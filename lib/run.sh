# shellcheck shell=bash
# The run pipeline (`brief run`), plus resend / status / logs.

RUN_DIR=""
RUN_MODE=""
RUN_START=0
DRY_RUN=0
EXTRA_NOTES=""

# ------------------------------------------------------------------ failure handling
# fail_run <reason>: log, record, alert on Telegram (or print on dry runs), exit 1.
FAIL_HANDLED=0
fail_run() {
  local reason="$1" msg tail_lines shown_log
  FAIL_HANDLED=1
  trap - EXIT; trap run_on_exit_quiet EXIT
  err "Run failed: $reason"
  mark_failure "$reason"
  write_last_run "failed" "$(( $(epoch_now) - RUN_START ))s" 0 "$RUN_MODE" "$reason"
  tail_lines="$(tail -n 15 "$LOG_FILE" 2>/dev/null | cut -c1-300 | redact)"
  shown_log="${LOG_FILE/#$HOME/~}"
  msg="⚠️ Morning brief failed: $reason

$tail_lines

Log: $shown_log"
  [ -n "$(retry_note)" ] && msg="$msg
$(retry_note)"
  if [ "$DRY_RUN" = 1 ]; then
    say ""; say "${C_DIM}(dry run: this alert would be sent to Telegram)${C_OFF}"; say "$msg"
  elif [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
    if tg_send_text "$msg" 0; then
      log_only "Failure alert sent to Telegram."
    else
      log_only "Could not send failure alert to Telegram: ${TG_LAST_ERROR:-unknown}"
      err "Telegram is unreachable too (${TG_LAST_ERROR:-unknown}); failure recorded in state/last_failure."
    fi
  else
    err "Telegram not configured; failure recorded in state/last_failure only."
  fi
  exit 1
}

run_on_exit_quiet() {
  claude_kill
  lock_release
}

# EXIT trap for the run: any non-zero exit that didn't go through fail_run (a bug, an
# unbound variable, a failed command) still gets recorded and alerted. Never fail silently.
run_on_exit() {
  local rc=$?
  claude_kill
  lock_release
  if [ "$rc" != 0 ] && [ "$FAIL_HANDLED" = 0 ]; then
    FAIL_HANDLED=1
    log_only "Unexpected exit (code $rc)"
    fail_run "unexpected internal error (exit $rc); see the log"   # exits
  fi
}

run_on_signal() {
  FAIL_HANDLED=1
  log_only "Interrupted by signal"
  claude_kill
  mark_failure "interrupted"
  write_last_run "interrupted" "$(( $(epoch_now) - RUN_START ))s" 0 "$RUN_MODE" "interrupted"
  lock_release
  err "Interrupted."
  exit 130
}

# ------------------------------------------------------------------ scheduling gate / catch-up
RUN_SCHEDULED=0
ATTEMPT=0

# Remember the last scheduler decision (shown by ./brief status). Cheap, no log file.
record_check() { printf '%s\t%s\n' "$(now_human)" "$1" >"$STATE_DIR/last_check"; }

# Number of scheduled attempts made today.
attempts_today() {
  local d n
  [ -f "$STATE_DIR/attempts" ] || { echo 0; return; }
  read -r d n <"$STATE_DIR/attempts" || { echo 0; return; }
  if [ "$d" = "$1" ]; then echo "${n:-0}"; else echo 0; fi
}
attempt_bump() {
  local n
  n=$(( $(attempts_today "$1") + 1 ))
  printf '%s %s\n' "$1" "$n" >"$STATE_DIR/attempts"
  echo "$n"
}

# Is a brief due now? Due = past today's run time, not yet delivered today, attempts left.
# Covers: missed 06:00 because the Mac was off/asleep/logged out (runs at login or wake),
# and a failed run (retried every RETRY_MINUTES, up to MAX_DAILY_ATTEMPTS per day).
scheduled_gate() {
  local today="$1" now_hm run_hm n
  now_hm="${BRIEF_NOW_HM:-$(TZ=$BRIEF_TZ date '+%H%M')}"   # BRIEF_NOW_HM: tests only
  run_hm="$(printf '%02d%02d' "$((10#$RUN_HOUR))" "$((10#$RUN_MINUTE))")"
  if [ "$(cat "$STATE_DIR/last_success" 2>/dev/null)" = "$today" ]; then
    record_check "skip: today's brief already delivered"; return 1
  fi
  if [ "$((10#$now_hm))" -lt "$((10#$run_hm))" ]; then
    record_check "skip: not due until $(printf '%02d:%02d' "$((10#$RUN_HOUR))" "$((10#$RUN_MINUTE))")"; return 1
  fi
  n="$(attempts_today "$today")"
  if [ "$n" -ge "$MAX_DAILY_ATTEMPTS" ]; then
    record_check "skip: $n failed attempts today (MAX_DAILY_ATTEMPTS=$MAX_DAILY_ATTEMPTS); run ./brief run manually"; return 1
  fi
  return 0
}

# After login/wake the network can take a moment. Wait up to 2 minutes for it.
wait_for_network() {
  [ "${BRIEF_SKIP_NETWORK_WAIT:-}" = 1 ] && return 0   # tests only
  local i=0 code
  while [ "$i" -lt 120 ]; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 https://api.telegram.org 2>/dev/null)"
    [ -n "$code" ] && [ "$code" != 000 ] && { [ "$i" -gt 0 ] && log "   network up after ${i}s"; return 0; }
    sleep 5; i=$(( i + 5 ))
  done
  warn "Network still unreachable after 2 minutes; trying anyway."
}

# Extra line for failure alerts, saying whether an automatic retry will follow.
retry_note() {
  [ "$RUN_SCHEDULED" = 1 ] || return 0
  if [ "$ATTEMPT" -lt "$MAX_DAILY_ATTEMPTS" ]; then
    printf 'Will retry automatically in about %s min (attempt %s of %s today).' "$RETRY_MINUTES" "$ATTEMPT" "$MAX_DAILY_ATTEMPTS"
  else
    printf 'No more automatic retries today (%s attempts). Fix it, then run ./brief run.' "$MAX_DAILY_ATTEMPTS"
  fi
}

# ------------------------------------------------------------------ chrome
chrome_running()   { pgrep -xq "Google Chrome"; }
chrome_connected() { pgrep -f -- "--chrome-native-host" >/dev/null 2>&1; }

# ensure_chrome <scheduled:0|1>
ensure_chrome() {
  local scheduled="$1" started=0 i=0
  [ "${BRIEF_SKIP_CHROME:-}" = 1 ] && return 0   # tests only
  if ! chrome_running; then
    log "Starting Google Chrome in the background…"
    if ! open -ga "Google Chrome" 2>/dev/null; then
      warn "Could not start Google Chrome; Chrome sources will fall back to WebFetch."
      EXTRA_NOTES="${EXTRA_NOTES}Google Chrome could not be started
"
      return 0
    fi
    started=1
  fi
  if [ "$scheduled" = 1 ]; then
    while ! chrome_connected && [ "$i" -lt 60 ]; do sleep 2; i=$(( i + 2 )); done
    if chrome_connected; then
      log "Claude in Chrome extension connected."
    else
      warn "Claude in Chrome extension did not connect within 60s; continuing (Chrome sources may fall back)."
      EXTRA_NOTES="${EXTRA_NOTES}Claude in Chrome extension not connected after 60s
"
    fi
  elif [ "$started" = 1 ]; then
    sleep 10
  fi
  if ! chrome_connected; then
    log_only "Note: no chrome-native-host process seen; the extension may not be connected."
  fi
}

# ------------------------------------------------------------------ message building
# Count item URLs in a section file (lines that are just a URL).
section_item_count() { grep -cE '^https?://[^[:space:]]+[[:space:]]*$' "$1" 2>/dev/null || true; }

# Strip Markdown that might slip into plain-text output (bold/italic markers, backticks,
# heading hashes, bullet asterisks), but never touch URL lines.
sanitize_section() {
  perl -CSD -Mutf8 -pe 'unless (m{^\s*https?://}) { s/\*\*|__|`//g; s/^\s*#+\s*//; s/^(\s*)\*\s+/$1• /; s/(?<![\w*])\*([^*\n]+)\*(?![\w*])/$1/g }' "$1"
}

# build_messages <run_dir> <sections> <today>  → fills <run_dir>/send/, sets SENT_ITEMS
build_messages() {
  local run_dir="$1" sections="$2" today="$3" send="$1/send" s f c header counts="" footer="" closing missing=""
  rm -rf "$send"; mkdir -p "$send"
  SENT_ITEMS=0
  for s in $sections; do
    f="$run_dir/$(section_file "$s")"
    if [ ! -s "$f" ]; then
      missing="$missing$(section_label "$s"): no output
"
      continue
    fi
    c="$(section_item_count "$f")"; c="${c:-0}"
    [ "$c" -gt 0 ] || { log_only "Section $s has no items; skipping."; continue; }
    sanitize_section "$f" >"$send/$(section_file "$s")"
    SENT_ITEMS=$(( SENT_ITEMS + c ))
    counts="$counts$(section_emoji "$s") $(section_label "$s"): $c
"
  done

  closing="$(closing_soon "$today" "$CLOSING_SOON_DAYS" "$SEEN_FILE")"
  if [ -n "$closing" ]; then
    printf '%s\n' "$closing" >"$send/60-closing.txt"
    counts="${counts}⏰ Closing soon: $(section_item_count "$send/60-closing.txt")
"
  fi

  header="☀️ Morning brief: $(date_pretty "$today")"
  [ "$DRY_RUN" = 1 ] && header="$header (dry run)"
  if [ -n "$counts" ]; then
    header="$header

$counts"
  else
    header="$header

Nothing new worth sending today."
  fi
  printf '%s\n' "$header" >"$send/00-header.txt"

  footer="$missing$EXTRA_NOTES"
  if [ -s "$run_dir/notes.txt" ]; then
    footer="$footer$(grep -v '^[[:space:]]*$' "$run_dir/notes.txt" | head -n 12)
"
  fi
  footer="$(printf '%s' "$footer" | grep -v '^[[:space:]]*$' | sed 's/^/• /')"
  if [ -n "$footer" ]; then
    printf '⚠️ Couldn'\''t check:\n%s\n' "$footer" >"$send/90-footer.txt"
  fi
}

section_emoji() {
  case "$1" in india) echo "🇮🇳" ;; tech) echo "💻" ;; events) echo "📅" ;; competitions) echo "🏆" ;; internships) echo "💼" ;; esac
}

# Send every message in a dir in order. Header (00-*) with sound, the rest silent.
send_dir() {
  local dir="$1" f silent first=1
  for f in "$dir"/[0-9][0-9]-*.txt; do
    [ -s "$f" ] || continue
    silent=1; case "$(basename "$f")" in 00-*) silent=0 ;; esac
    [ "$first" = 1 ] || tg_sleep 1
    first=0
    log_only "Sending $(basename "$f") ($(wc -c <"$f" | tr -d ' ') bytes)"
    tg_send_file "$f" "$silent" || { TG_FAILED_FILE="$(basename "$f")"; return 1; }
  done
  return 0
}

print_dir() {
  local dir="$1" f
  for f in "$dir"/[0-9][0-9]-*.txt; do
    [ -s "$f" ] || continue
    say ""
    say "${C_DIM}──────── $(basename "$f") ($(wc -c <"$f" | tr -d ' ') bytes) ────────${C_OFF}"
    cat "$f"
  done
  say ""
}

# ------------------------------------------------------------------ brief run
cmd_run() {
  local only="" scheduled=0 sections today chrome=0 rc fields is_error subtype reason pruned dest arch_note
  DRY_RUN=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --scheduled) scheduled=1 ;;
      --only) [ $# -ge 2 ] || die "--only needs a section: $ALL_SECTIONS"; only="$2"; shift ;;
      --only=*) only="${1#--only=}" ;;
      *) die "Unknown option for run: $1 (see ./brief help)" ;;
    esac
    shift
  done
  if [ -n "$only" ]; then
    valid_section "$only" || die "Unknown section '$only'. Choose one of: $ALL_SECTIONS"
    sections="$only"
  else
    sections="$ALL_SECTIONS"
  fi
  RUN_MODE="run"; [ "$scheduled" = 1 ] && RUN_MODE="scheduled"; [ "$DRY_RUN" = 1 ] && RUN_MODE="$RUN_MODE dry-run"
  [ -n "$only" ] && RUN_MODE="$RUN_MODE only=$only"

  mkdir -p "$STATE_DIR" "$RUNS_DIR" "$LOGS_DIR" "$ARCHIVE_DIR"
  today="$(today_iso)"
  RUN_SCHEDULED="$scheduled"

  # launchd calls `run --scheduled` at RUN_HOUR:RUN_MINUTE, at login (RunAtLoad), on wake after a
  # missed time, and every RETRY_MINUTES. The gate decides whether a brief is actually due, and stays
  # silent (no log file) when it isn't.
  local forced=0
  if [ "$scheduled" = 1 ]; then
    if [ -f "$STATE_DIR/force_next" ]; then
      rm -f "$STATE_DIR/force_next"; forced=1
    elif ! scheduled_gate "$today"; then
      exit 0
    fi
  fi

  if ! lock_acquire; then
    if [ "$scheduled" = 1 ]; then
      record_check "skip: another run in progress (pid $LOCK_HOLDER)"
      exit 0
    fi
    err "Another run is already in progress (pid $LOCK_HOLDER). If that's wrong, remove $LOCK_DIR."
    exit 1
  fi
  trap run_on_exit EXIT
  trap run_on_signal INT TERM

  [ "$scheduled" = 1 ] && ATTEMPT="$(attempt_bump "$today")"

  start_log
  RUN_START="$(epoch_now)"
  log "☀️  Morning Brief: $(now_human): mode: $RUN_MODE"
  log "   sections: $sections"
  log "   log: $LOG_FILE"
  if [ "$scheduled" = 1 ]; then
    record_check "run: attempt $ATTEMPT/$MAX_DAILY_ATTEMPTS$([ "$forced" = 1 ] && echo ' (kickstart)')"
    if [ "$forced" = 1 ]; then
      log "   (kickstarted: ignoring the already-delivered guard once)"
    else
      log "   attempt $ATTEMPT of $MAX_DAILY_ATTEMPTS today (catch-up/retry is automatic)"
    fi
    wait_for_network
  fi

  # ---- preflight (fail before spending any usage)
  [ -n "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ] || fail_run "claude binary not found (CLAUDE_BIN='$CLAUDE_BIN'). Install Claude Code or run ./brief install."
  if [ "$DRY_RUN" = 0 ]; then
    [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] || {
      mark_failure "Telegram not configured"
      die "TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID missing in config.env. Use --dry-run, or set them up (./brief chat-id)."
    }
  fi
  [ -f "$PROMPTS_DIR/profile.md" ] || warn "prompts/profile.md missing; using the generic profile.md.example. Copy and edit it."

  RUN_DIR="$RUNS_DIR/$(TZ=$BRIEF_TZ date '+%Y%m%d-%H%M%S')"
  [ "$DRY_RUN" = 1 ] && RUN_DIR="$RUN_DIR-dry"
  mkdir -p "$RUN_DIR"
  log_only "run dir: $RUN_DIR"

  pruned="$(seen_prune "$today" "$SEEN_RETENTION_DAYS")"
  log "   memory: $(wc -l <"$SEEN_FILE" | tr -d ' ') items already sent (pruned $pruned old)"
  cp "$SEEN_FILE" "$RUN_DIR/seen.tsv"

  if sections_need_chrome "$sections"; then
    chrome=1
    ensure_chrome "$scheduled"
  fi

  render_prompt "$RUN_DIR" "$sections" "$chrome" "$today" || fail_run "could not build the prompt (see log)"

  # ---- research
  log "🔎 Researching with claude ($MODEL$([ "$chrome" = 1 ] && echo ', Chrome on')). This takes a few minutes (timeout ${MAX_SECONDS}s)…"
  run_claude "$RUN_DIR" "$chrome"; rc=$?
  fields="$(claude_result_fields "$RUN_DIR/result.json" 2>/dev/null)"
  printf '%s\n' "$fields" | grep -v '^result=' | sed 's/^/claude result: /' | while IFS= read -r l; do log_only "$l"; done
  log_only "claude result text: $(printf '%s\n' "$fields" | sed -n 's/^result=//p' | cut -c1-500)"
  [ -s "$RUN_DIR/claude.stderr" ] && log_only "claude stderr: $(head -c 2000 "$RUN_DIR/claude.stderr" | tr '\n' ' ')"
  is_error="$(printf '%s\n' "$fields" | sed -n 's/^is_error=//p')"
  subtype="$(printf '%s\n' "$fields" | sed -n 's/^subtype=//p')"
  log "   claude: exit $rc, $(printf '%s\n' "$fields" | sed -n 's/^num_turns=//p') turns, $(( $(printf '%s\n' "$fields" | sed -n 's/^duration_ms=//p' | grep . || echo 0) / 1000 ))s, est. \$$(printf '%s\n' "$fields" | sed -n 's/^total_cost_usd=//p') (Pro: counts against usage limits, not billed), $(printf '%s\n' "$fields" | sed -n 's/^permission_denials=//p') denied tool calls"

  if [ "$rc" = 124 ]; then
    fail_run "claude timed out after ${MAX_SECONDS}s (MAX_SECONDS)"
  fi
  if [ "$rc" != 0 ] || [ "$is_error" = 1 ]; then
    if looks_like_usage_limit "$RUN_DIR/result.json" "$RUN_DIR/claude.stderr"; then
      fail_run "Claude usage limit reached (Pro plan limits). It will work again once the limit resets; rerun with ./brief run."
    fi
    reason="$(printf '%s\n' "$fields" | sed -n 's/^result=//p' | cut -c1-200)"
    [ -n "$reason" ] || reason="$(head -c 200 "$RUN_DIR/claude.stderr" 2>/dev/null | tr '\n' ' ')"
    fail_run "claude exited $rc (${subtype:-no result}): ${reason:-no details}"
  fi

  # ---- validate + build
  items_clean "$RUN_DIR/items.tsv" "$RUN_DIR/items.clean.tsv"
  local any=0 s
  for s in $sections; do [ -s "$RUN_DIR/$(section_file "$s")" ] && any=1; done
  [ "$any" = 1 ] || fail_run "Claude finished but produced no section files"
  build_messages "$RUN_DIR" "$sections" "$today"
  log "   built $(ls "$RUN_DIR/send" | wc -l | tr -d ' ') messages, $SENT_ITEMS items"

  if [ "$DRY_RUN" = 1 ]; then
    print_dir "$RUN_DIR/send"
    write_last_run "ok (dry run)" "$(( $(epoch_now) - RUN_START ))s" "$SENT_ITEMS" "$RUN_MODE" ""
    log "✅ Dry run complete: nothing sent, nothing saved. Files: $RUN_DIR"
    cleanup_old_runs
    exit 0
  fi

  # ---- send
  log "📨 Sending to Telegram…"
  send_dir "$RUN_DIR/send" || fail_run "Telegram send failed at ${TG_FAILED_FILE:-?}: ${TG_LAST_ERROR:-unknown error}"

  # ---- commit (only after every message went through)
  seen_append "$RUN_DIR/items.clean.tsv" "$today"
  dest="$(archive_run "$RUN_DIR/send" "$today")"
  cp "$RUN_DIR/items.clean.tsv" "$dest/items.tsv" 2>/dev/null
  [ -s "$RUN_DIR/notes.txt" ] && cp "$RUN_DIR/notes.txt" "$dest/notes.log"
  mark_success "$today"
  write_last_run "ok" "$(( $(epoch_now) - RUN_START ))s" "$SENT_ITEMS" "$RUN_MODE" ""
  arch_note="${dest/#$HOME/~}"
  log "✅ Delivered $SENT_ITEMS items. Archived to $arch_note"
  cleanup_old_runs
  exit 0
}

# ------------------------------------------------------------------ resend
cmd_resend() {
  local want="${1:-}" dir
  require_telegram_config
  if [ -n "$want" ]; then
    case "$want" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*) ;; *) die "Use a date like 2026-11-22" ;; esac
    dir="$ARCHIVE_DIR/$want"
  else
    dir="$(latest_archive)"
  fi
  [ -n "$dir" ] && [ -d "$dir" ] || die "No archived brief found${want:+ for $want}. Archives live in archive/."
  say "Re-sending $(basename "$dir")…"
  send_dir "$dir" || die "Telegram send failed at ${TG_FAILED_FILE:-?}: ${TG_LAST_ERROR:-unknown}"
  say "${C_GRN}✅ Re-sent $(basename "$dir").${C_OFF}"
}

# ------------------------------------------------------------------ status / logs
next_run_text() {
  local today now_hm run_hm when
  today="$(today_iso)"
  now_hm="$(TZ=$BRIEF_TZ date '+%H%M')"
  run_hm="$(printf '%02d%02d' "$RUN_HOUR" "$RUN_MINUTE")"
  if [ "$now_hm" -lt "$run_hm" ] && [ "$(cat "$STATE_DIR/last_success" 2>/dev/null)" != "$today" ]; then
    when="$today"
  else
    when="$(date_add_days "$today" +1)"
  fi
  printf '%s %02d:%02d' "$(date_pretty "$when")" "$RUN_HOUR" "$RUN_MINUTE"
}

cmd_status() {
  say "${C_BOLD}Morning Brief status${C_OFF}"
  if [ -f "$STATE_DIR/last_run" ]; then
    say "  Last run:      $(last_run_get time)  ($(last_run_get mode))"
    say "  Result:        $(last_run_get status)$( r="$(last_run_get reason)"; [ -n "$r" ] && printf ': %s' "$r")"
    say "  Duration:      $(last_run_get duration)"
    say "  Items:         $(last_run_get items)"
    say "  Log:           $(last_run_get log | sed "s|^$HOME|~|")"
  else
    say "  Last run:      never"
  fi
  say "  Last delivered: $(cat "$STATE_DIR/last_success" 2>/dev/null || echo never)"
  [ -f "$STATE_DIR/last_check" ] && say "  Last check:    $(tr '\t' ' ' <"$STATE_DIR/last_check")"
  say "  Attempts today: $(attempts_today "$(today_iso)") of $MAX_DAILY_ATTEMPTS (catch-up at login/wake, retry every ${RETRY_MINUTES} min)"
  [ -f "$STATE_DIR/last_failure" ] && say "  Last failure:  $(cut -f1,2 "$STATE_DIR/last_failure" | tr '\t' ' ')"
  if launchd_loaded; then
    say "  LaunchAgent:   ✅ loaded ($LABEL)"
    say "  Next run:      $(next_run_text) (daily at $(printf '%02d:%02d' "$RUN_HOUR" "$RUN_MINUTE"))"
  else
    if is_mac_mini; then
      say "  LaunchAgent:   ❌ not loaded (run ./brief install)"
    else
      say "  LaunchAgent:   not loaded (expected on this $(model_name); schedule lives on the Mac Mini)"
    fi
  fi
  say "  Memory:        $(wc -l <"$SEEN_FILE" 2>/dev/null | tr -d ' ' || echo 0) items in state/seen.tsv"
}

cmd_logs() {
  local f="$LOGS_DIR/latest.log"
  mkdir -p "$LOGS_DIR"
  if [ "${1:-}" = "-f" ]; then
    say "${C_DIM}Following $(readlink "$f" || echo latest.log), plus launchd output. Ctrl-C to stop.${C_OFF}"
    touch "$LOGS_DIR/launchd.out.log" "$LOGS_DIR/launchd.err.log"
    tail -n 50 -F "$f" "$LOGS_DIR/launchd.out.log" "$LOGS_DIR/launchd.err.log" 2>/dev/null
  else
    [ -e "$f" ] || die "No run logs yet (logs/ is empty). Try ./brief run --dry-run --only tech"
    cat "$f"
  fi
}
