# shellcheck shell=bash
# Sourced by tests/run-tests.sh: scheduled-mode gate, catch-up after a missed run, retry cap.

section "Catch-up & retry (scheduled mode)"
PH2="$TMP/catchup"; mkdir -p "$PH2"
cp "$TMP/pipe.env" "$TMP/catchup.env"
sched() {  # sched <HHMM> [args...]: run --scheduled as if the clock said HHMM
  local hm="$1"; shift
  BRIEF_NOW_HM="$hm" BRIEF_HOME="$PH2" BRIEF_CONFIG="$TMP/catchup.env" CURL_BIN="$TESTS_DIR/fake-curl.sh" \
    TG_NO_SLEEP=1 BRIEF_SKIP_CHROME=1 BRIEF_SKIP_NETWORK_WAIT=1 \
    "$REPO_DIR/brief" run --scheduled --only tech "$@" >"$TMP/pipe.out" 2>&1
}
logs_before() { ls "$PH2/logs" 2>/dev/null | grep -c '^run-' ; }

reset_fake "200${T}{\"ok\":true}"
n0="$(logs_before)"
FAKE_CLAUDE_MODE=ok sched 0530; rc=$?
check "login at 05:30 (before 06:00) → nothing runs yet" bash -c "[ $rc = 0 ] && [ ! -s '$FAKE_CALLS' ]"
check "…and records why (not due)" grep -q 'not due until 06:00' "$PH2/state/last_check"
check "…without creating a run log (silent check)" [ "$(logs_before)" = "$n0" ]

reset_fake "200${T}{\"ok\":true}"
FAKE_CLAUDE_MODE=ok sched 1015; rc=$?
check "login at 10:15 with no brief today → catch-up run delivers" bash -c "[ $rc = 0 ] && [ -s '$FAKE_CALLS' ] && [ \"\$(cat '$PH2/state/last_success')\" = '$TODAY' ]"

reset_fake "200${T}{\"ok\":true}"
FAKE_CLAUDE_MODE=ok sched 1045; rc=$?
check "next interval check after delivery → skips quietly" bash -c "[ $rc = 0 ] && [ ! -s '$FAKE_CALLS' ] && grep -q 'already delivered' '$PH2/state/last_check'"

# Failure + retry cap
rm -f "$PH2/state/last_success" "$PH2/state/attempts"
for i in 1 2 3; do
  reset_fake "200${T}{\"ok\":true}"
  FAKE_CLAUDE_MODE=error sched 0700
  cp "$FAKE_CALLS" "$TMP/alert-$i.calls"
done
check "each failed attempt sends exactly one alert" bash -c "[ \$(grep -c '^CALL' '$TMP/alert-1.calls') = 1 ]"
check "attempts counter reached 3" [ "$(awk '{print $2}' "$PH2/state/attempts")" = 3 ]
reset_fake "200${T}{\"ok\":true}"
FAKE_CLAUDE_MODE=error sched 0730; rc=$?
check "4th check after 3 failures → no more attempts today" bash -c "[ $rc = 0 ] && [ ! -s '$FAKE_CALLS' ] && grep -q 'failed attempts today' '$PH2/state/last_check'"

# Alert text: inspect what retry_note produces at each stage.
RUN_SCHEDULED=1; RETRY_MINUTES=30; MAX_DAILY_ATTEMPTS=3
ATTEMPT=1; n1="$(retry_note)"; ATTEMPT=3; n3="$(retry_note)"; RUN_SCHEDULED=0; n0="$(retry_note)"
check "alert on attempt 1: 'Will retry automatically in about 30 min (attempt 1 of 3 today).'" [ "$n1" = "Will retry automatically in about 30 min (attempt 1 of 3 today)." ]
check "alert on last attempt says no more retries" bash -c "case \"\$1\" in 'No more automatic retries'*) exit 0;; *) exit 1;; esac" _ "$n3"
check "manual runs get no retry note" [ -z "$n0" ]

# Retries reset the next day: attempts file from yesterday doesn't count.
printf '%s 3\n' "$(date_add_days "$TODAY" -1)" >"$PH2/state/attempts"
reset_fake "200${T}{\"ok\":true}"
FAKE_CLAUDE_MODE=ok sched 0900; rc=$?
check "yesterday's failed attempts don't block today" bash -c "[ $rc = 0 ] && [ -s '$FAKE_CALLS' ]"

# A run in progress → the interval check exits 0 quietly (no error, no alert).
rm -f "$PH2/state/last_success"
mkdir -p "$PH2/state/run.lock"; echo "$$" >"$PH2/state/run.lock/pid"
reset_fake "200${T}{\"ok\":true}"
FAKE_CLAUDE_MODE=ok sched 0900; rc=$?
check "check during an in-progress run → exit 0, nothing sent" bash -c "[ $rc = 0 ] && [ ! -s '$FAKE_CALLS' ] && grep -q 'in progress' '$PH2/state/last_check'"
rm -rf "$PH2/state/run.lock"

render_plist "$TMP/catchup.plist" "$HOME/.local/bin/claude"
check "plist: RunAtLoad = true (catch-up at login)" [ "$(plutil -extract RunAtLoad raw -o - "$TMP/catchup.plist")" = true ]
check "plist: StartInterval = 1800 (retry every 30 min)" [ "$(plutil -extract StartInterval raw -o - "$TMP/catchup.plist")" = 1800 ]
check "plist: still fires at 06:00" [ "$(plutil -extract StartCalendarInterval.0.Hour raw -o - "$TMP/catchup.plist")" = 6 ]
check "plist: also fires at the evening to-do hour (19:00)" [ "$(plutil -extract StartCalendarInterval.1.Hour raw -o - "$TMP/catchup.plist"):$(plutil -extract StartCalendarInterval.1.Minute raw -o - "$TMP/catchup.plist")" = 19:0 ]
