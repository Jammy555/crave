#!/bin/bash
#
# =============================================================================
#  LunarisOS Build Monitor v2 — runner-side Telegram reporter
# =============================================================================
#
#  USAGE:  ./monitor.sh <LOG_FILE> <CRAVE_PID> &
#
#  REQUIRED ENV VARS (from GitHub Secrets via workflow env: block):
#    TELEGRAM_BOT_TOKEN
#    TELEGRAM_CHAT_ID
#
#  DESIGN:
#    • ONE live Telegram message — created at queue time, edited throughout.
#    • Stats (CPU/RAM/Disk) embedded inline in the same message, optional.
#    • On failure → sendDocument with last 500 log lines as a .txt file.
#    • InlineKeyboard buttons: [🔄 Refresh] [📊 Stats] [🛑 Stop]
#    • Queue updates: every 30 min  (rate-limit safe for 6+ hr waits)
#    • Progress updates: every 60s
#    • Stats refresh inside message: every 30s
#
#  TAGS from volt.sh stdout:
#    [VOLT_STATUS]       current step
#    [VOLT_STEP]         step completed
#    [VOLT_MODULE_OK]    module success
#    [VOLT_MODULE_FAIL]  module failure
#    [VOLT_STALL]        stall detected
#    [VOLT_FATAL]        fatal error
#    [VOLT_RESULT]       final result (SUCCESS/FAILED/PARTIAL/CANCELLED)
#    [VOLT_STATS]        cpu=x|ram_used=x|ram_total=x|ram_pct=x|disk_used=x|disk_total=x|disk_pct=x|load=x|cores=x
#  TAGS from crave itself:
#    "Selecting project ..."
#    "Waiting for build id:..."
# =============================================================================

set -u

LOG_FILE="${1:?'Usage: monitor.sh <LOG_FILE> <CRAVE_PID> <PROJECT_DIR>'}"
CRAVE_PID="${2:?'Usage: monitor.sh <LOG_FILE> <CRAVE_PID> <PROJECT_DIR>'}"
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

PHASE="queuing"       # queuing | building | done
CURRENT_STAGE="Queue ⏳"
CURRENT_DETAIL="Waiting for a build cluster..."
COMPLETED_STEPS=""
BUILD_MODULES="bacon"
LAST_EDIT_EPOCH=0
LAST_STATS_EPOCH=0
LAST_QUEUE_EPOCH=0

# Stats (populated by [VOLT_STATS])
STAT_CPU=""; STAT_RAM_USED=""; STAT_RAM_TOTAL=""; STAT_RAM_PCT=""
STAT_DISK_USED=""; STAT_DISK_TOTAL=""; STAT_DISK_PCT=""
STAT_LOAD=""; STAT_CORES=""; STATS_AVAILABLE=0

# Telegram update offset for command polling
TG_OFFSET=0

LAST_LINE_COUNT=0
TEMP_FILE="/tmp/monitor_lines_$$.tmp"

# ─── Helpers ───────────────────────────────────────────────────────────────
elapsed() {
    local s=$(( $(date +%s) - START_EPOCH ))
    (( s < 0 )) && s=0
    printf '%02dh %02dm %02ds' $((s/3600)) $(((s%3600)/60)) $((s%60))
}

pbar() {
    local pct="${1:-0}" w=14
    pct=$((10#$pct))
    local f=$(( pct * w / 100 )) e=$(( w - pct * w / 100 )) bar=""
    for ((i=0;i<f;i++)); do bar+="▓"; done
    for ((i=0;i<e;i++)); do bar+="░"; done
    echo "$bar"
}

# ─── Telegram API wrappers ─────────────────────────────────────────────────
_curl_tg() {
    curl -s -X POST "${TG_API}/$1" "${@:2}" 2>/dev/null
}

tg_send() {
    # $1 = text, optional $2 = reply_markup JSON
    local text="$1"
    local markup="${2:-}"
    local args=( -d "chat_id=${TELEGRAM_CHAT}" -d "parse_mode=HTML" \
                 -d "disable_web_page_preview=true" \
                 --data-urlencode "text=${text}" )
    [[ -n "$markup" ]] && args+=( -d "reply_markup=${markup}" )
    local resp
    resp=$(_curl_tg "sendMessage" "${args[@]}")
    echo "$resp" | grep -o '"message_id":[0-9]*' | head -1 | cut -d: -f2
}

tg_edit() {
    local msg_id="$1" text="$2"
    local markup="${3:-}"
    local args=( -d "chat_id=${TELEGRAM_CHAT}" -d "message_id=${msg_id}" \
                 -d "parse_mode=HTML" -d "disable_web_page_preview=true" \
                 --data-urlencode "text=${text}" )
    [[ -n "$markup" ]] && args+=( -d "reply_markup=${markup}" )
    _curl_tg "editMessageText" "${args[@]}" > /dev/null
}

tg_doc() {
    # Send a file as a document
    local filepath="$1" caption="$2"
    [[ -f "$filepath" ]] || return 0
    _curl_tg "sendDocument" \
        -F "chat_id=${TELEGRAM_CHAT}" \
        -F "document=@${filepath}" \
        --form-string "caption=${caption}" \
        --form-string "parse_mode=HTML" > /dev/null
}

tg_pin() {
    local msg_id="$1"
    _curl_tg "pinChatMessage" \
        -d "chat_id=${TELEGRAM_CHAT}" \
        -d "message_id=${msg_id}" \
        -d "disable_notification=true" > /dev/null
}

# Inline keyboard: shown on the live message
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

    if [[ "$PHASE" == "queuing" ]]; then
        printf '⏳ <b>LunarisOS — Queuing</b>\n\n• Device: lemonade\n• Modules: %s\n• Since: %s\n• Waiting: %s\n\n%s\n\n<i>Next update in ~30 min</i>' \
            "$BUILD_MODULES" "$START_FMT" "$elapsed_str" "$CURRENT_DETAIL"
        return
    fi

    local steps_section=""
    if [[ -n "$COMPLETED_STEPS" ]]; then
        steps_section="
<b>Steps:</b>
${COMPLETED_STEPS}"
    fi

    printf '⚙️ <b>LunarisOS Build</b>\n\n• Device: lemonade  |  Modules: %s\n• Started: %s\n• Elapsed: %s\n%s\n━━━━━━━━━━━━━━━━━━━━━━━━\n👉 <b>%s</b>\n%s%s' \
        "$BUILD_MODULES" "$START_FMT" "$elapsed_str" \
        "$steps_section" \
        "$CURRENT_STAGE" "$CURRENT_DETAIL" \
        "$stats_block"
}

# ─── Send/edit the live message ─────────────────────────────────────────────
publish_message() {
    local now
    now=$(date +%s)
    local text
    text=$(build_message)

    if [[ -z "$MSG_ID" ]]; then
        MSG_ID=$(tg_send "$text" "$KEYBOARD")
        [[ -n "$MSG_ID" ]] && tg_pin "$MSG_ID"
        LAST_EDIT_EPOCH=$now
    else
        tg_edit "$MSG_ID" "$text" "$KEYBOARD"
        LAST_EDIT_EPOCH=$now
    fi
}

# Force-publish (bypass interval gate)
force_publish() {
    LAST_EDIT_EPOCH=0
    LAST_QUEUE_EPOCH=0
    publish_message
}

# Interval-gated publish
maybe_publish() {
    local now
    now=$(date +%s)
    if [[ "$PHASE" == "queuing" ]]; then
        if [[ $((now - LAST_QUEUE_EPOCH)) -ge $QUEUE_INTERVAL || -z "$MSG_ID" ]]; then
            publish_message
            LAST_QUEUE_EPOCH=$now
        fi
    else
        if [[ $((now - LAST_EDIT_EPOCH)) -ge $PROGRESS_INTERVAL || -z "$MSG_ID" ]]; then
            publish_message
        fi
    fi

    # Stats refresh (every 30s) — just re-edits if stats changed
    if [[ $STATS_AVAILABLE -eq 1 && $((now - LAST_STATS_EPOCH)) -ge $STATS_INTERVAL ]]; then
        publish_message
        LAST_STATS_EPOCH=$now
    fi
}

# ─── Send failure log as document ──────────────────────────────────────────
send_failure_log() {
    local exit_code="$1"
    local ts
    ts=$(date '+%Y%m%d_%H%M%S' -u)

    # Save full log inside the clone dir (PROJECT_DIR/build_logs/)
    local log_dir="${PROJECT_DIR}/build_logs"
    mkdir -p "$log_dir" 2>/dev/null || true
    local log_save="${log_dir}/build_${ts}.log"
    cp "$LOG_FILE" "$log_save" 2>/dev/null && \
        echo "Full build log saved to: $log_save" || \
        echo "Warning: could not save log to $log_save"

    # Extract last 500 lines to send as Telegram document
    local log_send="/tmp/build_failure_${ts}.txt"
    { echo "=== Build Log (last 500 lines) — saved full log: ${log_save} ===";
      tail -500 "$LOG_FILE" 2>/dev/null || echo "No log available"; } > "$log_send"

    local caption
    caption="$(printf '❌ <b>Build Failed</b>\nExit: %s  |  Modules: %s\nElapsed: %s\n\n<i>Last 500 log lines attached.\nFull log: %s</i>' \
        "$exit_code" "$BUILD_MODULES" "$(elapsed)" "$log_save")"

    tg_doc "$log_send" "$caption"
    rm -f "$log_send"
}

# ─── Telegram command polling ───────────────────────────────────────────────
poll_commands() {
    local resp update_id text
    resp=$(_curl_tg "getUpdates" -d "offset=$((TG_OFFSET+1))" -d "limit=5" -d "timeout=0" 2>/dev/null)
    local ids texts
    ids=$(echo "$resp" | grep -o '"update_id":[0-9]*' | cut -d: -f2)
    texts=$(echo "$resp" | grep -o '"text":"[^"]*"' | cut -d'"' -f4)

    local last_id
    last_id=$(echo "$ids" | tail -1)
    [[ -n "$last_id" ]] && TG_OFFSET=$last_id

    for cmd in $texts; do
        case "$cmd" in
            /refresh|refresh) force_publish ;;
            /stats|stats)
                LAST_STATS_EPOCH=0
                publish_message
                ;;
            /stop|stop|/cancel|cancel)
                CURRENT_DETAIL="🛑 Stop requested via Telegram"
                force_publish
                kill -TERM "$CRAVE_PID" 2>/dev/null || true
                ;;
        esac
    done
}

# ─── Log parser ─────────────────────────────────────────────────────────────
parse_line() {
    local line="$1"

    case "$line" in
        *"Selecting project"*)
            CURRENT_STAGE="Queue ⏳"
            CURRENT_DETAIL="$line"
            LAST_QUEUE_EPOCH=0
            maybe_publish
            ;;
        *"Waiting for build"*)
            CURRENT_STAGE="Queue ⏳"
            CURRENT_DETAIL="$line"
            if [[ $(($(date +%s) - LAST_QUEUE_EPOCH)) -gt 10 ]]; then
                force_publish
            fi
            ;;
        *"[VOLT_STATS]"*)
            local payload="${line#*\[VOLT_STATS\] }"
            local kv
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
            # Don't force publish — let the 30s stats interval handle it
            ;;
        *"[VOLT_STATUS]"*)
            local payload="${line#*\[VOLT_STATUS\] }"
            CURRENT_STAGE="${payload%%|*}"
            CURRENT_DETAIL="${payload#*|}"
            PHASE="building"
            ;;
        *"[VOLT_STEP]"*)
            COMPLETED_STEPS="${COMPLETED_STEPS}${line#*\[VOLT_STEP\] }"$'\n'
            ;;
        *"[VOLT_MODULES]"*)
            BUILD_MODULES="${line#*\[VOLT_MODULES\] }"
            PHASE="building"
            ;;
        *"[VOLT_MODULE_OK]"*)
            local mod="${line#*\[VOLT_MODULE_OK\] }"
            COMPLETED_STEPS="${COMPLETED_STEPS}✅ <b>${mod}</b> — OK"$'\n'
            CURRENT_DETAIL="✅ ${mod} complete"
            PHASE="building"
            force_publish
            ;;
        *"[VOLT_MODULE_FAIL]"*)
            local payload="${line#*\[VOLT_MODULE_FAIL\] }"
            local mod="${payload%%|*}" code="${payload#*|}"
            COMPLETED_STEPS="${COMPLETED_STEPS}❌ <b>${mod}</b> — Failed (exit ${code})"$'\n'
            CURRENT_DETAIL="❌ ${mod} failed (exit ${code})"
            PHASE="building"
            force_publish
            ;;
        *"[VOLT_STALL]"*)
            CURRENT_DETAIL="⚠️ Stall: ${line#*\[VOLT_STALL\] }"
            force_publish
            ;;
        *"[VOLT_FATAL]"*)
            local reason="${line#*\[VOLT_FATAL\] }"
            COMPLETED_STEPS="${COMPLETED_STEPS}❌ FATAL: ${reason}"$'\n'
            CURRENT_DETAIL="🚨 FATAL: ${reason}"
            PHASE="building"
            force_publish
            ;;
        *"[VOLT_RESULT]"*)
            local result="${line#*\[VOLT_RESULT\] }"
            local status="${result%%|*}" detail="${result#*|}"
            PHASE="done"
            case "$status" in
                SUCCESS)
                    CURRENT_STAGE="✅ Done"
                    CURRENT_DETAIL="All modules built successfully"
                    COMPLETED_STEPS="${COMPLETED_STEPS}✅ <b>All done</b>"$'\n'
                    ;;
                FAILED)
                    CURRENT_STAGE="❌ Failed"
                    CURRENT_DETAIL="$detail"
                    force_publish
                    send_failure_log "1"
                    ;;
                PARTIAL)
                    CURRENT_STAGE="⚠️ Partial"
                    CURRENT_DETAIL="$detail"
                    force_publish
                    send_failure_log "1"
                    ;;
                CANCELLED) CURRENT_STAGE="🛑 Cancelled"; CURRENT_DETAIL="$detail" ;;
            esac
            force_publish
            ;;
    esac

    # Ninja progress: [ 23% 12345/53421]
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

        CURRENT_DETAIL="[${bar}] ${pnum}% (${dtotal:-?})${eta}"$'\n'"🔧 ${action}"
        PHASE="building"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════

# Initial message — queue state
PHASE="queuing"
force_publish

while true; do
    # Crave exited?
    if ! kill -0 "$CRAVE_PID" 2>/dev/null; then
        # Drain remaining log lines
        if [[ -f "$LOG_FILE" ]]; then
            local_count=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
            if (( local_count > LAST_LINE_COUNT )); then
                tail -n +"$((LAST_LINE_COUNT + 1))" "$LOG_FILE" > "$TEMP_FILE" 2>/dev/null
                while IFS= read -r line; do parse_line "$line"; done < "$TEMP_FILE"
                LAST_LINE_COUNT=$local_count
            fi
        fi
        # Final edit
        force_publish
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
echo "Monitor: done."
