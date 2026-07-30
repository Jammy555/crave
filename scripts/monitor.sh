#!/bin/bash
#
# =============================================================================
#  LunarisOS Build Monitor — runs on the GitHub Actions runner (devspace)
# =============================================================================
#
#  This script monitors the streamed output of `crave run` and sends
#  live Telegram updates. It runs as a BACKGROUND process alongside
#  the main `crave run` command.
#
#  USAGE:
#    ./monitor.sh <LOG_FILE> <CRAVE_PID> &
#
#  REQUIRED ENVIRONMENT VARIABLES:
#    TELEGRAM_BOT_TOKEN  — Telegram bot token (from GitHub Secrets)
#    TELEGRAM_CHAT_ID    — Telegram chat ID (from GitHub Secrets)
#
#  The monitor reads structured tags from volt.sh stdout:
#    [VOLT_START]        — Build started
#    [VOLT_CONFIG]       — Build configuration
#    [VOLT_STATUS]       — Current step status
#    [VOLT_STEP]         — Step completed
#    [VOLT_MODULE_OK]    — Module built successfully
#    [VOLT_MODULE_FAIL]  — Module failed
#    [VOLT_STALL]        — Build stall detected
#    [VOLT_RESULT]       — Final result
#    [VOLT_FATAL]        — Fatal error
# =============================================================================

set -u

# --- Arguments ---------------------------------------------------------------
LOG_FILE="${1:?'Usage: monitor.sh <LOG_FILE> <CRAVE_PID>'}"
CRAVE_PID="${2:?'Usage: monitor.sh <LOG_FILE> <CRAVE_PID>'}"

# --- Credentials from environment (GitHub Secrets) ---------------------------
TELEGRAM_TOKEN="${TELEGRAM_BOT_TOKEN:?'TELEGRAM_BOT_TOKEN not set'}"
TELEGRAM_CHAT="${TELEGRAM_CHAT_ID:?'TELEGRAM_CHAT_ID not set'}"

# --- Configuration -----------------------------------------------------------
DEVICE_CODE="lemonade"
BUILD_TARGET="Lunaris"
ANDROID_VERSION="16"
UPDATE_INTERVAL=60       # Send Telegram update every 60 seconds
POLL_INTERVAL=5          # Check log file every 5 seconds

# --- State -------------------------------------------------------------------
TG_MSG_ID=""
START_TIME=$(date +%s)
START_TIME_FMT=$(date '+%Y-%m-%d %H:%M:%S %Z')
COMPLETED_STEPS=""
LAST_TG_UPDATE_ID=0
CURRENT_STAGE="Initializing"
CURRENT_DETAIL="Starting..."
LAST_UPDATE_TIME=0
BUILD_MODULES="bacon"

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

send_or_edit_message() {
    local message="$1"

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

send_telegram_file() {
    local file_path="$1"
    local caption_text="$2"

    if [ ! -f "$file_path" ]; then
        return
    fi

    # Telegram file limit: 50MB. Truncate if larger.
    local file_size
    file_size=$(stat -c%s "$file_path" 2>/dev/null || echo "0")
    local upload_file="$file_path"

    if [[ $file_size -gt 50000000 ]]; then
        upload_file="/tmp/monitor_truncated_log.txt"
        echo "=== LOG TRUNCATED (last 48MB of ${file_size} bytes) ===" > "$upload_file"
        tail -c 48000000 "$file_path" >> "$upload_file"
    fi

    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendDocument" \
        -F chat_id="${TELEGRAM_CHAT}" \
        -F document=@"${upload_file}" \
        -F caption="${caption_text}" > /dev/null 2>&1 || true
}

build_status_message() {
    local status_line="$1"

    local CURRENT_TIME DURATION H M S DURATION_FMT
    CURRENT_TIME=$(date +%s)
    DURATION=$((CURRENT_TIME - START_TIME))
    H=$((DURATION/3600)); M=$(((DURATION%3600)/60)); S=$((DURATION%60))
    DURATION_FMT=$(printf "%02d hrs, %02d mins, %02d secs" "$H" "$M" "$S")

    local message="⚙️ <b>LunarisOS Build Monitor</b>

• <b>ROM:</b> ${BUILD_TARGET}
• <b>Device:</b> ${DEVICE_CODE}
• <b>Android:</b> ${ANDROID_VERSION}
• <b>Server:</b> foss.crave.io
• <b>Start Time:</b> ${START_TIME_FMT}
• <b>Elapsed:</b> ${DURATION_FMT}

<b>Task Progress:</b>
${COMPLETED_STEPS}"

    if [ -n "$status_line" ]; then
        message="${message}👉 <b>${CURRENT_STAGE}:</b> ${status_line}"
    fi

    echo "$message"
}

update_telegram() {
    local detail="${1:-$CURRENT_DETAIL}"
    local message
    message=$(build_status_message "$detail")
    send_or_edit_message "$message"
    LAST_UPDATE_TIME=$(date +%s)
}

# =============================================================================
# TELEGRAM COMMAND POLLING
# =============================================================================
check_telegram_commands() {
    local updates new_update_id cmd_text
    updates=$(curl -s "https://api.telegram.org/bot${TELEGRAM_TOKEN}/getUpdates?offset=$((LAST_TG_UPDATE_ID + 1))&limit=1" 2>/dev/null)
    new_update_id=$(echo "$updates" | grep -o '"update_id":[0-9]*' | head -n 1 | cut -d':' -f2)
    cmd_text=$(echo "$updates" | grep -o '"text":"[^"]*"' | head -n 1 | cut -d'"' -f4)

    if [[ -n "$new_update_id" ]]; then
        LAST_TG_UPDATE_ID=$new_update_id
        if [[ "$cmd_text" == "/refresh" ]]; then
            update_telegram "🔄 Manual refresh triggered!"
        elif [[ "$cmd_text" == "/stop" || "$cmd_text" == "/cancel" ]]; then
            curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
                -d "chat_id=${TELEGRAM_CHAT}" \
                -d "text=🛑 <b>Stop requested via Telegram</b> — killing crave run..." \
                -d "parse_mode=HTML" > /dev/null
            kill -TERM "$CRAVE_PID" 2>/dev/null || true
        fi
    fi
}

# =============================================================================
# LOG PARSING
# =============================================================================
parse_log_line() {
    local line="$1"

    # --- Detect crave queue/waiting state ---
    # crave run outputs these BEFORE volt.sh even starts:
    #   "Selecting project LOS 22.1 (id:93)"
    #   "Waiting for build id:274833 to start..."
    if [[ "$line" == *"Selecting project"* ]]; then
        CURRENT_STAGE="Queue ⏳"
        CURRENT_DETAIL="⏳ ${line}"
        update_telegram "$CURRENT_DETAIL"

    elif [[ "$line" == *"Waiting for build"* ]]; then
        CURRENT_STAGE="Queue ⏳"
        CURRENT_DETAIL="⏳ ${line}"
        # Always update Telegram on waiting state so user sees it
        update_telegram "$CURRENT_DETAIL"

    # Parse structured volt.sh tags
    elif [[ "$line" == *"[VOLT_STATUS]"* ]]; then
        local payload="${line#*\[VOLT_STATUS\] }"
        CURRENT_STAGE="${payload%%|*}"
        CURRENT_DETAIL="⏳ ${payload#*|}"

    elif [[ "$line" == *"[VOLT_STEP]"* ]]; then
        local step_text="${line#*\[VOLT_STEP\] }"
        COMPLETED_STEPS="${COMPLETED_STEPS}${step_text}
"

    elif [[ "$line" == *"[VOLT_CONFIG]"* ]]; then
        local config="${line#*\[VOLT_CONFIG\] }"
        # Extract build modules if present
        BUILD_MODULES=$(echo "$config" | grep -oP 'modules=\K.*' || echo "bacon")

    elif [[ "$line" == *"[VOLT_MODULES]"* ]]; then
        BUILD_MODULES="${line#*\[VOLT_MODULES\] }"

    elif [[ "$line" == *"[VOLT_MODULE_OK]"* ]]; then
        local mod="${line#*\[VOLT_MODULE_OK\] }"
        COMPLETED_STEPS="${COMPLETED_STEPS}✅ <b>${mod}</b> (Built Successfully)
"
        update_telegram "✅ ${mod} completed!"

    elif [[ "$line" == *"[VOLT_MODULE_FAIL]"* ]]; then
        local payload="${line#*\[VOLT_MODULE_FAIL\] }"
        local mod="${payload%%|*}"
        local code="${payload#*|}"
        COMPLETED_STEPS="${COMPLETED_STEPS}❌ <b>${mod}</b> (Failed, exit ${code})
"
        update_telegram "🚨 ${mod} failed (exit ${code})"

    elif [[ "$line" == *"[VOLT_STALL]"* ]]; then
        local detail="${line#*\[VOLT_STALL\] }"
        update_telegram "⚠️ Build stall detected: ${detail}"

    elif [[ "$line" == *"[VOLT_FATAL]"* ]]; then
        local reason="${line#*\[VOLT_FATAL\] }"
        COMPLETED_STEPS="${COMPLETED_STEPS}❌ FATAL: ${reason}
"
        update_telegram "🚨 FATAL: ${reason}"

    elif [[ "$line" == *"[VOLT_RESULT]"* ]]; then
        local result="${line#*\[VOLT_RESULT\] }"
        local status="${result%%|*}"
        local detail="${result#*|}"
        case "$status" in
            SUCCESS)
                COMPLETED_STEPS="${COMPLETED_STEPS}✅ <b>All modules finished successfully</b>
"
                update_telegram "✅ ${detail}"
                ;;
            FAILED)
                update_telegram "🚨 ${detail}"
                ;;
            PARTIAL)
                update_telegram "⚠️ ${detail}"
                ;;
            CANCELLED)
                update_telegram "🛑 Build cancelled during: ${detail}"
                ;;
        esac
    fi

    # Parse ninja progress lines: [ 23% 12345/53421]
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
            eta_line=$(printf "\n⏱ ETA: ~%02dh %02dm remaining" $((est_remaining/3600)) $(((est_remaining%3600)/60)))
        fi

        CURRENT_DETAIL="⏳ [${bar}] ${percent_num}% (${done_total:-?})
🔧 ${action_desc}${eta_line}"
    fi
}

# =============================================================================
# MAIN MONITOR LOOP
# =============================================================================

# Initial Telegram message
update_telegram "⏳ Starting build..."

# Track where we are in the log file
LAST_LINE_COUNT=0
TEMP_LINES_FILE="/tmp/monitor_new_lines.$$"

while true; do
    # Check if crave is still running
    if ! kill -0 "$CRAVE_PID" 2>/dev/null; then
        # Process any remaining log lines
        if [[ -f "$LOG_FILE" ]]; then
            local_line_count=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
            if [[ $local_line_count -gt $LAST_LINE_COUNT ]]; then
                tail -n +"$((LAST_LINE_COUNT + 1))" "$LOG_FILE" > "$TEMP_LINES_FILE" 2>/dev/null
                while IFS= read -r line; do
                    parse_log_line "$line"
                done < "$TEMP_LINES_FILE"
            fi
        fi
        # Final update
        update_telegram "${CURRENT_DETAIL}"
        break
    fi

    # Read new lines from log file (avoid subshell with < redirect)
    if [[ -f "$LOG_FILE" ]]; then
        local_line_count=$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")
        if [[ $local_line_count -gt $LAST_LINE_COUNT ]]; then
            tail -n +"$((LAST_LINE_COUNT + 1))" "$LOG_FILE" 2>/dev/null | head -n 200 > "$TEMP_LINES_FILE"
            while IFS= read -r line; do
                parse_log_line "$line"
            done < "$TEMP_LINES_FILE"
            LAST_LINE_COUNT=$local_line_count
        fi
    fi

    # Check Telegram commands
    check_telegram_commands

    # Periodic Telegram update
    now=$(date +%s)
    if [[ $((now - LAST_UPDATE_TIME)) -ge $UPDATE_INTERVAL ]]; then
        update_telegram
    fi

    sleep "$POLL_INTERVAL"
done

# Cleanup temp file
rm -f "$TEMP_LINES_FILE"

echo "Monitor: crave process exited. Monitor shutting down."
exit 0

