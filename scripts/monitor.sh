#!/bin/bash
#
# =============================================================================
#  LunarisOS Build Monitor v4 — unified single-message Telegram reporter
# =============================================================================
#
#  USAGE:
#    ./monitor.sh <LOG_FILE> <STEP_PID> <PROJECT_DIR> <ATTEMPT> <MAX_RETRIES> \
#                  <BUILD_COMMAND> <RUN_URL> &
#
#  REQUIRED ENV VARS:
#    TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
#  OPTIONAL ENV VARS:
#    CRAVE_TOKEN, CRAVE_TEAM_ID   — enables live cluster queue position/stats
#
#  DESIGN (v4):
#    • ONE Telegram message for the ENTIRE workflow run — created on attempt 1,
#      edited through every retry, and finalized on success/failure/stop.
#      Continuity across attempts is kept via a small state file keyed by
#      STEP_PID (the retry loop's own PID, constant across every attempt).
#    • Collapsible sections ("expandable blockquote", Bot API 7.6+) for Steps
#      and Container Stats, so the message stays short by default.
#    • Cluster-wide queue position (running/queued totals + your place in
#      line) pulled from the crave job-list API, shown while queuing.
#    • Stop button asks for confirmation before actually stopping. A
#      confirmed stop auto-retries the SAME workflow run once.
#    • On terminal outcomes (success / real failure / glitch-exhausted /
#      confirmed stop) this script self-exits right after publishing — the
#      workflow no longer has to race a kill against a still-forming message.
#
#  TAGS parsed from volt.sh / crave stdout (unchanged contract with volt.sh):
#    [VOLT_START] [VOLT_CONFIG] [VOLT_MODULES] [VOLT_STATUS] [VOLT_STEP]
#    [VOLT_MODULE_OK] [VOLT_MODULE_FAIL] [VOLT_STALL] [VOLT_FATAL]
#    [VOLT_RESULT] [VOLT_STATS]
#
#  NEW tags — written by the WORKFLOW (not volt.sh), appended to LOG_FILE
#  after `crave run` exits, to hand the final outcome to this script instead
#  of the workflow sending its own separate message:
#    [VOLT_UPLOAD_OK]        filename|downloadlink
#    [VOLT_UPLOAD_FAIL]      filename
#    [VOLT_NO_ZIP]
#    [VOLT_GLITCH_RETRY]     delay_seconds
#    [VOLT_GLITCH_EXHAUSTED]
#    [VOLT_REAL_FAIL]        exit_code
#
#  Also parses raw crave stream lines ("Setting up workspace...", "Pulling
#  container image...", "Selecting project ...", "Waiting for build id:...").
# =============================================================================

set -u

LOG_FILE="${1:?'Usage: monitor.sh <LOG_FILE> <STEP_PID> <PROJECT_DIR> <ATTEMPT> <MAX_RETRIES> <BUILD_COMMAND> <RUN_URL> [TG_OFFSET]'}"
STEP_PID="${2:?'STEP_PID required'}"
PROJECT_DIR="${3:-/tmp}"
ATTEMPT="${4:-1}"
MAX_RETRIES="${5:-1}"
BUILD_COMMAND="${6:-}"
RUN_URL="${7:-}"
TG_OFFSET_INIT="${8:-0}"

TELEGRAM_TOKEN="${TELEGRAM_BOT_TOKEN:?'TELEGRAM_BOT_TOKEN not set'}"
TELEGRAM_CHAT="${TELEGRAM_CHAT_ID:?'TELEGRAM_CHAT_ID not set'}"
TG_API="https://api.telegram.org/bot${TELEGRAM_TOKEN}"

# ─── Crave cluster-queue API (optional — silently disables if unset) ───────
CRAVE_TOKEN="${CRAVE_TOKEN:-}"
CRAVE_TEAM_ID="${CRAVE_TEAM_ID:-14}"
CRAVE_API="https://foss.crave.io/api/job/v1/get"

# For the "🔁 Reload" button — re-fetches and exec's a fresh copy of this
# very script, same PID, so the outer workflow script's MONITOR_PID
# tracking never even notices. GITHUB_REPOSITORY/GITHUB_REF_NAME are
# GitHub Actions default env vars, already present without any workflow change.
MONITOR_SELF_URL="https://raw.githubusercontent.com/${GITHUB_REPOSITORY:-}/refs/heads/${GITHUB_REF_NAME:-main}/scripts/monitor.sh"

# ─── Timing ─────────────────────────────────────────────────────────────
QUEUE_INTERVAL=1800    # fallback full-refresh cadence while queuing
PROGRESS_INTERVAL=60   # edit cadence while building
STATS_INTERVAL=30      # container-stats refresh cadence
POLL_INTERVAL=5        # log file poll rate
QSTATS_INTERVAL=1800   # cluster-queue API poll rate (background heartbeat — Refresh button bypasses this)
INIT_RETRY_INTERVAL=15 # backoff between retries if the very first send fails (e.g. TG unreachable)

# ─── Cross-attempt state (keyed by the retry loop's stable PID) ───────────
MSG_STATE_FILE="/tmp/volt_msg_state_${STEP_PID}.txt"
STOP_SENTINEL="/tmp/volt_stop_requested_${STEP_PID}"
STOP_RETRY_USED_FILE="/tmp/volt_stop_retry_used_${STEP_PID}"

MSG_ID=""
[[ -f "$MSG_STATE_FILE" ]] && MSG_ID=$(cat "$MSG_STATE_FILE" 2>/dev/null || true)

# Validate saved MSG_ID is still alive (user might have deleted the pinned msg)
if [[ -n "$MSG_ID" ]]; then
    _validate_resp=$(_curl_tg "editMessageText" \
        -d "chat_id=${TELEGRAM_CHAT}" -d "message_id=${MSG_ID}" \
        -d "parse_mode=HTML" --data-urlencode "text=⏳ Reconnecting..." 2>/dev/null)
    if echo "$_validate_resp" | grep -q '"error_code"'; then
        dbg "Saved MSG_ID=$MSG_ID is no longer valid (deleted?) — will create a fresh message"
        MSG_ID=""
        rm -f "$MSG_STATE_FILE" 2>/dev/null || true
    else
        dbg "Saved MSG_ID=$MSG_ID validated OK"
    fi
fi

START_EPOCH=$(date +%s)
START_FMT=$(date '+%Y-%m-%d %H:%M:%S UTC' -u)

if [[ "$ATTEMPT" -gt 1 ]]; then
    PHASE="retrying"
else
    PHASE="starting"
fi
CURRENT_STAGE="Starting ⏳"
CURRENT_DETAIL="Handing off to crave..."
COMPLETED_STEPS=""
BUILD_MODULES="${BUILD_COMMAND:-bacon}"
DEVICE_NAME="lemonade"
ROM_NAME="Lunaris"
ANDROID_VER="16"
LAST_EDIT_EPOCH=0
LAST_STATS_EPOCH=0
LAST_QUEUE_EPOCH=0
LAST_WAITING_LINE_EPOCH=0
LAST_PROGRESS_EPOCH=0
SHOULD_EXIT=0

# Terminal-state info (set once a VOLT_UPLOAD_*/VOLT_*FAIL*/stop tag lands)
RESULT_KIND=""     # success | upload_fail | no_zip | real_fail | glitch_exhausted | stopped
RESULT_FILE=""
RESULT_LINK=""

# Container stats (populated by [VOLT_STATS])
STAT_CPU=""; STAT_RAM_USED=""; STAT_RAM_TOTAL=""; STAT_RAM_PCT=""
STAT_DISK_USED=""; STAT_DISK_TOTAL=""; STAT_DISK_PCT=""
STAT_LOAD=""; STAT_CORES=""; STATS_AVAILABLE=0

# Cluster queue stats
QUEUE_JOB_ID=""
STAT_Q_RUNNING=""
STAT_Q_QUEUED=""
STAT_Q_POSITION=""
STATS_Q_AVAILABLE=0
LAST_Q_FETCH_EPOCH=0
LAST_Q_POSITION=""
LAST_Q_RUNNING=""
LAST_Q_QUEUED=""

TG_OFFSET=$TG_OFFSET_INIT
LAST_LINE_COUNT=0
TEMP_FILE="/tmp/monitor_lines_$$.tmp"

MONITOR_LOG="/tmp/monitor_debug_$$.log"
dbg() { echo "[$(date '+%H:%M:%S')] $*" >> "$MONITOR_LOG"; }

# Call on any real terminal outcome reached within THIS run (success,
# real failure, glitch-exhausted, confirmed stop) — nothing left to resume.
clear_tracked_job() {
    rm -f "${PROJECT_DIR}/.crave_tracked_job.json" 2>/dev/null || true
}
dbg "Monitor v4 started — attempt=${ATTEMPT}/${MAX_RETRIES} LOG_FILE=$LOG_FILE STEP_PID=$STEP_PID resuming_msg=${MSG_ID:-none}"

# ─── Helpers ────────────────────────────────────────────────────────────
elapsed() {
    local s=$(( $(date +%s) - START_EPOCH ))
    (( s < 0 )) && s=0
    printf '%02dh %02dm %02ds' $((s/3600)) $(((s%3600)/60)) $((s%60))
}

pbar() {
    local pct="${1:-0}" w=14
    pct=$(echo "$pct" | tr -dc '0-9'); pct=${pct:-0}; pct=$((10#$pct))
    (( pct > 100 )) && pct=100
    (( pct < 0 )) && pct=0
    local f e bar
    f=$(( pct * w / 100 ))
    e=$(( w - f ))
    bar=""
    for ((i=0;i<f;i++)); do bar+="▓"; done
    for ((i=0;i<e;i++)); do bar+="░"; done
    echo "$bar"
}

# ─── Telegram API wrappers ──────────────────────────────────────────────
_curl_tg() { local method="$1"; shift; curl -s -m 20 -X POST "${TG_API}/${method}" "$@" 2>/dev/null; }

tg_send() {
    local text="$1" markup="${2:-}"
    local args=( -d "chat_id=${TELEGRAM_CHAT}" -d "parse_mode=HTML"
                 -d "disable_web_page_preview=true" --data-urlencode "text=${text}" )
    [[ -n "$markup" ]] && args+=( -d "reply_markup=${markup}" )
    local resp; resp=$(_curl_tg "sendMessage" "${args[@]}")
    local mid; mid=$(echo "$resp" | grep -o '"message_id":[0-9]*' | head -1 | cut -d: -f2)
    dbg "tg_send -> msg_id=$mid"
    echo "$mid"
}

tg_edit() {
    local msg_id="$1" text="$2" markup="${3:-}"
    local args=( -d "chat_id=${TELEGRAM_CHAT}" -d "message_id=${msg_id}"
                 -d "parse_mode=HTML" -d "disable_web_page_preview=true"
                 --data-urlencode "text=${text}" )
    [[ -n "$markup" ]] && args+=( -d "reply_markup=${markup}" )
    local resp; resp=$(_curl_tg "editMessageText" "${args[@]}")
    if echo "$resp" | grep -q '"error_code"'; then
        local desc; desc=$(echo "$resp" | grep -o '"description":"[^"]*"')
        dbg "tg_edit FAIL: $desc"
        if echo "$desc" | grep -qiE "message to edit not found|message can.t be edited|MESSAGE_ID_INVALID|chat not found"; then
            return 1
        fi
    fi
    return 0
}

tg_edit_markup() {
    local msg_id="$1" markup="$2"
    _curl_tg "editMessageReplyMarkup" \
        -d "chat_id=${TELEGRAM_CHAT}" -d "message_id=${msg_id}" \
        -d "reply_markup=${markup}" > /dev/null
}

tg_doc() {
    local filepath="$1" caption="$2"
    [[ -f "$filepath" ]] || { dbg "tg_doc: file not found: $filepath"; return 0; }
    _curl_tg "sendDocument" -F "chat_id=${TELEGRAM_CHAT}" -F "document=@${filepath}" \
        --form-string "caption=${caption}" --form-string "parse_mode=HTML" > /dev/null
    dbg "tg_doc sent: $filepath"
}

tg_pin()   { _curl_tg "pinChatMessage"   -d "chat_id=${TELEGRAM_CHAT}" -d "message_id=$1" -d "disable_notification=true" > /dev/null; }
tg_unpin() { _curl_tg "unpinChatMessage" -d "chat_id=${TELEGRAM_CHAT}" -d "message_id=$1" > /dev/null; }

# ─── Keyboards ──────────────────────────────────────────────────────────
KEYBOARD_LIVE='{"inline_keyboard":[[{"text":"🔄 Refresh","callback_data":"refresh"},{"text":"📊 Stats","callback_data":"stats"},{"text":"🛑 Stop","callback_data":"stop"}],[{"text":"📋 List builds","callback_data":"list"},{"text":"🔁 Reload script","callback_data":"reload"}]]}'
KEYBOARD_CONFIRM_STOP='{"inline_keyboard":[[{"text":"⚠️ Yes, stop it","callback_data":"stop_confirm"},{"text":"↩️ Never mind","callback_data":"stop_cancel"}]]}'

keyboard_terminal() {
    # $1 = RESULT_KIND
    local kind="$1"
    local row="["
    if [[ "$kind" == "success" && -n "$RESULT_LINK" ]]; then
        row="${row}{\"text\":\"⬇️ Download\",\"url\":\"${RESULT_LINK}\"}"
        [[ -n "$RUN_URL" ]] && row="${row},{\"text\":\"🔗 View Run\",\"url\":\"${RUN_URL}\"}"
    elif [[ -n "$RUN_URL" ]]; then
        row="${row}{\"text\":\"🔗 View Run\",\"url\":\"${RUN_URL}\"}"
    fi
    row="${row}]"
    if [[ "$row" == "[]" ]]; then
        echo ""
    else
        echo "{\"inline_keyboard\":[${row}]}"
    fi
}

# ─── Cluster queue stats (crave.io team job list) ──────────────────────────
# Uses the same Authorization the crave CLI uses (crave.conf's "headers.Authorization").
fetch_queue_stats() {
    [[ -z "$CRAVE_TOKEN" ]] && return
    local now; now=$(date +%s)
    (( now - LAST_Q_FETCH_EPOCH < QSTATS_INTERVAL )) && return
    LAST_Q_FETCH_EPOCH=$now

    local resp
    resp=$(curl -s -m 15 -X POST "$CRAVE_API" \
        -H "Authorization: ${CRAVE_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"action\":\"list\",\"page\":1,\"limit\":150,\"sort\":{\"jobId\":\"desc\"},\"filter\":{\"type\":\"batch\",\"teamId\":${CRAVE_TEAM_ID}},\"searchKeyword\":{}}" \
        2>/dev/null)

    [[ -z "$resp" ]] && { dbg "fetch_queue_stats: empty response"; return; }
    if ! echo "$resp" | jq -e '.success' >/dev/null 2>&1; then
        dbg "fetch_queue_stats: bad response: $(echo "$resp" | head -c 200)"
        return
    fi

    STAT_Q_RUNNING=$(echo "$resp" | jq '[.data.content[]? | select(.status=="running")] | length' 2>/dev/null)
    STAT_Q_QUEUED=$(echo "$resp"  | jq '[.data.content[]? | select(.status=="queued")]  | length' 2>/dev/null)

    if [[ -n "$QUEUE_JOB_ID" ]]; then
        local pos
        pos=$(echo "$resp" | jq --argjson jid "$QUEUE_JOB_ID" '
            [.data.content[]? | select(.status=="queued")]
            | sort_by(.queueStartTime)
            | map(.jobId) | index($jid)
        ' 2>/dev/null)
        if [[ "$pos" != "null" && -n "$pos" ]]; then
            STAT_Q_POSITION=$((pos + 1))
        else
            STAT_Q_POSITION=""
        fi
    fi

    local was_available=$STATS_Q_AVAILABLE
    STATS_Q_AVAILABLE=1
    dbg "fetch_queue_stats: running=$STAT_Q_RUNNING queued=$STAT_Q_QUEUED position=$STAT_Q_POSITION"

    local should_update=0
    [[ $was_available -eq 0 ]] && should_update=1   # first successful fetch — show it now, don't wait
    [[ "$STAT_Q_RUNNING" != "$LAST_Q_RUNNING" || "$STAT_Q_QUEUED" != "$LAST_Q_QUEUED" ]] && should_update=1
    [[ -n "$STAT_Q_POSITION" && "$STAT_Q_POSITION" != "$LAST_Q_POSITION" ]] && should_update=1

    if [[ "$PHASE" == "queuing" && $should_update -eq 1 ]]; then
        force_publish
    fi
    LAST_Q_RUNNING="$STAT_Q_RUNNING"
    LAST_Q_QUEUED="$STAT_Q_QUEUED"
    LAST_Q_POSITION="$STAT_Q_POSITION"
}

# ─── Message builder ────────────────────────────────────────────────────
build_message() {
    local elapsed_str; elapsed_str=$(elapsed)

    # ── Header (varies by phase / terminal result) ──
    local icon header
    case "$PHASE" in
        starting)  icon="🚀"; header="Starting" ;;
        retrying)  icon="🔁"; header="Retrying" ;;
        queuing)   icon="⏳"; header="Queued" ;;
        setup)     icon="📦"; header="Container Setup" ;;
        syncing)   icon="📥"; header="Syncing Sources" ;;
        building)  icon="🔨"; header="Building" ;;
        finishing) icon="📦"; header="Packaging & Uploading" ;;
        uploading) icon="⬆️"; header="Uploading" ;;
        stopping)  icon="🛑"; header="Stop Requested" ;;
        done)
            case "$RESULT_KIND" in
                success)          icon="🎉"; header="Build Complete" ;;
                upload_fail)      icon="⚠️"; header="Build OK — Upload Failed" ;;
                no_zip)           icon="⚠️"; header="Build OK — No ZIP Found" ;;
                real_fail)        icon="❌"; header="Build Failed" ;;
                glitch_exhausted) icon="❌"; header="All Retries Exhausted" ;;
                stopped)          icon="🛑"; header="Stopped" ;;
                lost_contact)     icon="⚠️"; header="Lost Contact" ;;
                *)                icon="🏁"; header="Finished" ;;
            esac
            ;;
        *) icon="⚙️"; header="Working" ;;
    esac

    # ── Persistent info block (always shown) ──
    local info="• Device: ${DEVICE_NAME}  |  Modules: ${BUILD_MODULES}
• ROM: ${ROM_NAME} (Android ${ANDROID_VER})
• Started: ${START_FMT}  |  Elapsed: ${elapsed_str}"
    if [[ -n "$MAX_RETRIES" && "$MAX_RETRIES" -gt 1 ]]; then
        info="${info}
• Attempt: ${ATTEMPT}/${MAX_RETRIES}"
    fi
    if [[ -n "$RUN_URL" ]]; then
        info="${info}
• 🔗 <a href=\"${RUN_URL}\">View workflow run</a>"
    fi

    # ── Collapsible steps ──
    local steps_section=""
    if [[ -n "$COMPLETED_STEPS" ]]; then
        steps_section="
<blockquote expandable>📋 <b>Steps</b>
${COMPLETED_STEPS}</blockquote>"
    fi

    # ── Cluster queue block (while queuing) ──
    local queue_block=""
    if [[ "$PHASE" == "queuing" && $STATS_Q_AVAILABLE -eq 1 ]]; then
        local checked_at; checked_at=$(date -u '+%H:%M:%S UTC')
        queue_block="
━━━━━━━━━━━━━━━━━━━━━━━━
<b>🌐 Cluster Queue</b>  <i>· checked ${checked_at}</i>
🏁 Running: ${STAT_Q_RUNNING:-?}   ⏳ Queued: ${STAT_Q_QUEUED:-?}"
        if [[ -n "$STAT_Q_POSITION" ]]; then
            local move_tag=""
            if [[ -n "$LAST_Q_POSITION" && "$LAST_Q_POSITION" != "$STAT_Q_POSITION" ]]; then
                if (( STAT_Q_POSITION < LAST_Q_POSITION )); then
                    move_tag="  <i>(▲ was #${LAST_Q_POSITION})</i>"
                else
                    move_tag="  <i>(▼ was #${LAST_Q_POSITION})</i>"
                fi
            fi
            queue_block="${queue_block}
📍 Your position: <b>#${STAT_Q_POSITION}</b>${move_tag}"
        fi
    fi

    # ── Collapsible container stats ──
    local stats_block=""
    if [[ $STATS_AVAILABLE -eq 1 && "$PHASE" != "done" ]]; then
        local cb rb db
        cb=$(pbar "${STAT_CPU:-0}"); rb=$(pbar "${STAT_RAM_PCT:-0}"); db=$(pbar "${STAT_DISK_PCT:-0}")
        stats_block="
<blockquote expandable>📊 <b>Container Stats</b>
🖥 CPU   [${cb}] ${STAT_CPU}%  <i>(load ${STAT_LOAD}/${STAT_CORES})</i>
🧠 RAM   [${rb}] ${STAT_RAM_PCT}%  <i>(${STAT_RAM_USED}/${STAT_RAM_TOTAL})</i>
💾 Disk  [${db}] ${STAT_DISK_PCT}%  <i>(${STAT_DISK_USED}/${STAT_DISK_TOTAL})</i></blockquote>"
    fi

    # ── Terminal result card ──
    local result_block=""
    if [[ "$PHASE" == "done" ]]; then
        case "$RESULT_KIND" in
            success)
                result_block="
━━━━━━━━━━━━━━━━━━━━━━━━
<b>📦 File:</b> ${RESULT_FILE}
<b>⬇️ Download:</b> <a href=\"${RESULT_LINK}\">${RESULT_LINK}</a>"
                ;;
            upload_fail|no_zip)
                result_block="
━━━━━━━━━━━━━━━━━━━━━━━━
<b>File:</b> ${RESULT_FILE:-unknown}
Check Actions logs for details."
                ;;
            real_fail|glitch_exhausted)
                result_block="
━━━━━━━━━━━━━━━━━━━━━━━━
Full log attached below as a file."
                ;;
            stopped)
                if [[ -f "$STOP_RETRY_USED_FILE" ]]; then
                    result_block="
━━━━━━━━━━━━━━━━━━━━━━━━
This run already auto-retried once after a stop — not retrying again."
                else
                    result_block="
━━━━━━━━━━━━━━━━━━━━━━━━
Automatically retrying this build once..."
                fi
                ;;
        esac
    fi

    local phase_hint=""
    if [[ "$PHASE" == "queuing" ]]; then
        phase_hint="
<i>Position updates live · full refresh ~30 min</i>"
    fi

    printf '%s <b>LunarisOS — %s</b>\n\n%s\n%s\n━━━━━━━━━━━━━━━━━━━━━━━━\n👉 <b>%s</b>\n%s%s%s%s%s' \
        "$icon" "$header" \
        "$info" \
        "$steps_section" \
        "$CURRENT_STAGE" "$CURRENT_DETAIL" \
        "$queue_block" "$stats_block" "$result_block" "$phase_hint"
}

# ─── Publish logic ──────────────────────────────────────────────────────
publish_message() {
    local now text markup
    now=$(date +%s)
    text=$(build_message)

    if [[ "$PHASE" == "done" ]]; then
        markup=$(keyboard_terminal "$RESULT_KIND")
    elif [[ "$PHASE" == "stopping" ]]; then
        markup="$KEYBOARD_CONFIRM_STOP"
    else
        markup="$KEYBOARD_LIVE"
    fi

    if [[ -z "$MSG_ID" ]]; then
        MSG_ID=$(tg_send "$text" "$markup")
        if [[ -n "$MSG_ID" ]]; then
            tg_pin "$MSG_ID"
            echo "$MSG_ID" > "$MSG_STATE_FILE" 2>/dev/null || true
        fi
        LAST_EDIT_EPOCH=$now
        dbg "Initial message sent, MSG_ID=$MSG_ID"
    else
        if ! tg_edit "$MSG_ID" "$text" "$markup"; then
            dbg "publish_message: target message gone (deleted?) — recreating a fresh one"
            MSG_ID=""
            MSG_ID=$(tg_send "$text" "$markup")
            if [[ -n "$MSG_ID" ]]; then
                tg_pin "$MSG_ID"
                echo "$MSG_ID" > "$MSG_STATE_FILE" 2>/dev/null || true
            fi
        fi
        LAST_EDIT_EPOCH=$now
    fi

    if [[ "$PHASE" == "done" && -n "$MSG_ID" ]]; then
        tg_unpin "$MSG_ID"
    fi
}

force_publish() {
    LAST_EDIT_EPOCH=0
    LAST_QUEUE_EPOCH=0
    LAST_PROGRESS_EPOCH=0
    publish_message
}

maybe_publish() {
    local now; now=$(date +%s)

    if [[ -z "$MSG_ID" ]]; then
        # Haven't managed to create the message yet (e.g. Telegram was briefly
        # unreachable on the first attempt). Retry on a fixed backoff instead
        # of hammering the API every single poll tick.
        if [[ $((now - LAST_EDIT_EPOCH)) -ge $INIT_RETRY_INTERVAL ]]; then
            publish_message
        fi
        return
    fi

    if [[ "$PHASE" == "queuing" ]]; then
        if [[ $((now - LAST_QUEUE_EPOCH)) -ge $QUEUE_INTERVAL ]]; then
            publish_message; LAST_QUEUE_EPOCH=$now
        fi
    else
        if [[ $((now - LAST_PROGRESS_EPOCH)) -ge $PROGRESS_INTERVAL ]]; then
            publish_message; LAST_PROGRESS_EPOCH=$now
        fi
    fi

    if [[ $STATS_AVAILABLE -eq 1 && $((now - LAST_STATS_EPOCH)) -ge $STATS_INTERVAL ]]; then
        publish_message; LAST_STATS_EPOCH=$now
    fi
}

# ─── Failure log upload ─────────────────────────────────────────────────
send_failure_log() {
    local exit_code="${1:-1}"
    local ts; ts=$(date '+%Y%m%d_%H%M%S' -u)

    local log_dir="${PROJECT_DIR}/build_logs"
    mkdir -p "$log_dir" 2>/dev/null || true
    local log_save="${log_dir}/build_${ts}.log"
    if cp "$LOG_FILE" "$log_save" 2>/dev/null; then
        dbg "Full log saved to: $log_save"
    else
        dbg "WARNING: could not save log to $log_save"
    fi

    local log_send="/tmp/build_failure_${ts}.txt"
    {
        echo "=== Build Log (last 500 lines, stats stripped) ==="
        echo "=== Full log at: ${log_save} ==="
        echo ""
        tail -500 "$LOG_FILE" 2>/dev/null | grep -v '^\[VOLT_STATS\]' || echo "No log available"
    } > "$log_send"

    local caption
    caption=$(printf '❌ <b>Build Failed</b>\nExit: %s  |  Modules: %s  |  Attempt: %s/%s\nElapsed: %s' \
        "$exit_code" "$BUILD_MODULES" "$ATTEMPT" "$MAX_RETRIES" "$(elapsed)")

    tg_doc "$log_send" "$caption"
    rm -f "$log_send"
}

# ─── Telegram callback_query + text command polling ─────────────────────
poll_commands() {
    local resp
    resp=$(_curl_tg "getUpdates" -d "offset=$((TG_OFFSET+1))" -d "limit=10" -d "timeout=0")
    [[ -z "$resp" || "$resp" == '{"ok":true,"result":[]}' ]] && return

    local last_id
    last_id=$(echo "$resp" | jq -r '.result[-1].update_id // empty')
    [[ -n "$last_id" ]] && TG_OFFSET=$last_id

    local callbacks
    callbacks=$(echo "$resp" | jq -c '.result[] | select(.callback_query != null) | {id: .callback_query.id, data: .callback_query.data}')

    while IFS= read -r cb; do
        [[ -z "$cb" ]] && continue
        local cb_id cb_data
        cb_id=$(echo "$cb" | jq -r '.id // empty')
        cb_data=$(echo "$cb" | jq -r '.data // empty')
        dbg "Callback: data=$cb_data id=$cb_id"
        [[ -n "$cb_id" ]] && _curl_tg "answerCallbackQuery" -d "callback_query_id=${cb_id}" -d "text=✅ Done" > /dev/null
        handle_command "$cb_data"
    done <<< "$callbacks"

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
            if [[ "$PHASE" == "queuing" ]]; then
                LAST_Q_FETCH_EPOCH=0
                fetch_queue_stats
            fi
            force_publish
            ;;
        stats|/stats)
            LAST_STATS_EPOCH=0
            publish_message
            ;;
        stop|/stop|cancel|/cancel)
            # First press just asks for confirmation — nothing is stopped yet.
            if [[ -n "$MSG_ID" ]]; then
                tg_edit_markup "$MSG_ID" "$KEYBOARD_CONFIRM_STOP"
                dbg "Stop pressed — awaiting confirmation"
            fi
            ;;
        stop_confirm)
            dbg "Stop CONFIRMED by user"
            ( cd "$PROJECT_DIR" 2>/dev/null && crave stop --all ) >/dev/null 2>&1 &
            touch "$STOP_SENTINEL"
            clear_tracked_job
            RESULT_KIND="stopped"
            PHASE="done"
            CURRENT_STAGE="🛑 Stopped by user"
            CURRENT_DETAIL="Cancel requested via Telegram."
            force_publish
            SHOULD_EXIT=1
            ;;
        stop_cancel)
            dbg "Stop cancelled by user"
            [[ -n "$MSG_ID" ]] && tg_edit_markup "$MSG_ID" "$KEYBOARD_LIVE"
            ;;
        list|/list)
            dbg "List builds requested"
            if [[ -z "$CRAVE_TOKEN" ]]; then
                tg_send "⚠️ CRAVE_TOKEN not set — can't fetch the job list." ""
                return
            fi
            local resp
            resp=$(curl -s -m 15 -X POST "$CRAVE_API" \
                -H "Authorization: ${CRAVE_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "{\"action\":\"list\",\"page\":1,\"limit\":150,\"sort\":{\"jobId\":\"desc\"},\"filter\":{\"type\":\"batch\",\"teamId\":${CRAVE_TEAM_ID}},\"searchKeyword\":{}}" \
                2>/dev/null)
            if ! echo "$resp" | jq -e '.success' >/dev/null 2>&1; then
                tg_send "⚠️ Couldn't fetch the job list right now — crave API didn't return a usable response." ""
                return
            fi

            local lines
            lines=$(echo "$resp" | jq -r '
                [.data.content[]? | select(.status=="running" or .status=="queued")]
                | sort_by(if .status=="queued" then .queueStartTime else "" end)
                | .[] | "\(.status)|\(.jobId)|\(.user.firstName // "?") \(.user.lastName // "")"
            ' 2>/dev/null)

            local out="📋 <b>Running / Queued right now</b>"$'\n'
            local n=0 found_tracked=0 pos_counter=0
            while IFS='|' read -r status jid name; do
                [[ -z "$status" ]] && continue
                n=$((n+1))
                local icon="⏳" pos_tag=""
                if [[ "$status" == "queued" ]]; then
                    pos_counter=$((pos_counter+1))
                    pos_tag=" (#${pos_counter} in queue)"
                else
                    icon="🏁"
                fi
                local marker=""
                if [[ -n "$QUEUE_JOB_ID" && "$jid" == "$QUEUE_JOB_ID" ]]; then
                    marker=" 👈 <b>this build</b>"
                    found_tracked=1
                fi
                out="${out}${icon} #${jid}${pos_tag} — ${name}${marker}"$'\n'
                [[ $n -ge 40 ]] && { out="${out}<i>(list capped at 40)</i>"$'\n'; break; }
            done <<< "$lines"

            if [[ -n "$QUEUE_JOB_ID" ]]; then
                if [[ $found_tracked -eq 0 ]]; then
                    out="${out}"$'\n'"⚠️ Tracked job #${QUEUE_JOB_ID} was <b>NOT found</b> in this list — either it already started/finished, or the position math is looking at the wrong ID. Worth checking crave.io directly for job #${QUEUE_JOB_ID}."
                fi
            else
                out="${out}"$'\n'"<i>No job ID captured yet for this build — can't cross-check position.</i>"
            fi

            tg_send "$out" ""
            ;;
        reload|/reload)
            dbg "Reload requested — re-fetching latest monitor.sh"
            local new_script="/tmp/volt_monitor_reload_$$.sh"
            if curl -LSs "$MONITOR_SELF_URL" -o "$new_script" 2>/dev/null && [[ -s "$new_script" ]]; then
                chmod +x "$new_script"
                dbg "Reload: got fresh copy, exec'ing (same PID, same message thread)"
                # Clear MSG_ID state so the reloaded script validates & recreates if deleted
                rm -f "$MSG_STATE_FILE" 2>/dev/null || true
                tg_send "🔁 Reloading — picking up the latest script now..." ""
                exec bash "$new_script" "$LOG_FILE" "$STEP_PID" "$PROJECT_DIR" "$ATTEMPT" "$MAX_RETRIES" "$BUILD_COMMAND" "$RUN_URL" "$TG_OFFSET"
                # exec only returns on failure
                dbg "Reload: exec failed unexpectedly, staying on current version"
                tg_send "⚠️ Reload failed to start — still running the previous version." ""
            else
                dbg "Reload: download failed"
                tg_send "⚠️ Reload failed — couldn't download the latest script. Still running the previous version." ""
            fi
            ;;
    esac
}

# ─── Log line parser ────────────────────────────────────────────────────
parse_line() {
    local line="$1"
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
            if [[ -z "$QUEUE_JOB_ID" ]]; then
                QUEUE_JOB_ID=$(echo "$line" | grep -oE '[0-9]+' | head -1)
                dbg "Captured QUEUE_JOB_ID=$QUEUE_JOB_ID"
                if [[ -n "$QUEUE_JOB_ID" ]]; then
                    printf '{"jobId": %s}\n' "$QUEUE_JOB_ID" > "${PROJECT_DIR}/.crave_tracked_job.json" 2>/dev/null || true
                fi
            fi
            local _now_ts; _now_ts=$(date +%s)
            if [[ $((_now_ts - LAST_WAITING_LINE_EPOCH)) -gt 10 ]]; then
                LAST_WAITING_LINE_EPOCH=$_now_ts
                force_publish
            fi
            ;;

        # ── Volt.sh lifecycle tags ────────────────────────────────────
        *"[VOLT_START]"*)
            PHASE="building"
            CURRENT_STAGE="🚀 Initialization"
            CURRENT_DETAIL="${line#*\[VOLT_START\] }"
            force_publish
            ;;
        *"[VOLT_CONFIG]"*)
            local payload="${line#*\[VOLT_CONFIG\] }"
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

        *"[VOLT_STATUS]"*)
            local payload="${line#*\[VOLT_STATUS\] }"
            CURRENT_STAGE="${payload%%|*}"
            CURRENT_DETAIL="${payload#*|}"
            if [[ "$PHASE" != "done" ]]; then
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

        # Inside-container result — informational only now. The REAL terminal
        # state (with upload link / real exit code) comes from the outer
        # VOLT_UPLOAD_*/VOLT_REAL_FAIL tags the workflow appends afterwards.
        *"[VOLT_RESULT]"*)
            local result="${line#*\[VOLT_RESULT\] }"
            local status="${result%%|*}" detail="${result#*|}"
            dbg "RESULT: status=$status detail=$detail"
            case "$status" in
                SUCCESS)
                    PHASE="finishing"
                    CURRENT_STAGE="📦 Packaging & Uploading"
                    CURRENT_DETAIL="Build succeeded — pulling artifact and uploading..."
                    COMPLETED_STEPS="${COMPLETED_STEPS}✅ <b>Build succeeded</b>"$'\n'
                    force_publish
                    ;;
                FAILED|PARTIAL)
                    PHASE="finishing"
                    CURRENT_STAGE="⚙️ Wrapping Up"
                    CURRENT_DETAIL="$detail"
                    force_publish
                    ;;
                CANCELLED)
                    CURRENT_DETAIL="$detail"
                    force_publish
                    ;;
            esac
            ;;

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
            ;;

        # ── NEW: outer terminal tags written by the workflow itself ────
        *"[VOLT_UPLOAD_OK]"*)
            local payload="${line#*\[VOLT_UPLOAD_OK\] }"
            RESULT_FILE="${payload%%|*}"
            RESULT_LINK="${payload#*|}"
            RESULT_KIND="success"
            PHASE="done"
            clear_tracked_job
            CURRENT_STAGE="🎉 Build Complete"
            CURRENT_DETAIL="Uploaded and ready to download."
            force_publish
            SHOULD_EXIT=1
            ;;
        *"[VOLT_UPLOAD_FAIL]"*)
            RESULT_FILE="${line#*\[VOLT_UPLOAD_FAIL\] }"
            RESULT_KIND="upload_fail"
            PHASE="done"
            clear_tracked_job
            CURRENT_STAGE="⚠️ Upload Failed"
            CURRENT_DETAIL="Build succeeded but the zdrive upload failed."
            force_publish
            SHOULD_EXIT=1
            ;;
        *"[VOLT_NO_ZIP]"*)
            RESULT_KIND="no_zip"
            PHASE="done"
            clear_tracked_job
            CURRENT_STAGE="⚠️ No ZIP Found"
            CURRENT_DETAIL="Build reported success but no output zip was found."
            force_publish
            SHOULD_EXIT=1
            ;;
        *"[VOLT_GLITCH_RETRY]"*)
            local delay="${line#*\[VOLT_GLITCH_RETRY\] }"
            CURRENT_STAGE="🔄 Crave Glitch"
            CURRENT_DETAIL="No worker was ever assigned. Retrying in ${delay}s (attempt ${ATTEMPT}/${MAX_RETRIES})..."
            force_publish
            SHOULD_EXIT=1   # non-terminal — next attempt's monitor.sh resumes this same message
            ;;
        *"[VOLT_GLITCH_EXHAUSTED]"*)
            RESULT_KIND="glitch_exhausted"
            PHASE="done"
            clear_tracked_job
            CURRENT_STAGE="❌ All Retries Exhausted"
            CURRENT_DETAIL="Crave never assigned a worker after ${MAX_RETRIES} attempts."
            force_publish
            SHOULD_EXIT=1
            ;;
        *"[VOLT_REAL_FAIL]"*)
            local code="${line#*\[VOLT_REAL_FAIL\] }"
            RESULT_KIND="real_fail"
            PHASE="done"
            clear_tracked_job
            CURRENT_STAGE="❌ Build Failed"
            CURRENT_DETAIL="Exit code ${code}"
            force_publish
            send_failure_log "$code"
            SHOULD_EXIT=1
            ;;
        *"[VOLT_UPLOADING]"*)
            local fname="${line#*\[VOLT_UPLOADING\] }"
            PHASE="uploading"
            CURRENT_STAGE="⬆️ Uploading to zdrive"
            CURRENT_DETAIL="Starting upload: ${fname}"
            force_publish
            ;;

        # ── Fallback: no recognized tag matched. During building/finishing/
        # uploading, show the freshest raw line instead of going silent —
        # this is what was making fast incremental builds (few ninja actions,
        # long post-processing) look "stuck" with no visible progress. ────
        *)
            if [[ "$PHASE" == "building" || "$PHASE" == "finishing" || "$PHASE" == "uploading" ]]; then
                # A bare "NN%" anywhere in the line (e.g. an upload progress
                # indicator) gets rendered as a real bar; otherwise just show
                # the raw line so something visibly moves.
                if echo "$line" | grep -qE '[0-9]{1,3}%'; then
                    local upct upbar
                    upct=$(echo "$line" | grep -oE '[0-9]{1,3}%' | head -1 | tr -d '%')
                    upbar=$(pbar "$upct")
                    CURRENT_DETAIL="[${upbar}] ${upct}%"$'\n'"🔧 ${line:0:100}"
                else
                    CURRENT_DETAIL="🔧 ${line:0:120}"
                fi
            fi
            ;;
    esac

    # ── Ninja progress bar: [ 23% 12345/53421] ────────────────────────
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

# ═══════════════════════════════════════════════════════════════════════
# MAIN LOOP
# ═══════════════════════════════════════════════════════════════════════

dbg "Sending initial message..."
force_publish
dbg "Initial message done, MSG_ID=$MSG_ID"

while true; do
    if [[ -f "$LOG_FILE" ]]; then
        local_count=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        if (( local_count > LAST_LINE_COUNT )); then
            tail -n +"$((LAST_LINE_COUNT + 1))" "$LOG_FILE" 2>/dev/null | tr -d '\r' | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' | head -n 500 > "$TEMP_FILE"
            while IFS= read -r line; do parse_line "$line"; done < "$TEMP_FILE"
            LAST_LINE_COUNT=$local_count
        fi
    fi

    if [[ $SHOULD_EXIT -eq 1 ]]; then
        dbg "Terminal/handoff tag processed — monitor exiting cleanly."
        break
    fi

    if [[ "$PHASE" == "queuing" ]]; then
        fetch_queue_stats
    fi

    poll_commands
    maybe_publish

    # Safety net: if the whole retry-loop shell died without us noticing
    # (job timed out, runner killed outright, etc.), don't spin forever —
    # and don't leave the message silently frozen either, since that's
    # indistinguishable from "still working" to whoever's watching it.
    if ! kill -0 "$STEP_PID" 2>/dev/null; then
        dbg "STEP_PID $STEP_PID is gone — publishing a lost-contact notice and exiting."
        RESULT_KIND="lost_contact"
        PHASE="done"
        CURRENT_STAGE="⚠️ Lost Contact"
        CURRENT_DETAIL="The runner process behind this build disappeared (job timeout, runner restart, or it was killed outright). Check GitHub Actions for the real outcome."
        force_publish
        break
    fi

    sleep "$POLL_INTERVAL"
done

rm -f "$TEMP_FILE"
dbg "Monitor exiting."
echo "Monitor: done."
