#!/bin/bash
#
# =============================================================================
#  LunarisOS Build Automation Script  —  CLEAN version (no secrets, no uploads)
# =============================================================================
#
#  This script runs INSIDE the Crave build cluster via:
#    crave run --no-patch -- "curl -LSs .../volt.sh | bash -s -- [ARGS]"
#
#  It does NOT contain any secrets, bot tokens, or upload logic.
#  Telegram monitoring and zdrive uploads are handled by the calling
#  environment (GitHub Actions workflow + monitor.sh).
#
#  WHAT THIS SCRIPT DOES, IN ORDER:
#    1. Syncs the LunarisOS manifest        (repo init + Crave's resync.sh)
#    2. Clones/updates device-specific trees (kernel, device, vendor, ...)
#    3. Optionally hard-resets repos         (only if you pass --reset)
#    4. Runs `lunch` for lemonade (OnePlus SM8350)
#    5. Clears stale build output            (mka installclean)
#    6. Optionally switches up to 2 trees to a different branch (--tree1=/--tree2=)
#    7. Builds whichever module(s) you asked for (max 2, defaults to "bacon")
#
#  Lunch runs before installclean on purpose: `mka`/`m` are shell functions
#  that envsetup.sh defines, not standalone programs.
#
#  If a module fails, it does NOT abort the whole run — it marks it failed
#  and moves on to the next module.
#
#  Run `bash volt.sh --help` for a flag summary, or scroll to the very
#  bottom of this script for copy-pasteable `crave run` examples.
# =============================================================================

# ---- Safety belts -----------------------------------------------------------
set -u
set -o pipefail
set -m

# =============================================================================
# CONFIGURATION
# =============================================================================

# --- Build identity ---------------------------------------------------------
DEVICE_CODE="lemonade"
DEVICE_CONFIG_FILE=""
DEVICE_BASE_URL="${DEVICE_BASE_URL:-https://raw.githubusercontent.com/${GITHUB_REPOSITORY:-Jammy555/crave}/refs/heads/${GITHUB_REF_NAME:-main}}"
LUNCH_TARGET=""
BUILD_VARIANT=""
BUILD_TARGET="Lunaris"
ANDROID_VERSION="16"
MANIFEST_URL="https://github.com/Lunaris-AOSP/android.git"
MANIFEST_BRANCH="16.2"

# --- Signing keys (populated by device config if applicable) ----------------
KEYS_REPO=""
KEYS_BRANCH="master"
KEYS_DIR=""

# --- Sync history markers ---------------------------------------------------
SYNC_HISTORY_FILE=".repo/.volt_sync_history"

# --- Tree lookup: "repo_url|local_path|display_name|default_branch" ---------
declare -A TREE_LOOKUP=()

# --- Tunables ---------------------------------------------------------------
POLL_INTERVAL_SECONDS=10
STARTUP_GRACE_POLLS=90
CLONE_MAX_ATTEMPTS=3
CLONE_RETRY_DELAY=10
INTERRUPT_GRACE_SECONDS=5
REPO_INIT_TIMEOUT_SECONDS=600
RESYNC_TIMEOUT_SECONDS=14400
MAX_MODULES=2
STATS_EMIT_INTERVAL=30   # emit [VOLT_STATS] to stdout every 30s during build

# --- Shell environment -------------------------------------------------------
export TZ="Asia/Kolkata"
export BUILD_USERNAME="Prathap"
export BUILD_HOSTNAME="crave"

# =============================================================================
# GLOBAL STATE
# =============================================================================
START_TIME=$(date +%s)
STEP_START_TIME=$START_TIME
LAST_STATS_TIME=0          # tracks when we last emitted [VOLT_STATS]
CURRENT_STAGE="Initializing"
FAILURE_REASON=""
MODULE_FAILURE_COUNT=0
INTERRUPTED=0
BUILD_PID=""
TREE1_NAME=""; TREE1_BRANCH=""
TREE2_NAME=""; TREE2_BRANCH=""

# =============================================================================
# DEVICE CONFIG RESOLVER
# =============================================================================
resolve_device_config() {
    # 1. Explicit config file or URL passed via --device-config=
    if [[ -n "$DEVICE_CONFIG_FILE" ]]; then
        if [[ "$DEVICE_CONFIG_FILE" =~ ^https?:// ]]; then
            local tmp_cfg="/tmp/volt_device_${DEVICE_CODE}_$$.sh"
            echo "[VOLT_STATUS] Config ⚙️|Downloading device config from ${DEVICE_CONFIG_FILE}..." >&2
            if curl -fLSs "$DEVICE_CONFIG_FILE" -o "$tmp_cfg" 2>/dev/null && [[ -s "$tmp_cfg" ]]; then
                echo "$tmp_cfg"
                return 0
            fi
            return 1
        elif [[ -f "$DEVICE_CONFIG_FILE" ]]; then
            echo "$DEVICE_CONFIG_FILE"
            return 0
        fi
        return 1
    fi

    # 2. Local devices/<device>.sh in workspace or relative path
    for candidate in "devices/${DEVICE_CODE}.sh" "./devices/${DEVICE_CODE}.sh" "$(dirname "$0")/../devices/${DEVICE_CODE}.sh"; do
        if [[ -f "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    # 3. Remote download from repo
    if [[ -n "$DEVICE_BASE_URL" ]]; then
        local remote_url="${DEVICE_BASE_URL}/devices/${DEVICE_CODE}.sh"
        local tmp_cfg="/tmp/volt_device_${DEVICE_CODE}_$$.sh"
        if curl -fLSs "$remote_url" -o "$tmp_cfg" 2>/dev/null && [[ -s "$tmp_cfg" ]]; then
            echo "$tmp_cfg"
            return 0
        fi
    fi

    return 1
}

# =============================================================================
# USAGE / HELP
# =============================================================================
print_usage() {
cat <<'USAGE_EOF'
LunarisOS build script (volt.sh) — usage:

  curl -LSs .../volt.sh | bash -s -- [flags] [module1] [-module2]

  IMPORTANT: that "--" right after "-s" is not optional decoration — always
  include it.

FLAGS
  --device=<codename>           Target device (default: lemonade).
                                Loads devices/<codename>.sh from repo or local.
  --device-config=<path|url>    Path or URL to a custom device script.
  --device-base-url=<url>       Base URL for remote device scripts.
  --lunch=<target>              Override lunch target (e.g. lineage_capri-bp4a-userdebug).
  --variant=<variant>           Build variant: userdebug, user, or eng (default: userdebug).
  --nosync                      Skip syncing + cloning, rebuild from disk.
  --nosyncd                     Skip device tree cloning only.
  --reset[=<paths>]             Hard reset (git reset --hard && clean -fd).
                                 No value = ALL repos. With a value = only
                                 those repo path(s), space-separated.
  --tree1=<name>:<branch>       Switch ONE tree to a different branch before
                                 building (fetch+reset, then mka installclean).
  --tree2=<name>:<branch>       A second, independent tree switch.
                                 <name> must be one of the trees defined for
                                 the active device.
  --manifest-branch=<branch>    Override the WHOLE ROM manifest branch.
  -h, --help                    Show this help and exit.

MODULES — max 2 per run
  A module is one or more build targets. Space-separated words stay in the
  SAME module. A word starting with "-" starts a SECOND module.
  No module given → defaults to "bacon" (the full flashable zip).

  Example:  ...volt.sh | bash -s -- --device=capri --variant=user bacon
  Example:  ...volt.sh | bash -s -- --device=lemonade --tree1=kernel:test KeyHandler -bacon
USAGE_EOF
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
SKIP_SYNC=0
SKIP_SYNC_DEVICE=0
RUN_RESET=0
RESET_TARGETS=""
CLEAN_ARGS=()

# --- Pass 1: Extract device flags to load device configuration first ---
for arg in "$@"; do
    case "$arg" in
        --device=*)
            DEVICE_CODE="${arg#*=}" ;;
        --device-config=*)
            DEVICE_CONFIG_FILE="${arg#*=}" ;;
        --device-base-url=*)
            DEVICE_BASE_URL="${arg#*=}" ;;
        --lunch=*)
            LUNCH_TARGET="${arg#*=}" ;;
        --variant=*)
            BUILD_VARIANT="${arg#*=}" ;;
    esac
done

DEVICE_CFG_PATH=$(resolve_device_config) || die "Could not load device configuration for '${DEVICE_CODE}'. Ensure devices/${DEVICE_CODE}.sh exists or pass --device-config=<url_or_path>."

# Sourced at top level so declare -A in device config is ALWAYS global
# shellcheck disable=SC1090
source "$DEVICE_CFG_PATH"

# Fallback default for LUNCH_TARGET if not set by device file or --lunch flag
if [[ -z "$LUNCH_TARGET" ]]; then
    LUNCH_TARGET="lineage_${DEVICE_CODE}-bp4a-userdebug"
fi

# If a build variant was explicitly requested (e.g. user, userdebug, eng), adjust LUNCH_TARGET
if [[ -n "$BUILD_VARIANT" ]]; then
    if [[ "$LUNCH_TARGET" =~ -(userdebug|user|eng)$ ]]; then
        LUNCH_TARGET="${LUNCH_TARGET%-*}-${BUILD_VARIANT}"
    fi
fi

# --- Pass 2: Parse remaining flags and modules ---
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            print_usage; exit 0 ;;
        --device=*|--device-config=*|--device-base-url=*|--lunch=*|--variant=*)
            # Handled in Pass 1
            ;;
        --nosync)
            SKIP_SYNC=1 ;;
        --nosyncd)
            SKIP_SYNC_DEVICE=1 ;;
        --reset)
            RUN_RESET=1 ;;
        --reset=*)
            RUN_RESET=1; RESET_TARGETS="${arg#*=}" ;;
        --manifest-branch=*)
            MANIFEST_BRANCH="${arg#*=}" ;;
        --tree1=*)
            _t="${arg#--tree1=}"
            TREE1_NAME="${_t%%:*}"; TREE1_NAME="${TREE1_NAME,,}"
            TREE1_BRANCH="${_t#*:}"
            if [[ "$TREE1_NAME" == "${_t,,}" || -z "$TREE1_BRANCH" ]]; then
                echo "ERROR: --tree1 needs the form name:branch, e.g. --tree1=kernel:test" >&2
                exit 1
            fi
            if [[ -z "${TREE_LOOKUP[$TREE1_NAME]:-}" ]]; then
                echo "ERROR: unknown tree '${TREE1_NAME}' in --tree1. Valid trees for ${DEVICE_CODE}: ${!TREE_LOOKUP[*]}" >&2
                exit 1
            fi
            ;;
        --tree2=*)
            _t="${arg#--tree2=}"
            TREE2_NAME="${_t%%:*}"; TREE2_NAME="${TREE2_NAME,,}"
            TREE2_BRANCH="${_t#*:}"
            if [[ "$TREE2_NAME" == "${_t,,}" || -z "$TREE2_BRANCH" ]]; then
                echo "ERROR: --tree2 needs the form name:branch, e.g. --tree2=vendor:test" >&2
                exit 1
            fi
            if [[ -z "${TREE_LOOKUP[$TREE2_NAME]:-}" ]]; then
                echo "ERROR: unknown tree '${TREE2_NAME}' in --tree2. Valid trees for ${DEVICE_CODE}: ${!TREE_LOOKUP[*]}" >&2
                exit 1
            fi
            ;;
        *)
            CLEAN_ARGS+=("$arg") ;;
    esac
done

if [[ -n "$TREE1_NAME" && -n "$TREE2_NAME" && "$TREE1_NAME" == "$TREE2_NAME" ]]; then
    echo "ERROR: --tree1 and --tree2 both target '${TREE1_NAME}'" >&2
    exit 1
fi

# =============================================================================
# MODULE PARSER
# =============================================================================
BUILD_MODULES=()
CURRENT_MODULE=""

for arg in "${CLEAN_ARGS[@]}"; do
    if [[ "$arg" == -* ]]; then
        if [[ -n "$CURRENT_MODULE" ]]; then
            BUILD_MODULES+=("$CURRENT_MODULE")
        fi
        CURRENT_MODULE="${arg#-}"
    else
        if [[ -z "$CURRENT_MODULE" ]]; then
            CURRENT_MODULE="$arg"
        else
            CURRENT_MODULE="$CURRENT_MODULE $arg"
        fi
    fi
done
if [[ -n "$CURRENT_MODULE" ]]; then
    BUILD_MODULES+=("$CURRENT_MODULE")
fi
if [[ ${#BUILD_MODULES[@]} -eq 0 ]]; then
    BUILD_MODULES=("bacon")
fi
if [[ ${#BUILD_MODULES[@]} -gt $MAX_MODULES ]]; then
    echo "ERROR: ${#BUILD_MODULES[@]} modules given, but max is ${MAX_MODULES}." >&2
    exit 1
fi

# =============================================================================
# STDOUT STATUS HELPERS (replaces Telegram — monitor.sh reads these)
# =============================================================================

# Prints a structured status line that monitor.sh can parse.
# Format: [VOLT_STATUS] <step>|<detail>
log_status() {
    local step="$1"
    local detail="$2"
    CURRENT_STAGE="$step"
    echo "[VOLT_STATUS] ${step}|${detail}"
}

# Prints a structured step completion that monitor.sh can parse.
# Format: [VOLT_STEP] <emoji+text>
log_step_complete() {
    local step_text="$1"
    echo "[VOLT_STEP] ${step_text}"
}

step_start() {
    STEP_START_TIME=$(date +%s)
}

elapsed_since_step() {
    local secs=$(( $(date +%s) - STEP_START_TIME ))
    (( secs < 0 )) && secs=0
    if (( secs < 60 )); then
        echo "${secs}s"
    else
        printf '%dm %ds' $((secs/60)) $((secs%60))
    fi
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

die() {
    FAILURE_REASON="$1"
    echo "[VOLT_FATAL] ${FAILURE_REASON}" >&2
    exit 1
}

on_interrupt() {
    INTERRUPTED=1
    if [[ -n "$BUILD_PID" ]] && kill -0 "$BUILD_PID" 2>/dev/null; then
        kill -TERM -- "-$BUILD_PID" 2>/dev/null
        sleep "$INTERRUPT_GRACE_SECONDS"
        if kill -0 "$BUILD_PID" 2>/dev/null; then
            kill -KILL -- "-$BUILD_PID" 2>/dev/null
        fi
    fi
    exit 130
}

on_exit() {
    local exit_code=$?
    trap - EXIT INT TERM HUP

    if [[ $INTERRUPTED -eq 1 ]]; then
        echo "[VOLT_RESULT] CANCELLED|${CURRENT_STAGE}"
    elif [[ -n "$FAILURE_REASON" ]]; then
        echo "[VOLT_RESULT] FAILED|${FAILURE_REASON}|${CURRENT_STAGE}"
    elif [[ $exit_code -ne 0 ]]; then
        echo "[VOLT_RESULT] PARTIAL|${MODULE_FAILURE_COUNT} module(s) failed"
    else
        echo "[VOLT_RESULT] SUCCESS|All modules finished successfully"
    fi
}

trap on_exit EXIT
trap on_interrupt INT TERM HUP

# =============================================================================
# RETRY HELPER
# =============================================================================
retry() {
    local attempts="$1"; shift
    local delay="$1"; shift
    local n=1
    until "$@"; do
        if (( n >= attempts )); then
            return 1
        fi
        echo "  ...attempt $n/$attempts failed, retrying in ${delay}s: $*" >&2
        sleep "$delay"
        n=$((n + 1))
    done
    return 0
}

# =============================================================================
# SMART CLONE
# =============================================================================
smart_clone() {
    local repo_url="$1"
    local branch="$2"
    local target_dir="$3"
    local comp_name="$4"

    log_status "Cloning Trees 🌲" "Fetching ${comp_name} (branch: ${branch})..."

    if [ -d "$target_dir" ]; then
        # Bulletproof: clean up stale locks if a previous run crashed
        rm -f "$target_dir/.git/"*.lock 2>/dev/null || true
        
        retry "$CLONE_MAX_ATTEMPTS" "$CLONE_RETRY_DELAY" git -C "$target_dir" fetch --depth=1 "$repo_url" "$branch" \
            || die "Failed fetching ${comp_name} (branch '${branch}' on ${repo_url})"
        git -C "$target_dir" reset --hard FETCH_HEAD \
            || die "Failed resetting ${comp_name} to FETCH_HEAD"
        git -C "$target_dir" clean -fdx
    else
        retry "$CLONE_MAX_ATTEMPTS" "$CLONE_RETRY_DELAY" git clone --depth=1 "$repo_url" -b "$branch" "$target_dir" \
            || die "Failed cloning ${comp_name} (branch '${branch}' on ${repo_url})"
    fi
}

clone_default() {
    local key="$1"
    local lookup="${TREE_LOOKUP[$key]}"
    local repo_url="${lookup%%|*}"; local rest="${lookup#*|}"
    local target_dir="${rest%%|*}"; rest="${rest#*|}"
    local display_name="${rest%%|*}"
    local default_branch="${rest#*|}"
    smart_clone "$repo_url" "$default_branch" "$target_dir" "$display_name"
}

switch_tree() {
    local tree_key="$1"
    local new_branch="$2"
    local lookup="${TREE_LOOKUP[$tree_key]}"
    local repo_url="${lookup%%|*}"; local rest="${lookup#*|}"
    local target_dir="${rest%%|*}"; rest="${rest#*|}"
    local display_name="${rest%%|*}"
    step_start

    smart_clone "$repo_url" "$new_branch" "$target_dir" "$display_name"

    log_status "Switching Tree 🔀" "mka installclean after moving ${display_name}..."
    mka installclean
    log_step_complete "🔀 Switched ${display_name} → ${new_branch} ($(elapsed_since_step))"
}

# =============================================================================
# PROGRESS BAR HELPER
# =============================================================================
make_progress_bar() {
    local percent="${1:-0}"
    percent=$((10#$percent))
    local width=14
    local filled=$(( percent * width / 100 ))
    local empty=$(( width - filled ))
    local bar=""
    for ((i = 0; i < filled; i++)); do bar+="▓"; done
    for ((i = 0; i < empty; i++)); do bar+="░"; done
    echo "$bar"
}

# Cleans stale lock files left by killed or crashed builds
clean_stale_locks() {
    find .repo -name '*.lock' -delete 2>/dev/null || true
    # Remove git locks that might have been left behind during clone/fetch
    find kernel device hardware vendor -type f -name '*.lock' -path '*/.git/*' -delete 2>/dev/null || true
    rm -f out/.ninja_lock out/soong/.soong.in_use out/.lock 2>/dev/null || true
}

# =============================================================================
# STATS EMITTER — reads from BUILD CONTAINER's /proc (not devspace)
# Emits [VOLT_STATS] tag to stdout; monitor.sh parses it.
# Format: [VOLT_STATS] cpu=<pct>|ram_used=<h>|ram_total=<h>|ram_pct=<pct>|disk_used=<h>|disk_total=<h>|disk_pct=<pct>|load=<load1>|cores=<n>
# =============================================================================
emit_stats() {
    local now
    now=$(date +%s)
    if (( now - LAST_STATS_TIME < STATS_EMIT_INTERVAL )); then
        return
    fi
    LAST_STATS_TIME=$now

    # CPU: sample /proc/stat over 0.5s — works unprivileged on any Linux
    local cpu_pct=0
    if command -v python3 &>/dev/null; then
        cpu_pct=$(python3 -c "
import time
def snap():
    with open('/proc/stat') as f:
        v=[float(x) for x in f.readline().split()[1:]]
    return sum(v), v[3]+v[4]
t1,i1=snap(); time.sleep(0.5); t2,i2=snap()
dt,di=t2-t1,i2-i1
print(max(0,min(100,int(((dt-di)/dt)*100))) if dt>0 else 0)" 2>/dev/null || echo "0")
    fi

    # Load average + core count (unprivileged)
    local load1 cores
    load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0")
    cores=$(nproc 2>/dev/null || echo "1")

    # RAM: /proc/meminfo (unprivileged)
    local ram_total_kb ram_avail_kb ram_used_kb ram_total_mb ram_used_mb ram_pct
    ram_total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo "1")
    ram_avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo "0")
    ram_used_kb=$(( ram_total_kb - ram_avail_kb ))
    ram_total_mb=$(( ram_total_kb / 1024 ))
    ram_used_mb=$(( ram_used_kb / 1024 ))
    ram_pct=$(( ram_used_kb * 100 / ram_total_kb ))
    # Format as human-readable GB/MB
    local ram_used_h ram_total_h
    if (( ram_used_mb >= 1024 )); then
        ram_used_h="$(( ram_used_mb / 1024 )).$((( ram_used_mb % 1024 ) * 10 / 1024))G"
    else
        ram_used_h="${ram_used_mb}M"
    fi
    if (( ram_total_mb >= 1024 )); then
        ram_total_h="$(( ram_total_mb / 1024 )).$((( ram_total_mb % 1024 ) * 10 / 1024))G"
    else
        ram_total_h="${ram_total_mb}M"
    fi

    # Disk: df on current working dir (the AOSP source tree — no sudo needed)
    local disk_used_kb disk_total_kb disk_pct disk_used_h disk_total_h
    disk_total_kb=$(df -k . 2>/dev/null | awk 'NR==2{print $2}' || echo "1")
    disk_used_kb=$(df -k . 2>/dev/null | awk 'NR==2{print $3}' || echo "0")
    disk_pct=$(( disk_used_kb * 100 / disk_total_kb ))
    local disk_used_gb disk_total_gb
    disk_used_gb=$(( disk_used_kb / 1048576 ))
    disk_total_gb=$(( disk_total_kb / 1048576 ))
    disk_used_h="${disk_used_gb}G"
    disk_total_h="${disk_total_gb}G"

    echo "[VOLT_STATS] cpu=${cpu_pct}|ram_used=${ram_used_h}|ram_total=${ram_total_h}|ram_pct=${ram_pct}|disk_used=${disk_used_h}|disk_total=${disk_total_h}|disk_pct=${disk_pct}|load=${load1}|cores=${cores}"
}

# =============================================================================
# BUILD FUNCTION
# =============================================================================
start_build_process() {
    clean_stale_locks
    mkdir -p out

    # --- DEVICE SWITCH DETECTION & STALE TREE CLEANUP ---
    local last_device_file=".repo/.volt_last_device"
    local last_trees_file=".repo/.volt_last_device_trees"

    # Extract normalized target directory paths for current device
    local current_device_paths=()
    for lookup in "${TREE_LOOKUP[@]}"; do
        local rest="${lookup#*|}"
        local tdir="${rest%%|*}"
        tdir="${tdir#./}"
        current_device_paths+=("$tdir")
    done

    if [[ -f "$last_device_file" ]]; then
        local last_device; last_device=$(cat "$last_device_file" 2>/dev/null || true)
        if [[ -n "$last_device" && "$last_device" != "$DEVICE_CODE" ]]; then
            log_status "Device Switch 🔄" "Detected switch from ${last_device} to ${DEVICE_CODE}. Cleaning stale trees..."
            step_start

            # Remove previous device trees that are not used by the new device
            if [[ -f "$last_trees_file" ]]; then
                while IFS= read -r old_path; do
                    [[ -z "$old_path" ]] && continue
                    old_path="${old_path#./}"
                    local keep=0
                    for cpath in "${current_device_paths[@]}"; do
                        if [[ "$old_path" == "$cpath" ]]; then
                            keep=1
                            break
                        fi
                    done
                    if [[ $keep -eq 0 && -d "$old_path" ]]; then
                        echo "  [Device Switch] Removing stale tree: $old_path"
                        rm -rf "$old_path"
                        # Clean up empty parent directories if any
                        local parent_dir; parent_dir=$(dirname "$old_path")
                        while [[ "$parent_dir" != "." && "$parent_dir" != "/" ]]; do
                            rmdir "$parent_dir" 2>/dev/null || break
                            parent_dir=$(dirname "$parent_dir")
                        done
                    fi
                done < "$last_trees_file"
            fi

            # Clean stale build outputs across device switches to avoid ninja cache poisoning
            echo "  [Device Switch] Cleaning stale build outputs (out/target/product out/soong)..."
            rm -rf out/target/product out/soong 2>/dev/null || true

            log_step_complete "✅ Cleaned stale trees from ${last_device} ($(elapsed_since_step))"
        fi
    fi

    # Record active device and its trees for next run
    mkdir -p .repo
    echo "$DEVICE_CODE" > "$last_device_file" 2>/dev/null || true
    printf '%s\n' "${current_device_paths[@]}" > "$last_trees_file" 2>/dev/null || true

    if [[ $SKIP_SYNC -eq 0 ]]; then
        # --- STEP 1: INITIALIZE & SYNC ---
        log_status "Syncing Sources 🔄" "Cleaning old manifest state..."
        step_start
        rm -rf .repo/manifests .repo/manifests.git .repo/manifest.xml .repo/local_manifests

        log_status "Syncing Sources 🔄" "Running repo init (manifest branch: ${MANIFEST_BRANCH})..."
        timeout "$REPO_INIT_TIMEOUT_SECONDS" repo init --depth=1 --no-repo-verify -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" --git-lfs \
            > out/repo_init.log 2>&1
        local REPO_INIT_STATUS=$?
        if [[ $REPO_INIT_STATUS -eq 124 ]]; then
            die "repo init timed out after ${REPO_INIT_TIMEOUT_SECONDS}s"
        elif [[ $REPO_INIT_STATUS -ne 0 ]]; then
            die "repo init failed (exit ${REPO_INIT_STATUS})"
        fi

        log_status "Syncing Sources 🔄" "Running resync.sh..."
        timeout "$RESYNC_TIMEOUT_SECONDS" /opt/crave/resync.sh > out/resync.log 2>&1
        local RESYNC_STATUS=$?

        if [[ $RESYNC_STATUS -eq 0 ]]; then
            mkdir -p .repo
            echo "$(date '+%Y-%m-%d %H:%M:%S %Z') - resync OK" >> "$SYNC_HISTORY_FILE"
        elif [[ -s "$SYNC_HISTORY_FILE" ]]; then
            local failing_repos
            failing_repos=$(grep -iE "error:|fatal:|cannot fetch|failed to sync|cannot checkout" out/resync.log | sort -u | head -20)
            log_step_complete "⚠️ resync.sh reported errors after $(elapsed_since_step) (continuing — last good sync: $(tail -1 "$SYNC_HISTORY_FILE"))"
            echo "Resync warning — continuing with what's on disk."
            echo "${failing_repos:-(no specific repo names matched — see resync.log)}"
        elif [[ $RESYNC_STATUS -eq 124 ]]; then
            die "resync.sh timed out after ${RESYNC_TIMEOUT_SECONDS}s"
        else
            die "resync.sh failed (no prior successful sync)"
        fi

        log_step_complete "✅ ROM Synced ($(elapsed_since_step))"
    else
        log_step_complete "⏩ ROM Sync Skipped (--nosync)"
    fi

    # --- STEP 2: CLONE OR UPDATE DEVICE TREES ---
    if [[ $SKIP_SYNC_DEVICE -eq 0 ]]; then
        step_start

        # Sort tree keys for clean deterministic clone order
        local sorted_keys=()
        for preferred in kernel device common hardware vendor vendor-common; do
            if [[ -n "${TREE_LOOKUP[$preferred]:-}" ]]; then
                sorted_keys+=("$preferred")
            fi
        done
        for k in "${!TREE_LOOKUP[@]}"; do
            if [[ ! " ${sorted_keys[*]} " =~ " ${k} " ]]; then
                sorted_keys+=("$k")
            fi
        done

        for tree_key in "${sorted_keys[@]}"; do
            clone_default "$tree_key"
        done

        # Signing keys (if configured for this device)
        if [[ -n "${KEYS_REPO:-}" && -n "${KEYS_DIR:-}" ]]; then
            if [ -d "$KEYS_DIR" ]; then
                log_status "Cloning Trees 🌲" "Wiping old keys folder (${KEYS_DIR})..."
                rm -rf "$KEYS_DIR"
            fi
            smart_clone "$KEYS_REPO" "${KEYS_BRANCH:-master}" "$KEYS_DIR" "signing keys"
        fi

        # Optional post-clone hook
        if declare -f post_clone_hook >/dev/null; then
            log_status "Config ⚙️" "Running post_clone_hook for ${DEVICE_CODE}..."
            post_clone_hook
        fi

        log_step_complete "✅ Trees Cloned & Updated ($(elapsed_since_step))"
    else
        log_step_complete "⏩ Device Tree Sync Skipped (--nosyncd)"
    fi

    # --- STEP 3: OPTIONAL REPOSITORY RESET (only with --reset) ---
    step_start
    if [[ $RUN_RESET -eq 1 ]]; then
        log_status "Environment Setup 🛠" "Running repo reset..."
        if [[ -n "$RESET_TARGETS" ]]; then
            repo forall $RESET_TARGETS -c 'git reset --hard && git clean -fd'
            log_step_complete "✅ Repositories Reset (${RESET_TARGETS}) ($(elapsed_since_step))"
        else
            repo forall -c 'git reset --hard && git clean -fd'
            log_step_complete "✅ Repositories Reset (All) ($(elapsed_since_step))"
        fi
    else
        log_step_complete "⏩ Repository Reset Skipped"
    fi

    # --- STEP 4: ENVSETUP & LUNCH ---
    step_start
    if declare -f pre_lunch_hook >/dev/null; then
        log_status "Environment Setup 🛠" "Running pre_lunch_hook for ${DEVICE_CODE}..."
        pre_lunch_hook
    fi

    log_status "Environment Setup 🛠" "Running lunch ${LUNCH_TARGET}..."
    set +u
    # shellcheck disable=SC1091
    . build/envsetup.sh
    lunch "$LUNCH_TARGET"
    local LUNCH_STATUS=$?
    if [[ $LUNCH_STATUS -ne 0 ]]; then
        die "lunch ${LUNCH_TARGET} failed (exit ${LUNCH_STATUS})"
    fi
    log_step_complete "✅ Environment Ready ($(elapsed_since_step))"

    # --- STEP 5: CLEAR STALE OUTPUT ---
    step_start
    log_status "Environment Setup 🛠" "Cleaning old target output (mka installclean)..."
    mka installclean
    log_step_complete "✅ Artifacts Cleared ($(elapsed_since_step))"

    # --- STEP 6: OPTIONAL TREE SWITCHES (--tree1= / --tree2=) ---
    if [[ -n "$TREE1_NAME" ]]; then
        switch_tree "$TREE1_NAME" "$TREE1_BRANCH"
    fi
    if [[ -n "$TREE2_NAME" ]]; then
        switch_tree "$TREE2_NAME" "$TREE2_BRANCH"
    fi

    # --- STEP 7: BUILD EACH MODULE (max 2) ---
    local total_modules=${#BUILD_MODULES[@]}
    local module_index=0

    for target_module in "${BUILD_MODULES[@]}"; do
        module_index=$((module_index + 1))
        log_status "Building 🔨" "Starting module ${module_index}/${total_modules}: ${target_module}..."
        step_start

        clean_stale_locks
        rm -f out/build.log out/.build_start_marker
        touch out/.build_start_marker
        sleep 1

        if command -v stdbuf &> /dev/null; then
            ( m $target_module 2>&1 | stdbuf -oL tee out/build.log ) &
        else
            ( m $target_module 2>&1 | tee out/build.log ) &
        fi
        BUILD_PID=$!

        local loop_count=0
        local last_log_size=0
        local last_activity_time=$(date +%s)
        local STALL_TIMEOUT_SECONDS=1200   # 20 minutes of zero output AND idle CPU = stalled
        LAST_STATS_TIME=0  # reset per module so first stat fires quickly

        while kill -0 "$BUILD_PID" 2>/dev/null; do
            sleep "$POLL_INTERVAL_SECONDS"
            loop_count=$((loop_count + 1))

            # Emit stats every STATS_EMIT_INTERVAL seconds
            emit_stats

            # --- BUILD STALL WATCHDOG ---
            local current_log_size=0
            if [[ -f out/build.log ]]; then
                current_log_size=$(stat -c%s out/build.log 2>/dev/null || echo "0")
            fi

            if [[ $current_log_size -gt $last_log_size ]]; then
                last_log_size=$current_log_size
                last_activity_time=$(date +%s)
            else
                local inactive_sec=$(( $(date +%s) - last_activity_time ))
                local load1_val cpu_is_idle=0
                load1_val=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0")
                cpu_is_idle=$(python3 -c "import sys; print(1 if float(sys.argv[1]) < 0.2 else 0)" "$load1_val" 2>/dev/null || echo "0")

                if [[ $inactive_sec -ge $STALL_TIMEOUT_SECONDS && $cpu_is_idle -eq 1 && $loop_count -gt $STARTUP_GRACE_POLLS ]]; then
                    echo "[VOLT_STALL] No log activity & CPU idle for $((inactive_sec/60)) mins! Re-initializing..."

                    kill -9 -"$BUILD_PID" 2>/dev/null || kill -9 "$BUILD_PID" 2>/dev/null || true
                    sleep 3
                    clean_stale_locks

                    mka installclean 2>/dev/null || true
                    set +u
                    # shellcheck disable=SC1091
                    . build/envsetup.sh
                    lunch "$LUNCH_TARGET"

                    echo "[VOLT_STATUS] Building 🔨|Resuming ${target_module} after stall recovery..."

                    if command -v stdbuf &> /dev/null; then
                        ( m $target_module 2>&1 | stdbuf -oL tee -a out/build.log ) &
                    else
                        ( m $target_module 2>&1 | tee -a out/build.log ) &
                    fi
                    BUILD_PID=$!
                    last_activity_time=$(date +%s)
                    last_log_size=$(stat -c%s out/build.log 2>/dev/null || echo "0")
                    continue
                fi
            fi
        done

        wait "$BUILD_PID"
        local BUILD_STATUS=$?

        if [[ $BUILD_STATUS -ne 0 ]]; then
            MODULE_FAILURE_COUNT=$((MODULE_FAILURE_COUNT + 1))
            log_step_complete "❌ ${target_module} (Failed after $(elapsed_since_step), exit ${BUILD_STATUS})"
            echo "[VOLT_MODULE_FAIL] ${target_module}|${BUILD_STATUS}"
            continue
        fi

        log_step_complete "✅ ${target_module} (Built in $(elapsed_since_step))"
        echo "[VOLT_MODULE_OK] ${target_module}"
    done

    if [[ $MODULE_FAILURE_COUNT -gt 0 ]]; then
        exit 1
    fi
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================
echo "[VOLT_START] LunarisOS Build — $(date '+%Y-%m-%d %H:%M:%S %Z')"
ACTIVE_VARIANT="${BUILD_VARIANT:-}"
if [[ -z "$ACTIVE_VARIANT" ]]; then
    if [[ "$LUNCH_TARGET" =~ -(userdebug|user|eng)$ ]]; then
        ACTIVE_VARIANT="${BASH_REMATCH[1]}"
    else
        ACTIVE_VARIANT="userdebug"
    fi
fi
echo "[VOLT_CONFIG] device=${DEVICE_CODE} variant=${ACTIVE_VARIANT} rom=${BUILD_TARGET} android=${ANDROID_VERSION} branch=${MANIFEST_BRANCH}"
echo "[VOLT_MODULES] ${BUILD_MODULES[*]}"
log_step_complete "✅ Initialization"
start_build_process
exit 0

# =============================================================================
# USAGE EXAMPLES — copy/paste into: crave run --no-patch -- "<command>"
# =============================================================================
#
# Everywhere below, <command> means:
#   curl -LSs https://raw.githubusercontent.com/<REPO>/refs/heads/<BRANCH>/scripts/volt.sh | bash -s -- [ARGS...]
#
#  1) Default: full sync + build the flashable ROM zip ("bacon")
#       ...volt.sh | bash -s -- bacon
#
#  2) Full sync + build ONE specific module/app target
#       ...volt.sh | bash -s -- KeyHandler
#
#  3) Full sync + build boot.img AND dtbo.img together, as one module
#       ...volt.sh | bash -s -- bootimage dtboimage
#
#  4) Skip syncing/cloning entirely — rebuild from what's on disk
#       ...volt.sh | bash -s -- --nosync --nosyncd bacon
#
#  5) Hard-reset EVERY repo before building
#       ...volt.sh | bash -s -- --reset bacon
#
#  6) Hard-reset specific repo(s) before building
#       ...volt.sh | bash -s -- --reset="frameworks/base frameworks/native" bacon
#
#  7) Two modules in one turn
#       ...volt.sh | bash -s -- KeyHandler -bootimage
#
#  8) Switch ONE tree to a different branch, then build
#       ...volt.sh | bash -s -- --tree1=kernel:some-branch bacon
#
#  9) Switch TWO trees, then build two modules
#       ...volt.sh | bash -s -- --tree1=kernel:test --tree2=vendor:test KeyHandler -bacon
#
# 10) Skip sync, swap kernel branch, rebuild
#       ...volt.sh | bash -s -- --nosync --tree1=kernel:my-test bacon
#
# 11) Override manifest branch
#       ...volt.sh | bash -s -- --manifest-branch=16.3 bacon
#
# 12) See help
#       ...volt.sh | bash -s -- --help
#
# =============================================================================
