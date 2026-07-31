#!/bin/bash
#
# =============================================================================
#  LunarisOS Build Monitor v3 — runner-side Telegram reporter
# =============================================================================
#
#  USAGE:  ./monitor.sh <LOG_FILE> <CRAVE_PID> [PROJECT_DIR] &
#
#  REQUIRED ENV VARS (from GitHub Secrets via workflow env: block):
#    TELEGRAM_BOT_TOKEN
#    TELEGRAM_CHAT_ID
#
#  DESIGN:
#    • ONE live pinned Telegram message — created at start, edited throughout.
#    • Stats (CPU/RAM/Disk) embedded inline in the same message.
#    • On failure → sendDocument with last 500 log lines as a .txt file.
#    • InlineKeyboard buttons: [🔄 Refresh] [📊 Stats] [🛑 Stop]
#    • Queue updates: every 30 min  (rate-limit safe for 6+ hr waits)
#    • Progress updates: every 60s
#    • Stats refresh inside message: every 30s
#
#  TAGS parsed from volt.sh / crave stdout:
#    [VOLT_START]        build has begun inside container
#    [VOLT_CONFIG]       device/rom/android/branch info
#    [VOLT_MODULES]      which modules will be built
#    [VOLT_STATUS]       current step description (step|detail)
#    [VOLT_STEP]         step completed
#    [VOLT_MODULE_OK]    module success
#    [VOLT_MODULE_FAIL]  module failure (module|exit_code)
#    [VOLT_STALL]        stall detected
#    [VOLT_FATAL]        fatal error
#    [VOLT_RESULT]       final result (SUCCESS/FAILED/PARTIAL/CANCELLED|detail)
#    [VOLT_STATS]        cpu=x|ram_used=x|ram_total=x|...
#
#  Also parses raw crave stream lines:
#    "Setting up workspace..."
#    "Pulling container image..."
#    "Selecting project ..."
#    "Waiting for build id:..."
# =============================================================================

set -u

LOG_FILE="${1:?'Usage: monitor.sh <LOG_FILE> <CRAVE_PID> [PROJECT_DIR]'}"
CRAVE_PID="${2:?'Usage: monitor.sh <LOG_FILE> <CRAVE_PID> [PROJECT_DIR]'}"
PROJECT_DIR="${3:-/tmp}"   # crave clone dir — logs saved here

TELEGRAM_TOKEN="${TELEGRAM_BOT_TOKEN:?'TELEGRAM_BOT_TOKEN not set'}"
TELEGRAM_CHAT="${TELEGRAM_CHAT_ID:?'TELEGRAM_CHAT_ID not set'}"
TG_API="https://api.telegram.org/bot${TELEGRAM_TOKEN}"

# ─── Timing ────────────────────────────────────────────────────────────────
QUEUE_INTERVAL=1800   # 30 min between edits during queue wait
PROGRESS_INTERVAL=60  # 60s between edits during build
STATS_INTERVAL=30     # 30s between stats refresh inside message
POLL_INTERVAL=5       # log file poll rate

# ─── State ─────────────────────────────────────────────────────────────────
MSG_ID=""             # the ONE live Telegram message
START_EPOCH=$(date +%s)
START_FMT=$(date '+%Y-%m-%d %H:%M:%S UTC' -u)

# Phase: queuing → setup → syncing → building → done
PHASE="queuing"
CURRENT_STAGE="Queue ⏳"
CURRENT_DETAIL="Waiting for crave cluster..."
COMPLETED_STEPS=""
BUILD_MODULES="bacon"
DEVICE_NAME="lemonade"
ROM_NAME="Lunaris"
ANDROID_VER="16"
LAST_EDIT_EPOCH=0
LAST_STATS_EPOCH=0
LAST_QUEUE_EPOCH=0
LAST_PROGRESS_EPOCH=0

# Stats (populated by [VOLT_STATS])
STAT_CPU=""; STAT_RAM_USED=""; STAT_RAM_TOTAL=""; STAT_RAM_PCT=""
STAT_DISK_USED=""; STAT_DISK_TOTAL=""; STAT_DISK_PCT=""
STAT_LOAD=""; STAT_CORES=""; STATS_AVAILABLE=0

# Telegram update offset for callback_query polling
TG_OFFSET=0

LAST_LINE_COUNT=0
TEMP_FILE="/tmp/monitor_lines_$$.tmp"

# ─── Debug logger ──────────────────────────────────────────────────────────
MONITOR_LOG="/tmp/monitor_debug_$$.log"
dbg() {
    echo "[$(date '+%H:%M:%S')] $*" >> "$MONITOR_LOG"
}

dbg "Monitor started — LOG_FILE=$LOG_FILE CRAVE_PID=$CRAVE_PID PROJECT_DIR=$PROJECT_DIR"

# ─── Helpers ───────────────────────────────────────────────────────────────
elapsed() {
    local s=$(( $(date +%s) - START_EPOCH ))
    (( s < 0 )) && s=0
    printf '%02dh %02dm %02ds' $((s/3600)) $(((s%3600)/60)) $((s%60))
}

pbar() {
    local pct="${1:-0}" w=14
    # Strip non-numeric chars safely
    pct=$(echo "$pct" | tr -dc '0-9')
    pct=${pct:-0}
    pct=$((10#$pct))
    (( pct > 100 )) && pct=100
    (( pct < 0 )) && pct=0
    local f=$(( pct * w / 100 )) e=$(( w - f )) bar=""
    for ((i=0;i<f;i++)); do bar+="▓"; done
    for ((i=0;i<e;i++)); do bar+="░"; done
    echo "$bar"
}

# ─── Telegram API wrappers ─────────────────────────────────────────────────
_curl_tg() {
    local method="$1"; shift
    curl -s -X POST "${TG_API}/${method}" "$@" 2>/dev/null
}

tg_send() {
    # $1 = text, optional $2 = reply_markup JSON
    local text="$1" markup="${2:-}"
    local args=( -d "chat_id=${TELEGRAM_CHAT}" -d "parse_mode=HTML"
                 -d "disable_web_page_preview=true"
                 --data-urlencode "text=${text}" )
    [[ -n "$markup" ]] && args+=( -d "reply_markup=${markup}" )
    local resp
    resp=$(_curl_tg "sendMessage" "${args[@]}")
    local mid
    mid=$(echo "$resp" | grep -o '"message_id":[0-9]*' | head -1 | cut -d: -f2)
    dbg "tg_send → msg_id=$mid"
    echo "$mid"
}

tg_edit() {
    local msg_id="$1" text="$2" markup="${3:-}"
    local args=( -d "chat_id=${TELEGRAM_CHAT}" -d "message_id=${msg_id}"
                 -d "parse_mode=HTML" -d "disable_web_page_preview=true"
                 --data-urlencode "text=${text}" )
    [[ -n "$markup" ]] && args+=( -d "reply_markup=${markup}" )
    local resp
    resp=$(_curl_tg "editMessageText" "${args[@]}")
    # Check if edit failed (e.g. message not modified)
    if echo "$resp" | grep -q '"error_code"'; then
        dbg "tg_edit FAIL: $(echo "$resp" | grep -o '"description":"[^"]*"')"
    fi
}

tg_doc() {
    local filepath="$1" caption="$2"
    [[ -f "$filepath" ]] || { dbg "tg_doc: file not found: $filepath"; return 0; }
    _curl_tg "sendDocument" \
        -F "chat_id=${TELEGRAM_CHAT}" \
        -F "document=@${filepath}" \
        --form-string "caption=${caption}" \
        --form-string "parse_mode=HTML" > /dev/null
    dbg "tg_doc sent: $filepath"
}

tg_pin() {
    local msg_id="$1"
    _curl_tg "pinChatMessage" \
        -d "chat_id=${TELEGRAM_CHAT}" \
        -d "message_id=${msg_id}" \
        -d "disable_notification=true" > /dev/null
}

# Inline keyboard
KEYBOARD='{"inline_keyboard":[[{"text":"🔄 Refresh","callback_data":"refresh"},{"text":"📊 Stats","callback_data":"stats"},{"text":"🛑 Stop","callback_data":"stop"}]]}'

# ─── Message builder ───────────────────────────────────────────────────────
build_message() {
    local elapsed_str
    elapsed_str=$(elapsed)

    local stats_block=""
    if [[ $STATS_AVAILABLE -eq 1 ]]; then
        local cb rb db
        cb=$(pbar "${STAT_CPU:-0}")
        rb=$(pbar "${STAT_RAM_PCT:-0}")
        db=$(pbar "${STAT_DISK_PCT:-0}")
        stats_block="
━━━━━━━━━━━━━━━━━━━━━━━━
<b>📊 Container Stats</b>
🖥 CPU   [${cb}] ${STAT_CPU}%  <i>(load ${STAT_LOAD}/${STAT_CORES})</i>
🧠 RAM   [${rb}] ${STAT_RAM_PCT}%  <i>(${STAT_RAM_USED}/${STAT_RAM_TOTAL})</i>
💾 Disk  [${db}] ${STAT_DISK_PCT}%  <i>(${STAT_DISK_USED}/${STAT_DISK_TOTAL})</i>"
    fi

    # Header varies by phase
    local header icon
    case "$PHASE" in
        queuing)  icon="⏳"; header="Queuing" ;;
        setup)    icon="📦"; header="Container Setup" ;;
        syncing)  icon="📥"; header="Syncing Sources" ;;
        building) icon="🔨"; header="Building" ;;
        done)     icon="🏁"; header="Complete" ;;
        *)        icon="⚙️"; header="Working" ;;
    esac

    local steps_section=""
    if [[ -n "$COMPLETED_STEPS" ]]; then
        steps_section="
<b>Steps:</b>
${COMPLETED_STEPS}"
    fi

    local phase_hint=""
    if [[ "$PHASE" == "queuing" ]]; then
        phase_hint="
<i>Next update in ~30 min</i>"
    fi

    printf '%s <b>LunarisOS — %s</b>\n\n• Device: %s  |  Modules: %s\n• ROM: %s (Android %s)\n• Started: %s\n• Elapsed: %s\n%s\n━━━━━━━━━━━━━━━━━━━━━━━━\n👉 <b>%s</b>\n%s%s%s' \
        "$icon" "$header" \
        "$DEVICE_NAME" "$BUILD_MODULES" \
        "$ROM_NAME" "$ANDROID_VER" \
        "$START_FMT" "$elapsed_str" \
        "$steps_section" \
        "$CURRENT_STAGE" "$CURRENT_DETAIL" \
        "$stats_block" "$phase_hint"
}

# ─── Publish logic ─────────────────────────────────────────────────────────
publish_message() {
    local now text
    now=$(date +%s)
    text=$(build_message)

    if [[ -z "$MSG_ID" ]]; then
        MSG_ID=$(tg_send "$text" "$KEYBOARD")
        [[ -n "$MSG_ID" ]] && tg_pin "$MSG_ID"
        LAST_EDIT_EPOCH=$now
        dbg "Initial message sent, MSG_ID=$MSG_ID"
    else
        tg_edit "$MSG_ID" "$text" "$KEYBOARD"
        LAST_EDIT_EPOCH=$now
    fi
}

force_publish() {
    LAST_EDIT_EPOCH=0
    LAST_QUEUE_EPOCH=0
    LAST_PROGRESS_EPOCH=0
    publish_message
}

maybe_publish() {
    local now
    now=$(date +%s)

    if [[ "$PHASE" == "queuing" ]]; then
        if [[ $((now - LAST_QUEUE_EPOCH)) -ge $QUEUE_INTERVAL || -z "$MSG_ID" ]]; then
            publish_message
            LAST_QUEUE_EPOCH=$now
        fi
    else
        if [[ $((now - LAST_PROGRESS_EPOCH)) -ge $PROGRESS_INTERVAL || -z "$MSG_ID" ]]; then
            publish_message
            LAST_PROGRESS_EPOCH=$now
        fi
    fi

    # Stats refresh (every 30s) — only if stats have been received
    if [[ $STATS_AVAILABLE -eq 1 && $((now - LAST_STATS_EPOCH)) -ge $STATS_INTERVAL ]]; then
        publish_message
        LAST_STATS_EPOCH=$now
    fi
}

# ─── Failure log upload ───────────────────────────────────────────────────
send_failure_log() {
    local exit_code="${1:-1}"
    local ts
    ts=$(date '+%Y%m%d_%H%M%S' -u)

    # Save full log inside clone dir
    local log_dir="${PROJECT_DIR}/build_logs"
    mkdir -p "$log_dir" 2>/dev/null || true
    local log_save="${log_dir}/build_${ts}.log"
    if cp "$LOG_FILE" "$log_save" 2>/dev/null; then
        dbg "Full log saved to: $log_save"
    else
        dbg "WARNING: could not save log to $log_save"
    fi

    # Telegram document with last 500 lines (filter out [VOLT_STATS] noise)
    local log_send="/tmp/build_failure_${ts}.txt"
    {
        echo "=== Build Log (last 500 lines, stats stripped) ==="
        echo "=== Full log at: ${log_save} ==="
        echo ""
        tail -500 "$LOG_FILE" 2>/dev/null | grep -v '^\[VOLT_STATS\]' || echo "No log available"
    } > "$log_send"

    local caption
    caption=$(printf '❌ <b>Build Failed</b>\nExit: %s  |  Modules: %s\nElapsed: %s\n\nFull log saved to devspace.' \
        "$exit_code" "$BUILD_MODULES" "$(elapsed)")

    tg_doc "$log_send" "$caption"
    rm -f "$log_send"
}

# ─── Telegram callback_query + text command polling ────────────────────────
poll_commands() {
    local resp
    resp=$(_curl_tg "getUpdates" -d "offset=$((TG_OFFSET+1))" -d "limit=10" -d "timeout=0")
    [[ -z "$resp" || "$resp" == '{"ok":true,"result":[]}' ]] && return

    # Advance offset
    local last_id
    last_id=$(echo "$resp" | jq -r '.result[-1].update_id // empty')
    [[ -n "$last_id" ]] && TG_OFFSET=$last_id

    # ── Callback queries (inline button presses) ────────────────────────────
    local callbacks
    callbacks=$(echo "$resp" | jq -c '.result[] | select(.callback_query != null) | {id: .callback_query.id, data: .callback_query.data}')
    
    while IFS= read -r cb; do
        [[ -z "$cb" ]] && continue
        local cb_id cb_data
        cb_id=$(echo "$cb" | jq -r '.id // empty')
        cb_data=$(echo "$cb" | jq -r '.data // empty')
        
        dbg "Callback: data=$cb_data id=$cb_id"

        # Answer the callback to dismiss spinner
        [[ -n "$cb_id" ]] && _curl_tg "answerCallbackQuery" \
            -d "callback_query_id=${cb_id}" \
            -d "text=✅ Done" > /dev/null

        handle_command "$cb_data"
    done <<< "$callbacks"

    # ── Text messages (e.g. /refresh typed in chat) ─────────────────────────
    local texts
    texts=$(echo "$resp" | jq -r '.result[] | select(.message.text != null) | .message.text')
    while IFS= read -r cmd; do
        [[ -z "$cmd" ]] && continue
        handle_command "$cmd"
    done <<< "$texts"
}

handle_command() {
    local cmd="$1"
    dbg "handle_command: $cmd"
    case "$cmd" in
        refresh|/refresh)
            force_publish
            ;;
        stats|/stats)
            LAST_STATS_EPOCH=0
            publish_message
            ;;
        stop|/stop|cancel|/cancel)
            CURRENT_DETAIL="🛑 Stop requested via Telegram"
            force_publish
            kill -TERM "$CRAVE_PID" 2>/dev/null || true
            ;;
    esac
}

# ─── Log line parser ───────────────────────────────────────────────────────
parse_line() {
    local line="$1"

    # Skip empty lines
    [[ -z "$line" ]] && return

    case "$line" in

        # ── Crave infrastructure lines (before volt.sh starts) ──────────
        *"Setting up workspace"*)
            PHASE="setup"
            CURRENT_STAGE="📦 Container Setup"
            CURRENT_DETAIL="Setting up workspace..."
            force_publish
            ;;
        *"Pulling container image"*)
            PHASE="setup"
            CURRENT_STAGE="📦 Container Setup"
            CURRENT_DETAIL="Pulling build container image..."
            ;;
        *"Finished pulling container"*)
            CURRENT_DETAIL="Container ready ✅"
            force_publish
            ;;
        *"Selecting project"*)
            PHASE="queuing"
            CURRENT_STAGE="Queue ⏳"
            CURRENT_DETAIL="$line"
            LAST_QUEUE_EPOCH=0
            maybe_publish
            ;;
        *"Waiting for build"*)
            PHASE="queuing"
            CURRENT_STAGE="Queue ⏳"
            CURRENT_DETAIL="$line"
            if [[ $(($(date +%s) - LAST_QUEUE_EPOCH)) -gt 10 ]]; then
                force_publish
            fi
            ;;

        # ── Volt.sh lifecycle tags ──────────────────────────────────────
        *"[VOLT_START]"*)
            PHASE="building"
            CURRENT_STAGE="🚀 Initialization"
            CURRENT_DETAIL="${line#*\[VOLT_START\] }"
            force_publish
            ;;
        *"[VOLT_CONFIG]"*)
            local payload="${line#*\[VOLT_CONFIG\] }"
            # Parse key=value pairs: device=lemonade rom=Lunaris android=16 branch=16.2
            for kv in $payload; do
                local k="${kv%%=*}" v="${kv#*=}"
                case "$k" in
                    device)  DEVICE_NAME="$v" ;;
                    rom)     ROM_NAME="$v" ;;
                    android) ANDROID_VER="$v" ;;
                esac
            done
            dbg "Config: device=$DEVICE_NAME rom=$ROM_NAME android=$ANDROID_VER"
            ;;
        *"[VOLT_MODULES]"*)
            BUILD_MODULES="${line#*\[VOLT_MODULES\] }"
            PHASE="building"
            dbg "Modules: $BUILD_MODULES"
            ;;

        # ── Status / step progress ──────────────────────────────────────
        *"[VOLT_STATUS]"*)
            local payload="${line#*\[VOLT_STATUS\] }"
            CURRENT_STAGE="${payload%%|*}"
            CURRENT_DETAIL="${payload#*|}"
            if [[ "$PHASE" != "done" ]]; then
                # Detect sync phase by stage name
                if echo "$CURRENT_STAGE" | grep -qi "sync"; then
                    PHASE="syncing"
                else
                    PHASE="building"
                fi
            fi
            dbg "STATUS: stage='$CURRENT_STAGE' detail='$CURRENT_DETAIL' phase=$PHASE"
            ;;
        *"[VOLT_STEP]"*)
            local step_text="${line#*\[VOLT_STEP\] }"
            COMPLETED_STEPS="${COMPLETED_STEPS}${step_text}"$'\n'
            PHASE="building"
            force_publish
            dbg "STEP: $step_text"
            ;;

        # ── Module results ──────────────────────────────────────────────
        *"[VOLT_MODULE_OK]"*)
            local mod="${line#*\[VOLT_MODULE_OK\] }"
            COMPLETED_STEPS="${COMPLETED_STEPS}✅ <b>${mod}</b> — OK"$'\n'
            CURRENT_DETAIL="✅ ${mod} complete"
            force_publish
            ;;
        *"[VOLT_MODULE_FAIL]"*)
            local payload="${line#*\[VOLT_MODULE_FAIL\] }"
            local mod="${payload%%|*}" code="${payload#*|}"
            COMPLETED_STEPS="${COMPLETED_STEPS}❌ <b>${mod}</b> — Failed (exit ${code})"$'\n'
            CURRENT_DETAIL="❌ ${mod} failed (exit ${code})"
            force_publish
            ;;

        # ── Stall / fatal ───────────────────────────────────────────────
        *"[VOLT_STALL]"*)
            CURRENT_DETAIL="⚠️ Stall: ${line#*\[VOLT_STALL\] }"
            force_publish
            ;;
        *"[VOLT_FATAL]"*)
            local reason="${line#*\[VOLT_FATAL\] }"
            COMPLETED_STEPS="${COMPLETED_STEPS}🚨 FATAL: ${reason}"$'\n'
            CURRENT_DETAIL="🚨 FATAL: ${reason}"
            force_publish
            ;;

        # ── Final result ────────────────────────────────────────────────
        *"[VOLT_RESULT]"*)
            local result="${line#*\[VOLT_RESULT\] }"
            local status="${result%%|*}" detail="${result#*|}"
            PHASE="done"
            dbg "RESULT: status=$status detail=$detail"
            case "$status" in
                SUCCESS)
                    CURRENT_STAGE="✅ Build Succeeded"
                    CURRENT_DETAIL="All modules built successfully"
                    COMPLETED_STEPS="${COMPLETED_STEPS}✅ <b>All done</b>"$'\n'
                    force_publish
                    ;;
                FAILED)
                    CURRENT_STAGE="❌ Build Failed"
                    CURRENT_DETAIL="$detail"
                    force_publish
                    send_failure_log "1"
                    ;;
                PARTIAL)
                    CURRENT_STAGE="⚠️ Partial Build"
                    CURRENT_DETAIL="$detail"
                    force_publish
                    send_failure_log "1"
                    ;;
                CANCELLED)
                    CURRENT_STAGE="🛑 Cancelled"
                    CURRENT_DETAIL="$detail"
                    force_publish
                    ;;
            esac
            ;;

        # ── Stats (parsed but not force-published) ──────────────────────
        *"[VOLT_STATS]"*)
            local payload="${line#*\[VOLT_STATS\] }"
            for kv in ${payload//|/ }; do
                local k="${kv%%=*}" v="${kv#*=}"
                case "$k" in
                    cpu)        STAT_CPU="$v" ;;
                    ram_used)   STAT_RAM_USED="$v" ;;
                    ram_total)  STAT_RAM_TOTAL="$v" ;;
                    ram_pct)    STAT_RAM_PCT="$v" ;;
                    disk_used)  STAT_DISK_USED="$v" ;;
                    disk_total) STAT_DISK_TOTAL="$v" ;;
                    disk_pct)   STAT_DISK_PCT="$v" ;;
                    load)       STAT_LOAD="$v" ;;
                    cores)      STAT_CORES="$v" ;;
                esac
            done
            STATS_AVAILABLE=1
            # Stats are included via the 30s interval in maybe_publish
            ;;
    esac

    # ── Ninja progress bar: [ 23% 12345/53421] ──────────────────────────
    if echo "$line" | grep -qE '\[ *[0-9]{1,3}% [0-9]+/[0-9]+\]'; then
        local pct dtotal action
        pct=$(echo "$line" | grep -oE '[0-9]{1,3}%' | head -1 | tr -d '%')
        dtotal=$(echo "$line" | grep -oE '[0-9]+/[0-9]+' | head -1)
        action=$(echo "$line" | sed -E 's/^.*\] *//' | cut -c1-80)
        pct="${pct:-0}"
        local pnum=$((10#$pct))
        local bar eta=""
        bar=$(pbar "$pnum")

        if (( pnum > 0 )); then
            local el=$(( $(date +%s) - START_EPOCH ))
            local et=$(( el * 100 / pnum ))
            local er=$(( et - el ))
            (( er < 0 )) && er=0
            eta=" | ETA ~$(printf '%dh%02dm' $((er/3600)) $(((er%3600)/60)))"
        fi

        CURRENT_STAGE="🔨 Building"
        CURRENT_DETAIL="[${bar}] ${pnum}% (${dtotal:-?})${eta}"$'\n'"🔧 ${action}"
        PHASE="building"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN LOOP
# ═══════════════════════════════════════════════════════════════════════════

dbg "Sending initial message..."
PHASE="queuing"
force_publish
dbg "Initial message done, MSG_ID=$MSG_ID"

while true; do
    # Check if crave process is still alive
    if ! kill -0 "$CRAVE_PID" 2>/dev/null; then
        dbg "Crave PID $CRAVE_PID is dead — draining remaining log lines"
        # Drain remaining log lines
        if [[ -f "$LOG_FILE" ]]; then
            local_count=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
            if (( local_count > LAST_LINE_COUNT )); then
                tail -n +"$((LAST_LINE_COUNT + 1))" "$LOG_FILE" > "$TEMP_FILE" 2>/dev/null
                while IFS= read -r line; do parse_line "$line"; done < "$TEMP_FILE"
                LAST_LINE_COUNT=$local_count
            fi
        fi

        # If we never got a VOLT_RESULT, the process died unexpectedly
        if [[ "$PHASE" != "done" ]]; then
            dbg "Crave exited but no VOLT_RESULT received — unexpected exit"
            CURRENT_STAGE="❌ Unexpected Exit"
            CURRENT_DETAIL="Crave process ended without a VOLT_RESULT tag"
            PHASE="done"
            force_publish
            send_failure_log "unknown"
        else
            force_publish
        fi
        break
    fi

    # Read new log lines
    if [[ -f "$LOG_FILE" ]]; then
        local_count=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        if (( local_count > LAST_LINE_COUNT )); then
            tail -n +"$((LAST_LINE_COUNT + 1))" "$LOG_FILE" 2>/dev/null | head -n 500 > "$TEMP_FILE"
            while IFS= read -r line; do parse_line "$line"; done < "$TEMP_FILE"
            LAST_LINE_COUNT=$local_count
        fi
    fi

    poll_commands
    maybe_publish

    sleep "$POLL_INTERVAL"
done

rm -f "$TEMP_FILE"
dbg "Monitor exiting."
echo "Monitor: done."
