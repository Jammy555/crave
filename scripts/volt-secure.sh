#!/bin/bash
#
# =============================================================================
#  LunarisOS Build & Upload Automation Script  —  SECURED version for GitHub Actions
# =============================================================================
#
#  REQUIRED ENVIRONMENT VARIABLES (set by GitHub Actions from secrets):
#    TELEGRAM_BOT_TOKEN  — your Telegram bot token
#    TELEGRAM_CHAT_ID    — your Telegram chat/user ID
#    ZDRIVE_API_KEY      — your zdrive (zincdrive.com) API key
#
#  OPTIONAL ENVIRONMENT VARIABLES (set by GitHub Actions workflow inputs):
#    INPUT_SKIP_SYNC        — "true" to skip sync
#    INPUT_RUN_RESET        — "true" to hard-reset repos
#    INPUT_BUILD_MODULE     — what to build, default "bacon"
#    INPUT_TREE_OVERRIDES   — comma-separated branch overrides, e.g.
#                             "kernel:test,device:main,vendor:test"
#                             Only listed trees are overridden; others use defaults.
#    INPUT_MANIFEST_BRANCH  — override manifest branch
#
#  CLI USAGE (for manual runs):
#    bash volt-secure.sh [flags] [module1] [-module2]
#    Flags: --nosync, --reset, --tree1=name:branch, --tree2=name:branch,
#           --manifest-branch=X, -h/--help
# =============================================================================

# ---- Safety belts -----------------------------------------------------------
set -u
set -o pipefail
set -m

# =============================================================================
# CREDENTIALS — from environment, NOT hardcoded
# =============================================================================
TELEGRAM_TOKEN="${TELEGRAM_BOT_TOKEN:?'ERROR: TELEGRAM_BOT_TOKEN not set. Add it to GitHub Secrets.'}"
TELEGRAM_CHAT="${TELEGRAM_CHAT_ID:?'ERROR: TELEGRAM_CHAT_ID not set. Add it to GitHub Secrets.'}"
ZDRIVE_KEY="${ZDRIVE_API_KEY:?'ERROR: ZDRIVE_API_KEY not set. Add it to GitHub Secrets.'}"

# =============================================================================
# CONFIGURATION
# =============================================================================

# --- Build identity ---------------------------------------------------------
DEVICE_CODE="lemonade"
BUILD_TARGET="Lunaris"
ANDROID_VERSION="16"
MANIFEST_URL="https://github.com/Lunaris-AOSP/android.git"
MANIFEST_BRANCH="${INPUT_MANIFEST_BRANCH:-16.2}"

# --- Sync history marker -----------------------------------------------
SYNC_HISTORY_FILE=".repo/.volt_sync_history"

# --- Tree lookup: "repo_url|local_path|display_name|default_branch" --------
declare -A TREE_LOOKUP=(
    [kernel]="https://github.com/Jammy555/android_kernel_oneplus_sm8350.git|./kernel/oneplus/sm8350|kernel|16.2"
    [device]="https://github.com/Jammy555/android_device_oneplus_lemonade.git|./device/oneplus/lemonade|device tree|test"
    [common]="https://github.com/Jammy555/android_device_oneplus_sm8350-common.git|./device/oneplus/sm8350-common|common tree|test"
    [hardware]="https://github.com/Jammy555/hardware_oplus.git|./hardware/oplus|hardware|test"
    [vendor]="https://github.com/Jammy555/vendor_oneplus_lemonade.git|./vendor/oneplus/lemonade|vendor lemonade|test"
    [vendor-common]="https://github.com/Jammy555/vendor_oneplus_sm8350-common.git|./vendor/oneplus/sm8350-common|vendor common|test"
    [camera]="https://github.com/Jammy555/vendor_oplus_camera.git|./vendor/oplus/camera|oplus camera|testi"
    [dolby]="https://github.com/Jammy555/vendor_oneplus_dolby.git|./vendor/sony/dolby|dolby|D2"
    [pixelworks]="https://github.com/LineageOS/android_hardware_pixelworks_interfaces.git|hardware/pixelworks/interfaces|pixelworks|lineage-23.2"
)

# --- Branch override map (populated from INPUT_TREE_OVERRIDES or --tree1/2) --
# If a tree name has an entry here, clone_default() uses THIS branch instead
# of the default from TREE_LOOKUP.
declare -A BRANCH_OVERRIDES=()

# --- Tunables ---------------------------------------------------------------
POLL_INTERVAL_SECONDS=15
STATUS_EVERY_N_POLLS=4
STARTUP_GRACE_POLLS=12
CLONE_MAX_ATTEMPTS=3
CLONE_RETRY_DELAY=10
UPLOAD_MAX_ATTEMPTS=3
UPLOAD_RETRY_DELAY=10
INTERRUPT_GRACE_SECONDS=5
REPO_INIT_TIMEOUT_SECONDS=600
RESYNC_TIMEOUT_SECONDS=14400
MAX_MODULES=2

# --- Shell environment -------------------------------------------------------
export TZ="Asia/Kolkata"
export BUILD_USERNAME="Prathap"
export BUILD_HOSTNAME="crave"

# =============================================================================
# GLOBAL STATE
# =============================================================================
TG_MSG_ID=""
START_TIME=$(date +%s)
STEP_START_TIME=$START_TIME
START_TIME_FMT=$(date '+%Y-%m-%d %H:%M:%S %Z')
COMPLETED_STEPS=""
LAST_TG_UPDATE_ID=0
CURRENT_STAGE="Initializing"
FAILURE_REASON=""
CURRENT_LOG_FILE=""
MODULE_FAILURE_COUNT=0
INTERRUPTED=0
BUILD_PID=""
TREE1_NAME=""; TREE1_BRANCH=""
TREE2_NAME=""; TREE2_BRANCH=""

# =============================================================================
# USAGE / HELP
# =============================================================================
print_usage() {
cat <<'USAGE_EOF'
LunarisOS build script (volt-secure.sh) — SECURED version

  bash volt-secure.sh [flags] [module1] [-module2]

  REQUIRED ENVIRONMENT VARIABLES:
    TELEGRAM_BOT_TOKEN   Your Telegram bot token
    TELEGRAM_CHAT_ID     Your Telegram chat/user ID
    ZDRIVE_API_KEY       Your zdrive API key

FLAGS
  --nosync                      Skip syncing + cloning.
  --reset[=<paths>]             Hard reset repos.
  --tree1=<name>:<branch>       Switch ONE tree (CLI only).
  --tree2=<name>:<branch>       Second tree switch (CLI only).
  --manifest-branch=<branch>    Override manifest branch.
  -h, --help                    Show this help.

ENVIRONMENT VARIABLE OVERRIDES (GitHub Actions):
  INPUT_SKIP_SYNC=true
  INPUT_RUN_RESET=true
  INPUT_BUILD_MODULE="bacon"
  INPUT_TREE_OVERRIDES="kernel:test,device:main,vendor:test"
  INPUT_MANIFEST_BRANCH="16.2"

VALID TREE NAMES for overrides:
  kernel, device, common, hardware, vendor, vendor-common,
  camera, dolby, pixelworks
USAGE_EOF
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
SKIP_SYNC=0
RUN_RESET=0
RESET_TARGETS=""
CLEAN_ARGS=()

# Apply environment variable overrides first (from GitHub Actions inputs)
if [[ "${INPUT_SKIP_SYNC:-}" == "true" ]]; then
    SKIP_SYNC=1
fi
if [[ "${INPUT_RUN_RESET:-}" == "true" ]]; then
    RUN_RESET=1
fi

# Parse INPUT_TREE_OVERRIDES — comma-separated "name:branch" pairs
# e.g. "kernel:test,device:main,vendor:test"
# These override the default branch in TREE_LOOKUP during step 2 (clone).
if [[ -n "${INPUT_TREE_OVERRIDES:-}" ]]; then
    IFS=',' read -ra _overrides <<< "$INPUT_TREE_OVERRIDES"
    for _entry in "${_overrides[@]}"; do
        # Trim whitespace
        _entry=$(echo "$_entry" | xargs)
        [[ -z "$_entry" ]] && continue

        _oname="${_entry%%:*}"
        _oname="${_oname,,}"  # lowercase
        _oname="${_oname//_/-}"
        [[ "$_oname" == "device-common" ]] && _oname="common"
        _obranch="${_entry#*:}"

        if [[ "$_oname" == "${_entry,,}" || -z "$_obranch" ]]; then
            echo "ERROR: TREE_OVERRIDES entry '${_entry}' needs the form name:branch" >&2
            exit 1
        fi
        if [[ -z "${TREE_LOOKUP[$_oname]:-}" ]]; then
            echo "ERROR: unknown tree '${_oname}' in TREE_OVERRIDES. Valid: ${!TREE_LOOKUP[*]} device-common" >&2
            exit 1
        fi
        BRANCH_OVERRIDES[$_oname]="$_obranch"
        echo "  Tree override: ${_oname} → ${_obranch}"
    done
fi

# Then parse CLI args (--tree1/--tree2 still supported for manual runs)
for arg in "$@"; do
    case "$arg" in
        -h|--help)
            print_usage; exit 0 ;;
        --nosync)
            SKIP_SYNC=1 ;;
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
                echo "ERROR: --tree1 needs the form name:branch" >&2; exit 1
            fi
            if [[ -z "${TREE_LOOKUP[$TREE1_NAME]:-}" ]]; then
                echo "ERROR: unknown tree '${TREE1_NAME}'. Valid: ${!TREE_LOOKUP[*]}" >&2; exit 1
            fi
            ;;
        --tree2=*)
            _t="${arg#--tree2=}"
            TREE2_NAME="${_t%%:*}"; TREE2_NAME="${TREE2_NAME,,}"
            TREE2_BRANCH="${_t#*:}"
            if [[ "$TREE2_NAME" == "${_t,,}" || -z "$TREE2_BRANCH" ]]; then
                echo "ERROR: --tree2 needs the form name:branch" >&2; exit 1
            fi
            if [[ -z "${TREE_LOOKUP[$TREE2_NAME]:-}" ]]; then
                echo "ERROR: unknown tree '${TREE2_NAME}'. Valid: ${!TREE_LOOKUP[*]}" >&2; exit 1
            fi
            ;;
        *)
            CLEAN_ARGS+=("$arg") ;;
    esac
done

if [[ -n "$TREE1_NAME" && -n "$TREE2_NAME" && "$TREE1_NAME" == "$TREE2_NAME" ]]; then
    echo "ERROR: --tree1 and --tree2 both target '${TREE1_NAME}'" >&2; exit 1
fi

# =============================================================================
# MODULE PARSER
# =============================================================================
BUILD_MODULES=()
CURRENT_MODULE=""

if [[ ${#CLEAN_ARGS[@]} -eq 0 && -n "${INPUT_BUILD_MODULE:-}" ]]; then
    CLEAN_ARGS=("${INPUT_BUILD_MODULE}")
fi

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
    echo "ERROR: ${#BUILD_MODULES[@]} modules given, max is ${MAX_MODULES}." >&2; exit 1
fi

# =============================================================================
# TELEGRAM HELPERS
# =============================================================================

update_tg_status() {
    local current_step="$1"
    local status_text="$2"
    CURRENT_STAGE="$current_step"

    local CURRENT_TIME DURATION H M S DURATION_FMT message
    CURRENT_TIME=$(date +%s)
    DURATION=$((CURRENT_TIME - START_TIME))
    H=$((DURATION/3600)); M=$(((DURATION%3600)/60)); S=$((DURATION%60))
    DURATION_FMT=$(printf "%02d hrs, %02d mins, %02d secs" "$H" "$M" "$S")

    message="⚙️ <b>LunarisOS Build Monitor</b>

• <b>ROM:</b> ${BUILD_TARGET}
• <b>Device:</b> ${DEVICE_CODE}
• <b>Android:</b> ${ANDROID_VERSION}
• <b>Server:</b> foss.crave.io
• <b>Start Time:</b> ${START_TIME_FMT}
• <b>Elapsed:</b> ${DURATION_FMT}

<b>Task Progress:</b>
${COMPLETED_STEPS}"

    if [ -n "$current_step" ]; then
        message="${message}👉 <b>${current_step}:</b> ${status_text}"
    fi

    if [ -z "$TG_MSG_ID" ]; then
        local response
        response=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT}" \
            --data-urlencode "text=${message}" \
            -d "parse_mode=HTML" \
            -d "disable_web_page_preview=true")
        TG_MSG_ID=$(echo "$response" | grep -o '"message_id":[0-9]*' | head -n 1 | cut -d':' -f2)
    else
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/editMessageText" \
            -d "chat_id=${TELEGRAM_CHAT}" \
            -d "message_id=${TG_MSG_ID}" \
            --data-urlencode "text=${message}" \
            -d "parse_mode=HTML" \
            -d "disable_web_page_preview=true" &> /dev/null
    fi
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

mark_step_complete() {
    local step_text="$1"
    COMPLETED_STEPS="${COMPLETED_STEPS}${step_text}
"
}

send_telegram_file() {
    local file_path="$1"
    local caption_text="$2"

    if [ ! -f "$file_path" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT}" \
            --data-urlencode "text=⚠️ <b>Warning:</b> Could not find file ${file_path} to upload." \
            -d "parse_mode=HTML" > /dev/null
        return
    fi

    local attempt
    for ((attempt=1; attempt<=UPLOAD_MAX_ATTEMPTS; attempt++)); do
        if curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendDocument" \
            -F chat_id="${TELEGRAM_CHAT}" \
            -F document=@"${file_path}" \
            -F caption="${caption_text}" > /dev/null; then
            return
        fi
        sleep "$UPLOAD_RETRY_DELAY"
    done
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

die() {
    FAILURE_REASON="$1"
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
        mark_step_complete "🛑 Cancelled during: ${CURRENT_STAGE}"
        update_tg_status "Cancelled 🛑" "⚠️ Build manually stopped during: ${CURRENT_STAGE}"
        [[ -n "$CURRENT_LOG_FILE" ]] && send_telegram_file "$CURRENT_LOG_FILE" "📄 Log at cancellation"
    elif [[ -n "$FAILURE_REASON" ]]; then
        mark_step_complete "❌ Failed during: ${CURRENT_STAGE}"
        update_tg_status "Build Failed ❌" "🚨 ${FAILURE_REASON} — during: ${CURRENT_STAGE}"
        [[ -n "$CURRENT_LOG_FILE" ]] && send_telegram_file "$CURRENT_LOG_FILE" "📄 Log from: ${CURRENT_STAGE}"
    elif [[ $exit_code -ne 0 ]]; then
        update_tg_status "Finished, with failures ⚠️" "⚠️ ${MODULE_FAILURE_COUNT} module(s) failed."
    else
        mark_step_complete "✅ <b>All modules finished successfully</b>"
        update_tg_status "Finished 🎉" "✅ All queued build modules completed."
    fi
}

trap on_exit EXIT
trap on_interrupt INT TERM HUP

# =============================================================================
# SMALL RETRY HELPER
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

    update_tg_status "Cloning Trees 🌲" "⏳ Verifying remote branch '${branch}' for ${comp_name}..."

    # Check if the branch exists on remote repository
    if ! git ls-remote --heads --exit-code "$repo_url" "$branch" &>/dev/null; then
        die "Branch '${branch}' does NOT exist on remote repo for ${comp_name} (${repo_url})"
    fi

    update_tg_status "Cloning Trees 🌲" "⏳ Fetching ${comp_name} (branch: ${branch})..."

    if [ -d "$target_dir" ]; then
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

# Clones a tree using its default branch from TREE_LOOKUP, UNLESS there's
# an override in BRANCH_OVERRIDES (set by INPUT_TREE_OVERRIDES env var).
clone_default() {
    local key="$1"
    local lookup="${TREE_LOOKUP[$key]}"
    local repo_url="${lookup%%|*}"; local rest="${lookup#*|}"
    local target_dir="${rest%%|*}"; rest="${rest#*|}"
    local display_name="${rest%%|*}"
    local default_branch="${rest#*|}"

    # Use override branch if one was specified for this tree
    local branch="${BRANCH_OVERRIDES[$key]:-$default_branch}"

    if [[ "$branch" != "$default_branch" ]]; then
        update_tg_status "Cloning Trees 🌲" "⏳ ${display_name}: using override branch '${branch}' (default was '${default_branch}')..."
    fi

    smart_clone "$repo_url" "$branch" "$target_dir" "$display_name"
}

# Switches ONE tree to an EXPLICIT branch (used by CLI --tree1/--tree2).
switch_tree() {
    local tree_key="$1"
    local new_branch="$2"
    local lookup="${TREE_LOOKUP[$tree_key]}"
    local repo_url="${lookup%%|*}"; local rest="${lookup#*|}"
    local target_dir="${rest%%|*}"; rest="${rest#*|}"
    local display_name="${rest%%|*}"
    step_start

    smart_clone "$repo_url" "$new_branch" "$target_dir" "$display_name"

    update_tg_status "Switching Tree 🔀" "⏳ mka installclean after moving ${display_name}..."
    mka installclean
    mark_step_complete "🔀 Switched <b>${display_name}</b> → ${new_branch} ($(elapsed_since_step))"
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

# =============================================================================
# BUILD FUNCTION
# =============================================================================
start_build_process() {
    mkdir -p out

    if [[ $SKIP_SYNC -eq 0 ]]; then
        # --- STEP 1: INITIALIZE & SYNC ---
        update_tg_status "Syncing Sources 🔄" "⏳ Cleaning old manifest state..."
        step_start
        rm -rf .repo/manifests .repo/manifests.git .repo/manifest.xml .repo/local_manifests

        update_tg_status "Syncing Sources 🔄" "⏳ Running repo init (manifest branch: ${MANIFEST_BRANCH})..."
        CURRENT_LOG_FILE="out/repo_init.log"
        timeout "$REPO_INIT_TIMEOUT_SECONDS" repo init --depth=1 --no-repo-verify -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" --git-lfs \
            > out/repo_init.log 2>&1
        local REPO_INIT_STATUS=$?
        if [[ $REPO_INIT_STATUS -eq 124 ]]; then
            die "repo init timed out after ${REPO_INIT_TIMEOUT_SECONDS}s"
        elif [[ $REPO_INIT_STATUS -ne 0 ]]; then
            die "repo init failed (exit ${REPO_INIT_STATUS})"
        fi
        CURRENT_LOG_FILE=""

        update_tg_status "Syncing Sources 🔄" "⏳ Running resync.sh..."
        CURRENT_LOG_FILE="out/resync.log"
        timeout "$RESYNC_TIMEOUT_SECONDS" /opt/crave/resync.sh > out/resync.log 2>&1
        local RESYNC_STATUS=$?

        if [[ $RESYNC_STATUS -eq 0 ]]; then
            CURRENT_LOG_FILE=""
            mkdir -p .repo
            echo "$(date '+%Y-%m-%d %H:%M:%S %Z') - resync OK" >> "$SYNC_HISTORY_FILE"
        elif [[ -s "$SYNC_HISTORY_FILE" ]]; then
            local failing_repos
            failing_repos=$(grep -iE "error:|fatal:|cannot fetch|failed to sync|cannot checkout" out/resync.log | sort -u | head -20)
            mark_step_complete "⚠️ resync.sh reported errors after $(elapsed_since_step) (continuing — last good sync: $(tail -1 "$SYNC_HISTORY_FILE"))"
            update_tg_status "Resync Warning ⚠️" "⚠️ resync.sh hit an error, continuing with what's on disk.
${failing_repos:-(see attached log)}"
            send_telegram_file "out/resync.log" "📄 resync.sh output (failed, but prior sync exists)"
            CURRENT_LOG_FILE=""
        elif [[ $RESYNC_STATUS -eq 124 ]]; then
            die "resync.sh timed out after ${RESYNC_TIMEOUT_SECONDS}s"
        else
            die "resync.sh failed (no prior successful sync)"
        fi

        mark_step_complete "✅ Sources Synced ($(elapsed_since_step))"

        # --- STEP 2: CLONE OR UPDATE DEVICE TREES ---
        # clone_default() automatically uses BRANCH_OVERRIDES if set
        step_start

        # Log which overrides are active
        if [[ ${#BRANCH_OVERRIDES[@]} -gt 0 ]]; then
            local override_summary=""
            for _ok in "${!BRANCH_OVERRIDES[@]}"; do
                override_summary="${override_summary} ${_ok}→${BRANCH_OVERRIDES[$_ok]}"
            done
            update_tg_status "Cloning Trees 🌲" "⏳ Active branch overrides:${override_summary}"
        fi

        clone_default kernel
        clone_default device
        clone_default common
        clone_default hardware
        clone_default vendor
        clone_default vendor-common
        clone_default camera
        clone_default dolby

        # --- FRAMEWORKS & APPS ---
        smart_clone "https://github.com/Lunaris-AOSP/frameworks_base.git" "$MANIFEST_BRANCH" "frameworks/base" "frameworks base"
        smart_clone "https://github.com/Lunaris-AOSP/packages_apps_Singularity.git" "$MANIFEST_BRANCH" "packages/apps/Singularity" "singularity"

        # --- PIXELWORKS & KEYS ---
        clone_default pixelworks

        if [ -d "vendor/lineage-priv/keys" ]; then
            update_tg_status "Cloning Trees 🌲" "⏳ Wiping old keys folder..."
            rm -rf vendor/lineage-priv/keys
        fi
        smart_clone "https://github.com/Jammy555/vendor_evolution-priv_keys-template.git" "master" "vendor/lineage-priv/keys" "lineage keys"

        # Report overrides in the completion message
        if [[ ${#BRANCH_OVERRIDES[@]} -gt 0 ]]; then
            local ov_list=""
            for _ok in "${!BRANCH_OVERRIDES[@]}"; do
                ov_list="${ov_list}, ${_ok}:${BRANCH_OVERRIDES[$_ok]}"
            done
            mark_step_complete "✅ Trees Cloned & Updated ($(elapsed_since_step)) [overrides:${ov_list:2}]"
        else
            mark_step_complete "✅ Trees Cloned & Updated ($(elapsed_since_step))"
        fi
    else
        mark_step_complete "⏩ <b>Sync & Clones Skipped</b> (--nosync)"
    fi

    # --- STEP 3: ENVSETUP & LUNCH ---
    step_start
    update_tg_status "Environment Setup 🛠" "⏳ Running lunch command..."
    set +u
    # shellcheck disable=SC1091
    . build/envsetup.sh
    lunch lineage_lemonade-bp4a-user
    local LUNCH_STATUS=$?
    if [[ $LUNCH_STATUS -ne 0 ]]; then
        die "lunch lineage_lemonade-bp4a-user failed (exit ${LUNCH_STATUS})"
    fi
    mark_step_complete "✅ Environment Ready ($(elapsed_since_step))"

    # --- STEP 4: CLEAR STALE OUTPUT (mka installclean — NOT make clean!) ---
    step_start
    update_tg_status "Environment Setup 🛠" "⏳ Cleaning old target output (mka installclean)..."
    mka installclean
    mark_step_complete "✅ Artifacts Cleared ($(elapsed_since_step))"

    # --- STEP 5: OPTIONAL REPOSITORY RESET ---
    step_start
    if [[ $RUN_RESET -eq 1 ]]; then
        update_tg_status "Environment Setup 🛠" "⏳ Running repo reset..."
        if [[ -n "$RESET_TARGETS" ]]; then
            repo forall $RESET_TARGETS -c 'git reset --hard && git clean -fdx'
            mark_step_complete "✅ Repositories Reset (${RESET_TARGETS}) ($(elapsed_since_step))"
        else
            repo forall -c 'git reset --hard && git clean -fdx'
            mark_step_complete "✅ Repositories Reset (All) ($(elapsed_since_step))"
        fi
    else
        mark_step_complete "⏩ <b>Repository Reset Skipped</b>"
    fi

    # --- STEP 6: ZDRIVE SETUP ---
    step_start
    update_tg_status "Upload Prep 📤" "⏳ Installing & configuring zdrive CLI..."
    if ! command -v zdrive &> /dev/null; then
        curl -s https://zincdrive.com/cli | bash
        sleep 2
        export PATH="/home/admin/.local/bin:$HOME/.local/bin:$PATH"
    fi
    zdrive setup "$ZDRIVE_KEY"
    mark_step_complete "✅ Upload Tool Ready ($(elapsed_since_step))"

    # --- STEP 7: OPTIONAL TREE SWITCHES (CLI --tree1/--tree2 only) ---
    # These are for manual CLI use. GitHub Actions uses TREE_OVERRIDES which
    # applies during clone (step 2) and doesn't need a post-clone switch.
    if [[ -n "$TREE1_NAME" ]]; then
        switch_tree "$TREE1_NAME" "$TREE1_BRANCH"
    fi
    if [[ -n "$TREE2_NAME" ]]; then
        switch_tree "$TREE2_NAME" "$TREE2_BRANCH"
    fi

    # --- STEP 8: BUILD + UPLOAD EACH MODULE ---
    local total_modules=${#BUILD_MODULES[@]}
    local module_index=0

    for target_module in "${BUILD_MODULES[@]}"; do
        module_index=$((module_index + 1))
        update_tg_status "Building 🔨" "⏳ Starting module ${module_index}/${total_modules}: ${target_module}..."
        CURRENT_LOG_FILE="out/build.log"
        step_start

        rm -f out/build.log out/.build_start_marker
        touch out/.build_start_marker
        sleep 1

        # stdbuf -oL forces line-buffered output so the log file updates
        # in real time for the progress parser below.
        # Fall back to plain tee if stdbuf isn't available.
        if command -v stdbuf &> /dev/null; then
            ( m $target_module 2>&1 | stdbuf -oL tee out/build.log ) &
        else
            ( m $target_module 2>&1 | tee out/build.log ) &
        fi
        BUILD_PID=$!

        local loop_count=0
        while kill -0 "$BUILD_PID" 2>/dev/null; do
            sleep "$POLL_INTERVAL_SECONDS"
            loop_count=$((loop_count + 1))
            local force_update=0

            local updates new_update_id cmd_text
            updates=$(curl -s "https://api.telegram.org/bot${TELEGRAM_TOKEN}/getUpdates?offset=$((LAST_TG_UPDATE_ID + 1))&limit=1" 2>/dev/null)
            new_update_id=$(echo "$updates" | grep -o '"update_id":[0-9]*' | head -n 1 | cut -d':' -f2)
            cmd_text=$(echo "$updates" | grep -o '"text":"[^"]*"' | head -n 1 | cut -d'"' -f4)

            if [[ -n "$new_update_id" ]]; then
                LAST_TG_UPDATE_ID=$new_update_id
                if [[ "$cmd_text" == "/refresh" ]]; then
                    force_update=1
                    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" -d "chat_id=${TELEGRAM_CHAT}" -d "text=🔄 <b>Manual Refresh Triggered!</b> Fetching latest logs..." -d "parse_mode=HTML" > /dev/null
                elif [[ "$cmd_text" == "/stop" || "$cmd_text" == "/cancel" ]]; then
                    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" -d "chat_id=${TELEGRAM_CHAT}" -d "text=🛑 <b>Stop requested via Telegram</b> — cancelling ${target_module}..." -d "parse_mode=HTML" > /dev/null
                    kill -TERM $$
                fi
            fi

            # ── PROGRESS PARSING ──────────────────────────────────────
            # Read a large chunk from the end of the log and look for
            # ninja progress lines like: [ 23% 12345/53421] target C++: ...
            #
            # - tail -c 16000: read last 16KB (generous, catches progress
            #   even with very long action descriptions between updates)
            # - tr '\r' '\n': ninja uses \r to overwrite lines in terminal;
            #   convert to real newlines so grep can match each update
            # - grep WITHOUT ^ anchor: crave run may prefix lines with
            #   extra output, so the [ may not be at column 0
            local latest_line
            latest_line=$(tail -c 16000 out/build.log 2>/dev/null | tr '\r' '\n' | grep -E '\[ *[0-9]{1,3}% [0-9]+/[0-9]+\]' | tail -n 1)

            local current_status=""
            if [[ -z "$latest_line" ]] || { [[ "$latest_line" == *"[100% "* ]] && [[ $loop_count -lt $STARTUP_GRACE_POLLS ]]; }; then
                current_status="⏳ (${target_module}) Analyzing Blueprints..."
            else
                local percent done_total action_desc bar elapsed eta_line percent_num
                percent=$(echo "$latest_line" | grep -oE '[0-9]{1,3}%' | head -n1 | tr -d '%')
                percent="${percent:-0}"
                percent_num=$((10#$percent))
                done_total=$(echo "$latest_line" | grep -oE '[0-9]+/[0-9]+' | head -n1)
                action_desc=$(echo "$latest_line" | sed -E 's/.*\] *//' | cut -c1-90)
                bar=$(make_progress_bar "$percent_num")

                eta_line=""
                if (( percent_num > 0 )); then
                    elapsed=$(( $(date +%s) - STEP_START_TIME ))
                    local est_total est_remaining
                    est_total=$(( elapsed * 100 / percent_num ))
                    est_remaining=$(( est_total - elapsed ))
                    (( est_remaining < 0 )) && est_remaining=0
                    eta_line=$(printf "\n⏱ Rough ETA: ~%02dh %02dm remaining" $((est_remaining/3600)) $(((est_remaining%3600)/60)))
                fi

                current_status="⏳ (${target_module}) [${bar}] ${percent_num}% (${done_total:-?})
🔧 ${action_desc}${eta_line}"
            fi

            if [[ $force_update -eq 1 ]] || [[ $((loop_count % STATUS_EVERY_N_POLLS)) -eq 0 ]]; then
                update_tg_status "Building 🔨" "$current_status"
            fi
        done

        wait "$BUILD_PID"
        local BUILD_STATUS=$?

        if [[ $BUILD_STATUS -ne 0 ]]; then
            MODULE_FAILURE_COUNT=$((MODULE_FAILURE_COUNT + 1))
            mark_step_complete "❌ <b>${target_module}</b> (Failed after $(elapsed_since_step), exit ${BUILD_STATUS})"
            update_tg_status "Module Failed ❌" "🚨 '${target_module}' failed (exit ${BUILD_STATUS})"
            send_telegram_file "out/build.log" "📄 Build error log: ${target_module} (exit ${BUILD_STATUS})"
            continue
        fi

        # --- UPLOAD ---
        update_tg_status "Uploading 📤" "⏳ Hunting for outputs from: ${target_module}..."

        local MODULE_LINKS=""
        local files_uploaded=0

        for specific_target in $target_module; do
            local search_pattern=""
            case "$specific_target" in
                bootimage)        search_pattern="boot.img" ;;
                dtboimage)        search_pattern="dtbo.img" ;;
                vendorbootimage)  search_pattern="vendor_boot.img" ;;
                vendorimage)      search_pattern="vendor.img" ;;
                recoveryimage)    search_pattern="recovery.img" ;;
                bacon)            search_pattern="*${DEVICE_CODE}*.zip" ;;
                *)                search_pattern="${specific_target}.*" ;;
            esac

            local matched_file
            matched_file=$(find "out/target/product/${DEVICE_CODE}/" -type f -name "$search_pattern" -newer out/.build_start_marker -printf '%T@ %p\n' 2>/dev/null | grep -E '\.(apk|jar|img|zip)$' | sort -n | tail -1 | cut -d' ' -f2-)

            if [[ -n "$matched_file" && -f "$matched_file" ]]; then
                local filename
                filename=$(basename "$matched_file")
                update_tg_status "Uploading 📤" "⏳ Uploading ${filename}..."

                local upload_success=0
                local attempt upload_log download_link
                for ((attempt=1; attempt<=UPLOAD_MAX_ATTEMPTS; attempt++)); do
                    upload_log=$(zdrive "$matched_file" 2>&1)
                    download_link=$(echo "$upload_log" | grep -o 'https://zdrive.to/[a-zA-Z0-9_-]*')

                    if [[ -n "$download_link" ]]; then
                        MODULE_LINKS="${MODULE_LINKS}
  ↳ <a href=\"${download_link}\">${filename}</a>"
                        upload_success=1
                        files_uploaded=$((files_uploaded + 1))
                        break
                    fi
                    sleep "$UPLOAD_RETRY_DELAY"
                done

                if [[ $upload_success -eq 0 ]]; then
                    MODULE_LINKS="${MODULE_LINKS}
  ↳ ❌ ${filename} (Upload Failed after ${UPLOAD_MAX_ATTEMPTS} attempts)"
                fi
            else
                MODULE_LINKS="${MODULE_LINKS}
  ↳ ⚠️ ${specific_target} (Compiled, but output file missing)"
            fi
        done

        if [[ $files_uploaded -gt 0 ]]; then
            mark_step_complete "✅ <b>${target_module}</b> ($(elapsed_since_step))${MODULE_LINKS}"
        else
            mark_step_complete "⚠️ <b>${target_module}</b> (Success in $(elapsed_since_step), no files uploaded)${MODULE_LINKS}"
        fi
    done

    if [[ $MODULE_FAILURE_COUNT -gt 0 ]]; then
        exit 1
    fi
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================
update_tg_status "Initializing 🚀" "⏳ Starting script..."
mark_step_complete "✅ Initialization"
start_build_process
exit 0
