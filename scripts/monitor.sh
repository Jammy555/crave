#!/bin/bash
#
# =============================================================================
#  LunarisOS Build Monitor — runs on the GitHub Actions runner (devspace)
# =============================================================================
#
#  USAGE:
#    ./monitor.sh <LOG_FILE> <CRAVE_PID> &
#
#  REQUIRED ENVIRONMENT VARIABLES (set by GitHub Actions from secrets):
#    TELEGRAM_BOT_TOKEN  — Telegram bot token
#    TELEGRAM_CHAT_ID    — Telegram chat ID
#
#  TIMING:
#    - Queue/waiting state : Telegram update every 30 MINUTES
#    - Build stats (CPU/RAM/Disk from build container) : updated every 30s
#    - Task progress section : updated every 60s
#
#  Tags parsed from volt.sh stdout:
#    [VOLT_START]        — Build started
#    [VOLT_CONFIG]       — Build configuration
#    [VOLT_STATUS]       — Current step status
#    [VOLT_STEP]         — Step completed
#    [VOLT_MODULE_OK]    — Module built successfully
#    [VOLT_MODULE_FAIL]  — Module failed
#    [VOLT_STALL]        — Build stall detected
#    [VOLT_RESULT]       — Final result
#    [VOLT_FATAL]        — Fatal error
#    [VOLT_STATS]        — CPU/RAM/Disk stats from BUILD CONTAINER
#
#  Tags from crave itself:
#    "Selecting project ..."   — queue assignment
#    "Waiting for build id:..."— queue waiting
# =============================================================================

set -u

# --- Arguments ---------------------------------------------------------------
LOG_FILE="${1:?'Usage: monitor.sh <LOG_FILE> <CRAVE_PID>'}"
CRAVE_PID="${2:?'Usage: monitor.sh <LOG_FILE> <CRAVE_PID>'}"

# --- Credentials from environment (GitHub Secrets — NEVER hardcoded) ---------
TELEGRAM_TOKEN="${TELEGRAM_BOT_TOKEN:?'TELEGRAM_BOT_TOKEN not set'}"
TELEGRAM_CHAT="${TELEGRAM_CHAT_ID:?'TELEGRAM_CHAT_ID not set'}"

# --- Configuration -----------------------------------------------------------
DEVICE_CODE="lemonade"
BUILD_TARGET="Lunaris"
ANDROID_VERSION="16"

QUEUE_UPDATE_INTERVAL=1800   # 30 minutes between Telegram updates while in queue
PROGRESS_UPDATE_INTERVAL=60  # 60s between progress updates during build
STATS_UPDATE_INTERVAL=30     # 30s between stats section re-renders
POLL_INTERVAL=5              # check log file every 5 seconds

# --- State -------------------------------------------------------------------
TG_MSG_ID=""
TG_STATS_MSG_ID=""           # separate "live stats" message pinned above progress
START_TIME=$(date +%s)
START_TIME_FMT=$(date '+%Y-%m-%d %H:%M:%S %Z')
COMPLETED_STEPS=""
LAST_TG_UPDATE_ID=0
LAST_PROGRESS_UPDATE=0
LAST_STATS_UPDATE=0
LAST_QUEUE_UPDATE=0

CURRENT_STAGE="Queue ⏳"
CURRENT_DETAIL="⏳ Waiting for build cluster..."
BUILD_MODULES="bacon"

# Stats from build container (populated by [VOLT_STATS] tags)
STAT_CPU="?"
STAT_RAM_USED="?"
STAT_RAM_TOTAL="?"
STAT_RAM_PCT="?"
STAT_DISK_USED="?"
STAT_DISK_TOTAL="?"
STAT_DISK_PCT="?"
STAT_LOAD="?"
STAT_CORES="?"
STATS_AVAILABLE=0            # flips to 1 once first [VOLT_STATS] arrives

# State machine: "queuing" → "building" → "done"
PHASE="queuing"

# =============================================================================
# TELEGRAM HELPERS
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

_tg_post() {
    # $1 = method, rest = -d args
    local method="$1"; shift
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/${method}" "$@" 2>/dev/null
}

send_message() {
    local text="$1"
    local response
    response=$(_tg_post "sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT}" \
        --data-urlencode "text=${text}" \
        -d "parse_mode=HTML" \
        -d "disable_web_page_preview=true")
    echo "$response" | grep -o '"message_id":[0-9]*' | head -1 | cut -d: -f2
}

edit_message() {
    local msg_id="$1"
    local text="$2"
    _tg_post "editMessageText" \
        -d "chat_id=${TELEGRAM_CHAT}" \
        -d "message_id=${msg_id}" \
        --data-urlencode "text=${text}" \
        -d "parse_mode=HTML" \
        -d "disable_web_page_preview=true" > /dev/null
}

send_or_edit() {
    # Updates the MAIN progress message
    local text="$1"
    if [[ -z "$TG_MSG_ID" ]]; then
        TG_MSG_ID=$(send_message "$text")
    else
        edit_message "$TG_MSG_ID" "$text"
    fi
}

send_or_edit_stats() {
    # Updates the STATS message (separate message above progress)
    local text="$1"
    if [[ -z "$TG_STATS_MSG_ID" ]]; then
        TG_STATS_MSG_ID=$(send_message "$text")
    else
        edit_message "$TG_STATS_MSG_ID" "$text"
    fi
}

send_telegram_file() {
    local file_path="$1"
    local caption_text="$2"
    [[ -f "$file_path" ]] || return

    local file_size
    file_size=$(stat -c%s "$file_path" 2>/dev/null || echo "0")
    local upload_file="$file_path"

    if [[ $file_size -gt 50000000 ]]; then
        upload_file="/tmp/monitor_truncated_log.txt"
        echo "=== LOG TRUNCATED — last 48 MB ===" > "$upload_file"
        tail -c 48000000 "$file_path" >> "$upload_file"
    fi

    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendDocument" \
        -F chat_id="${TELEGRAM_CHAT}" \
        -F document=@"${upload_file}" \
        -F caption="${caption_text}" > /dev/null 2>&1 || true
}

# =============================================================================
# MESSAGE BUILDERS
# =============================================================================

elapsed_fmt() {
    local secs=$(( $(date +%s) - START_TIME ))
    (( secs < 0 )) && secs=0
    printf "%02dh %02dm %02ds" $((secs/3600)) $(((secs%3600)/60)) $((secs%60))
}

build_queue_message() {
    local detail="${1:-$CURRENT_DETAIL}"
    local elapsed
    elapsed=$(elapsed_fmt)
    echo "⏳ <b>LunarisOS — Waiting for Build Cluster</b>

• <b>ROM:</b> ${BUILD_TARGET} (Android ${ANDROID_VERSION})
• <b>Device:</b> ${DEVICE_CODE}
• <b>Modules:</b> ${BUILD_MODULES}
• <b>Waiting since:</b> ${START_TIME_FMT}
• <b>Elapsed:</b> ${elapsed}

${detail}

<i>Next update in ~30 minutes...</i>"
}

build_stats_message() {
    if [[ $STATS_AVAILABLE -eq 0 ]]; then
        return
    fi
    local cpu_bar ram_bar disk_bar
    cpu_bar=$(make_progress_bar "${STAT_CPU:-0}")
    ram_bar=$(make_progress_bar "${STAT_RAM_PCT:-0}")
    disk_bar=$(make_progress_bar "${STAT_DISK_PCT:-0}")

    echo "📊 <b>Build Container Stats</b>

🖥 <b>CPU:</b> [${cpu_bar}] ${STAT_CPU}%  (load: ${STAT_LOAD} / ${STAT_CORES} cores)
🧠 <b>RAM:</b> [${ram_bar}] ${STAT_RAM_PCT}%  (${STAT_RAM_USED} / ${STAT_RAM_TOTAL})
💾 <b>Disk:</b> [${disk_bar}] ${STAT_DISK_PCT}%  (${STAT_DISK_USED} / ${STAT_DISK_TOTAL})

<i>Updated: $(date '+%H:%M:%S %Z')</i>"
}

build_progress_message() {
    local detail="${1:-$CURRENT_DETAIL}"
    local elapsed
    elapsed=$(elapsed_fmt)

    echo "⚙️ <b>LunarisOS Build</b>

• <b>ROM:</b> ${BUILD_TARGET} (Android ${ANDROID_VERSION})
• <b>Device:</b> ${DEVICE_CODE}
• <b>Modules:</b> ${BUILD_MODULES}
• <b>Started:</b> ${START_TIME_FMT}
• <b>Elapsed:</b> ${elapsed}

<b>Steps:</b>
${COMPLETED_STEPS}
👉 <b>${CURRENT_STAGE}:</b> ${detail}"
}

# =============================================================================
# UPDATE FUNCTIONS (respect per-phase intervals)
# =============================================================================

update_queue_telegram() {
    local now
    now=$(date +%s)
    if [[ $((now - LAST_QUEUE_UPDATE)) -lt $QUEUE_UPDATE_INTERVAL && -n "$TG_MSG_ID" ]]; then
        return   # still within 30-min window
    fi
    send_or_edit "$(build_queue_message)"
    LAST_QUEUE_UPDATE=$now
}

update_progress_telegram() {
    local now
    now=$(date +%s)
    if [[ $((now - LAST_PROGRESS_UPDATE)) -lt $PROGRESS_UPDATE_INTERVAL && -n "$TG_MSG_ID" ]]; then
        return
    fi
    send_or_edit "$(build_progress_message "$CURRENT_DETAIL")"
    LAST_PROGRESS_UPDATE=$now
}

# Force an immediate progress update regardless of interval
force_progress_update() {
    LAST_PROGRESS_UPDATE=0
    update_progress_telegram
}

update_stats_telegram() {
    [[ $STATS_AVAILABLE -eq 0 ]] && return
    local now
    now=$(date +%s)
    if [[ $((now - LAST_STATS_UPDATE)) -lt $STATS_UPDATE_INTERVAL && -n "$TG_STATS_MSG_ID" ]]; then
        return
    fi
    send_or_edit_stats "$(build_stats_message)"
    LAST_STATS_UPDATE=$now
}

# =============================================================================
# TELEGRAM COMMAND POLLING
# =============================================================================
check_telegram_commands() {
    local updates new_update_id cmd_text
    updates=$(curl -s "https://api.telegram.org/bot${TELEGRAM_TOKEN}/getUpdates?offset=$((LAST_TG_UPDATE_ID + 1))&limit=1&timeout=0" 2>/dev/null)
    new_update_id=$(echo "$updates" | grep -o '"update_id":[0-9]*' | head -1 | cut -d: -f2)
    cmd_text=$(echo "$updates" | grep -o '"text":"[^"]*"' | head -1 | cut -d'"' -f4)

    if [[ -n "$new_update_id" && "$new_update_id" != "$LAST_TG_UPDATE_ID" ]]; then
        LAST_TG_UPDATE_ID=$new_update_id
        case "$cmd_text" in
            /refresh)
                LAST_PROGRESS_UPDATE=0
                update_progress_telegram
                ;;
            /stats)
                LAST_STATS_UPDATE=0
                update_stats_telegram
                ;;
            /stop|/cancel)
                send_message "🛑 <b>Stop requested via Telegram — killing crave run...</b>" > /dev/null
                kill -TERM "$CRAVE_PID" 2>/dev/null || true
                ;;
        esac
    fi
}

# =============================================================================
# LOG PARSING
# =============================================================================
parse_log_line() {
    local line="$1"

    # --- Detect crave queue/waiting state (BEFORE volt.sh starts) ---
    if [[ "$line" == *"Selecting project"* ]]; then
        CURRENT_STAGE="Queue ⏳"
        CURRENT_DETAIL="⏳ ${line}"
        update_queue_telegram

    elif [[ "$line" == *"Waiting for build"* ]]; then
        CURRENT_STAGE="Queue ⏳"
        CURRENT_DETAIL="⏳ ${line}"
        # Always send once immediately when we enter waiting state
        if [[ $(($(date +%s) - LAST_QUEUE_UPDATE)) -gt 5 ]]; then
            send_or_edit "$(build_queue_message)"
            LAST_QUEUE_UPDATE=$(date +%s)
        fi

    # --- Stats from build container ---
    elif [[ "$line" == *"[VOLT_STATS]"* ]]; then
        local payload="${line#*\[VOLT_STATS\] }"
        # Parse key=value pairs separated by |
        local kv
        for kv in ${payload//|/ }; do
            local key="${kv%%=*}"
            local val="${kv#*=}"
            case "$key" in
                cpu)       STAT_CPU="$val" ;;
                ram_used)  STAT_RAM_USED="$val" ;;
                ram_total) STAT_RAM_TOTAL="$val" ;;
                ram_pct)   STAT_RAM_PCT="$val" ;;
                disk_used) STAT_DISK_USED="$val" ;;
                disk_total)STAT_DISK_TOTAL="$val" ;;
                disk_pct)  STAT_DISK_PCT="$val" ;;
                load)      STAT_LOAD="$val" ;;
                cores)     STAT_CORES="$val" ;;
            esac
        done
        STATS_AVAILABLE=1
        # Don't call update here; the periodic loop handles it at 30s intervals

    # --- Structured volt.sh tags ---
    elif [[ "$line" == *"[VOLT_STATUS]"* ]]; then
        local payload="${line#*\[VOLT_STATUS\] }"
        CURRENT_STAGE="${payload%%|*}"
        CURRENT_DETAIL="⏳ ${payload#*|}"
        PHASE="building"

    elif [[ "$line" == *"[VOLT_STEP]"* ]]; then
        local step_text="${line#*\[VOLT_STEP\] }"
        COMPLETED_STEPS="${COMPLETED_STEPS}${step_text}
"

    elif [[ "$line" == *"[VOLT_CONFIG]"* ]]; then
        PHASE="building"

    elif [[ "$line" == *"[VOLT_MODULES]"* ]]; then
        BUILD_MODULES="${line#*\[VOLT_MODULES\] }"
        PHASE="building"

    elif [[ "$line" == *"[VOLT_MODULE_OK]"* ]]; then
        local mod="${line#*\[VOLT_MODULE_OK\] }"
        COMPLETED_STEPS="${COMPLETED_STEPS}✅ <b>${mod}</b> (Built Successfully)
"
        CURRENT_DETAIL="✅ ${mod} done"
        force_progress_update

    elif [[ "$line" == *"[VOLT_MODULE_FAIL]"* ]]; then
        local payload="${line#*\[VOLT_MODULE_FAIL\] }"
        local mod="${payload%%|*}"
        local code="${payload#*|}"
        COMPLETED_STEPS="${COMPLETED_STEPS}❌ <b>${mod}</b> (Failed, exit ${code})
"
        CURRENT_DETAIL="🚨 ${mod} failed (exit ${code})"
        force_progress_update

    elif [[ "$line" == *"[VOLT_STALL]"* ]]; then
        local detail="${line#*\[VOLT_STALL\] }"
        CURRENT_DETAIL="⚠️ Stall: ${detail}"
        force_progress_update

    elif [[ "$line" == *"[VOLT_FATAL]"* ]]; then
        local reason="${line#*\[VOLT_FATAL\] }"
        COMPLETED_STEPS="${COMPLETED_STEPS}❌ FATAL: ${reason}
"
        CURRENT_DETAIL="🚨 FATAL: ${reason}"
        force_progress_update

    elif [[ "$line" == *"[VOLT_RESULT]"* ]]; then
        local result="${line#*\[VOLT_RESULT\] }"
        local status="${result%%|*}"
        local detail="${result#*|}"
        PHASE="done"
        case "$status" in
            SUCCESS)
                COMPLETED_STEPS="${COMPLETED_STEPS}✅ <b>All modules finished</b>
"
                CURRENT_DETAIL="✅ ${detail}"
                ;;
            FAILED)    CURRENT_DETAIL="🚨 ${detail}" ;;
            PARTIAL)   CURRENT_DETAIL="⚠️ ${detail}" ;;
            CANCELLED) CURRENT_DETAIL="🛑 Cancelled during: ${detail}" ;;
        esac
        force_progress_update
    fi

    # --- Parse ninja progress lines: [ 23% 12345/53421] ---
    if echo "$line" | grep -qE '\[ *[0-9]{1,3}% [0-9]+/[0-9]+\]'; then
        local percent done_total action_desc bar eta_line percent_num
        percent=$(echo "$line" | grep -oE '[0-9]{1,3}%' | head -n1 | tr -d '%')
        done_total=$(echo "$line" | grep -oE '[0-9]+/[0-9]+' | head -n1)
        percent="${percent:-0}"
        percent_num=$((10#$percent))
        action_desc=$(echo "$line" | sed -E 's/^.*\] *//' | cut -c1-90)
        bar=$(make_progress_bar "$percent_num")

        eta_line=""
        if (( percent_num > 0 )); then
            local elapsed est_total est_remaining
            elapsed=$(( $(date +%s) - START_TIME ))
            est_total=$(( elapsed * 100 / percent_num ))
            est_remaining=$(( est_total - elapsed ))
            (( est_remaining < 0 )) && est_remaining=0
            eta_line=$(printf "\n⏱ ETA: ~%02dh %02dm" $((est_remaining/3600)) $(((est_remaining%3600)/60)))
        fi

        CURRENT_DETAIL="⏳ [${bar}] ${percent_num}% (${done_total:-?})
🔧 ${action_desc}${eta_line}"
        PHASE="building"
    fi
}

# =============================================================================
# MAIN MONITOR LOOP
# =============================================================================

# Send the first Telegram message immediately (queue state)
send_or_edit "$(build_queue_message "⏳ Waiting for a build cluster to become available...")"
LAST_QUEUE_UPDATE=$(date +%s)

LAST_LINE_COUNT=0
TEMP_LINES_FILE="/tmp/monitor_lines_$$.tmp"

while true; do
    # ── Check if crave has exited ──
    if ! kill -0 "$CRAVE_PID" 2>/dev/null; then
        # Drain remaining log lines
        if [[ -f "$LOG_FILE" ]]; then
            local_line_count=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
            if [[ $local_line_count -gt $LAST_LINE_COUNT ]]; then
                tail -n +"$((LAST_LINE_COUNT + 1))" "$LOG_FILE" > "$TEMP_LINES_FILE" 2>/dev/null
                while IFS= read -r line; do
                    parse_log_line "$line"
                done < "$TEMP_LINES_FILE"
            fi
        fi
        # Final updates
        force_progress_update
        if [[ $STATS_AVAILABLE -eq 1 ]]; then
            LAST_STATS_UPDATE=0
            update_stats_telegram
        fi
        break
    fi

    # ── Read new log lines ──
    if [[ -f "$LOG_FILE" ]]; then
        local_line_count=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
        if [[ $local_line_count -gt $LAST_LINE_COUNT ]]; then
            tail -n +"$((LAST_LINE_COUNT + 1))" "$LOG_FILE" 2>/dev/null | head -n 500 > "$TEMP_LINES_FILE"
            while IFS= read -r line; do
                parse_log_line "$line"
            done < "$TEMP_LINES_FILE"
            LAST_LINE_COUNT=$local_line_count
        fi
    fi

    # ── Check Telegram commands ──
    check_telegram_commands

    # ── Periodic Telegram updates — rate depends on phase ──
    if [[ "$PHASE" == "queuing" ]]; then
        update_queue_telegram    # only fires every 30 minutes
    else
        update_progress_telegram  # fires every 60s
        update_stats_telegram     # fires every 30s
    fi

    sleep "$POLL_INTERVAL"
done

rm -f "$TEMP_LINES_FILE"
echo "Monitor: crave exited. Shutting down."
exit 0
