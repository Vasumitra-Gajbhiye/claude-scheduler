# shellcheck shell=bash
# Sourced by tests/run-tests.sh: state, closing-soon, lock, prompt, plist, full pipeline (fake claude).

TODAY="$(today_iso)"
d() { date_add_days "$TODAY" "$1"; }

# ---------------------------------------------------------------- prune
section "seen.tsv prune"
mkdir -p "$STATE_DIR"
{
  printf '%s\tnews\t\tOld news, no deadline\thttps://a/old-news\n' "$(d -200)"
  printf '%s\tcompetition\t%s\tOld comp, deadline passed\thttps://a/old-past\n' "$(d -200)" "$(d -150)"
  printf '%s\tinternship\t%s\tOld internship, deadline ahead\thttps://a/old-future\n' "$(d -200)" "$(d +10)"
  printf '%s\tnews\t\tRecent news\thttps://a/recent\n' "$(d -5)"
  printf '%s\tcompetition\t%s\tRecent comp, past deadline\thttps://a/recent-past\n' "$(d -10)" "$(d -1)"
  printf 'garbage line without tabs\n'
} >"$SEEN_FILE"
dropped="$(seen_prune "$TODAY" 120)"
check "dropped 3 rows (2 stale + 1 malformed): got $dropped" [ "$dropped" = 3 ]
check "kept old row whose deadline is still ahead" grep -q 'old-future' "$SEEN_FILE"
check "kept recent rows (even with a past deadline)" bash -c "grep -q 'a/recent	' '$SEEN_FILE' || grep -q 'a/recent\$' '$SEEN_FILE'; grep -q recent-past '$SEEN_FILE'"
check "dropped old row with no deadline" bash -c "! grep -q old-news '$SEEN_FILE'"
check "dropped old row with past deadline" bash -c "! grep -q old-past '$SEEN_FILE'"

# ---------------------------------------------------------------- closing soon
section "Closing soon (deterministic)"
{
  printf '%s\tcompetition\t%s\tPast deadline comp\thttps://c/past\n' "$(d -3)" "$(d -1)"
  printf '%s\tinternship\t%s\tCloses today\thttps://c/today\n' "$(d -3)" "$TODAY"
  printf '%s\tcompetition\t%s\tCloses in two days\thttps://c/plus2\n' "$(d -2)" "$(d +2)"
  printf '%s\tcompetition\t%s\tCloses in two days (dup)\thttps://c/plus2\n' "$(d -1)" "$(d +2)"
  printf '%s\tinternship\t%s\tCloses in ten days\thttps://c/plus10\n' "$(d -1)" "$(d +10)"
  printf '%s\tevent\t%s\tMeetup tomorrow\thttps://c/event\n' "$(d -1)" "$(d +1)"
  printf '%s\tnews\t\tNews item\thttps://c/news\n' "$(d -1)"
} >"$TMP/seen-cs.tsv"
cs="$(closing_soon "$TODAY" 3 "$TMP/seen-cs.tsv")"
printf '%s\n' "$cs" >"$TMP/cs.txt"
check "starts with ⏰ CLOSING SOON" [ "$(head -1 "$TMP/cs.txt")" = "⏰ CLOSING SOON" ]
check "includes today's deadline as (today)" grep -q "closes $(date_pretty "$TODAY") (today)" "$TMP/cs.txt"
check "includes +2d as 'closes $(date_pretty "$(d +2)") (in 2 days)'" grep -q "closes $(date_pretty "$(d +2)") (in 2 days)" "$TMP/cs.txt"
check "events say 'happens … (tomorrow)'" grep -q "happens $(date_pretty "$(d +1)") (tomorrow)" "$TMP/cs.txt"
check "excludes past deadlines" bash -c "! grep -q c/past '$TMP/cs.txt'"
check "excludes +10d (outside the 3-day window)" bash -c "! grep -q c/plus10 '$TMP/cs.txt'"
check "dedupes by URL (one +2d entry)" [ "$(grep -c 'c/plus2' "$TMP/cs.txt")" = 1 ]
check "sorted by deadline (today first)" [ "$(grep -m1 '^https' "$TMP/cs.txt")" = "https://c/today" ]
check "empty seen → no message" [ -z "$(closing_soon "$TODAY" 3 /dev/null)" ]
say "    ${C_DIM}sample:${C_OFF}"; sed 's/^/      /' "$TMP/cs.txt"

# ---------------------------------------------------------------- items.tsv cleaning
section "items.tsv validation"
printf 'news\t\tGood\thttps://ok/1\r\nbogus\t\tBad type\thttps://x\ncompetition\tnot-a-date\tBad date\thttps://ok/2\ntech\t\tNo url\tnot-a-url\nevent\t2026-12-01\tGood event\thttps://ok/3\n' >"$TMP/items-raw.tsv"
items_clean "$TMP/items-raw.tsv" "$TMP/items-clean.tsv"
check "keeps 3 valid rows" [ "$(wc -l <"$TMP/items-clean.tsv" | tr -d ' ')" = 3 ]
check "invalid deadline blanked" grep -q "$(printf 'competition\t\tBad date')" "$TMP/items-clean.tsv"
check "CR stripped" bash -c "! grep -q $'\r' '$TMP/items-clean.tsv'"

# ---------------------------------------------------------------- lock
section "Run lock"
rm -rf "$LOCK_DIR"; LOCK_OWNED=0
check "first acquire succeeds" lock_acquire
check "second acquire (live owner) is refused" bash -c '. "$REPO_DIR/lib/common.sh"; . "$REPO_DIR/lib/state.sh"; MAX_SECONDS=60; ! lock_acquire'
lock_release
check "release removes the lock" [ ! -d "$LOCK_DIR" ]
mkdir -p "$LOCK_DIR"; echo 999999 >"$LOCK_DIR/pid"; LOCK_OWNED=0
check "lock with dead pid is reclaimed" lock_acquire
lock_release
mkdir -p "$LOCK_DIR"; echo "$$" >"$LOCK_DIR/pid"; touch -t 202001010000 "$LOCK_DIR"; LOCK_OWNED=0
check "lock older than 2×MAX_SECONDS is reclaimed (even with live pid)" lock_acquire
lock_release

# ---------------------------------------------------------------- prompt
section "Prompt rendering"
mkdir -p "$TMP/run1"
render_prompt "$TMP/run1" "tech india" 1 "$TODAY"
check "renders without leftover {{placeholders}}" bash -c "! grep -q '{{' '$TMP/run1/prompt.md'"
check "contains the run dir and section paths" grep -q -- "- tech → $TMP/run1/20-tech.txt" "$TMP/run1/prompt.md"
check "contains profile.md content" grep -q "Who this brief is for" "$TMP/run1/prompt.md"
check "contains sources.md content" grep -q "news.ycombinator.com" "$TMP/run1/prompt.md"
check "contains today's date" grep -q "($TODAY)" "$TMP/run1/prompt.md"
check "Chrome enabled note" grep -q "Claude in Chrome is ENABLED" "$TMP/run1/prompt.md"
render_prompt "$TMP/run1" "tech" 0 "$TODAY"
check "Chrome disabled note for tech-only" grep -q "Claude in Chrome is NOT available" "$TMP/run1/prompt.md"
check "sections_need_chrome: tech → no" bash -c '. "$REPO_DIR/lib/claude.sh"; ! sections_need_chrome tech'
check "sections_need_chrome: india → yes" sections_need_chrome india

# ---------------------------------------------------------------- plist
section "launchd plist"
render_plist "$TMP/test.plist" "$HOME/.local/bin/claude"
check "plist passes plutil -lint" plutil -lint "$TMP/test.plist"
check "Hour = 6" [ "$(plutil -extract StartCalendarInterval.Hour raw -o - "$TMP/test.plist")" = 6 ]
check "runs 'brief run --scheduled'" [ "$(plutil -extract ProgramArguments.3 raw -o - "$TMP/test.plist")" = "--scheduled" ]
check "absolute brief path" [ "$(plutil -extract ProgramArguments.1 raw -o - "$TMP/test.plist")" = "$REPO_DIR/brief" ]
check "PATH includes ~/.local/bin and /opt/homebrew/bin" bash -c "p=\$(plutil -extract EnvironmentVariables.PATH raw -o - '$TMP/test.plist'); case \$p in *$HOME/.local/bin*/opt/homebrew/bin*) exit 0;; *) exit 1;; esac"
out="$("$REPO_DIR/brief" install --print 2>&1)"; rc=$?
check "./brief install --print renders without installing" [ "$rc" = 0 ]
check "nothing was installed into ~/Library/LaunchAgents" [ ! -f "$HOME/Library/LaunchAgents/com.morningbrief.daily.plist" ]
if ! is_mac_mini; then
  out="$("$REPO_DIR/brief" install 2>&1)"; rc=$?
  check "./brief install refuses on a non-Mac-mini without --yes" [ "$rc" != 0 ]
fi

# ---------------------------------------------------------------- full pipeline with fake claude + fake curl
section "Full pipeline (fake claude + fake curl)"
PH="$TMP/pipe"; mkdir -p "$PH"
cp "$BRIEF_CONFIG" "$TMP/pipe.env"
printf 'CLAUDE_BIN="%s"\n' "$TESTS_DIR/fake-claude.sh" >>"$TMP/pipe.env"
pipe() { BRIEF_HOME="$PH" BRIEF_CONFIG="$TMP/pipe.env" CURL_BIN="$TESTS_DIR/fake-curl.sh" TG_NO_SLEEP=1 BRIEF_SKIP_CHROME=1 \
  ANTHROPIC_API_KEY=sk-should-be-unset "$REPO_DIR/brief" "$@" >"$TMP/pipe.out" 2>&1; }
export FAKE_CALLS FAKE_COUNTER FAKE_RESPONSES
reset_fake "200${T}{\"ok\":true}"

FAKE_CLAUDE_MODE=ok pipe run --dry-run; rc=$?
check "dry run exits 0" [ "$rc" = 0 ]
check "dry run prints the India section" grep -q '🇮🇳 INDIA' "$TMP/pipe.out"
check "dry run sends nothing" [ ! -s "$FAKE_CALLS" ]
check "dry run does not write seen.tsv rows" [ ! -s "$PH/state/seen.tsv" ]
check "dry run does not archive" [ -z "$(ls "$PH/archive" 2>/dev/null)" ]
rd="$(ls -d "$PH"/runs/*-dry | tail -1)"
check "claude was called with --strict-mcp-config, dontAsk, prompts none" bash -c "grep -qx -- --strict-mcp-config '$rd/fake-args.txt' && grep -qx dontAsk '$rd/fake-args.txt' && grep -qx none '$rd/fake-args.txt'"
check "claude got --chrome for a full run" grep -qx -- --chrome "$rd/fake-args.txt"
check "Bash is disallowed for the inner run" bash -c "grep -A1 -x -- --disallowedTools '$rd/fake-args.txt' | grep -q '^Bash,'"
check "Edit is scoped to the run dir" bash -c "grep -A1 -x -- --allowedTools '$rd/fake-args.txt' | grep -qF 'Edit(/$rd/**)'"
check "ANTHROPIC_API_KEY was unset before calling claude" [ ! -s "$rd/fake-env.txt" ]
check "empty section (events: nothing notable) skipped" bash -c "[ ! -e '$rd/send/30-events.txt' ]"
check "markdown ** stripped from section text" bash -c "! grep -q '\*\*' '$rd/send/10-india.txt'"
check "footer lists notes.txt" grep -q 'luma.com via Chrome: fake note' "$rd/send/90-footer.txt"
check "header has per-section counts" bash -c "grep -q 'India: 2' '$rd/send/00-header.txt' && grep -q 'Tech & AI: 1' '$rd/send/00-header.txt'"

reset_fake "200${T}{\"ok\":true}"
FAKE_CLAUDE_MODE=ok pipe run; rc=$?
check "real run exits 0" [ "$rc" = 0 ]
calls="$(grep '^CALL' "$FAKE_CALLS" | wc -l | tr -d ' ')"
check "sent header + 4 sections + footer = 6 messages (got $calls)" [ "$calls" = 6 ]
check "only the first message (header) makes a sound" [ "$(grep -c 'disable_notification=false' "$FAKE_CALLS")" = 1 ]
check "seen.tsv got 5 valid rows with today's date" [ "$(grep -c "^$TODAY	" "$PH/state/seen.tsv")" = 5 ]
check "archive/$TODAY created with messages" [ -s "$PH/archive/$TODAY/00-header.txt" ]
check "last_success = today" [ "$(cat "$PH/state/last_success")" = "$TODAY" ]

reset_fake "200${T}{\"ok\":true}"
FAKE_CLAUDE_MODE=ok pipe run --only tech; rc=$?
check "second real run same day archives to $TODAY-2" [ -d "$PH/archive/$TODAY-2" ]
check "closing soon (+2d competition from run 1) appears in run 2" [ -s "$PH/archive/$TODAY-2/60-closing.txt" ]
rd2="$(ls -d "$PH"/runs/* | grep -v -- -dry | tail -1)"
check "--only tech runs with --no-chrome" grep -qx -- --no-chrome "$rd2/fake-args.txt"

reset_fake "200${T}{\"ok\":true}"
FAKE_CLAUDE_MODE=ok pipe run --scheduled; rc=$?
check "--scheduled skips when already delivered today" bash -c "[ $rc = 0 ] && grep -q 'already delivered' '$TMP/pipe.out' && [ ! -s '$FAKE_CALLS' ]"
touch "$PH/state/force_next"
FAKE_CLAUDE_MODE=ok pipe run --scheduled --only tech; rc=$?
check "--scheduled runs once when kickstart left force_next" bash -c "[ $rc = 0 ] && [ -s '$FAKE_CALLS' ] && [ ! -e '$PH/state/force_next' ]"

reset_fake "200${T}{\"ok\":true}"
pipe resend "$TODAY"; rc=$?
check "resend $TODAY sends the archived messages" bash -c "[ $rc = 0 ] && [ \$(grep -c '^CALL' '$FAKE_CALLS') = 6 ]"

reset_fake "200${T}{\"ok\":true}"
FAKE_CLAUDE_MODE=usage pipe run --only tech; rc=$?
check "usage limit → exit 1" [ "$rc" = 1 ]
check "usage limit → one alert sent, saying so plainly" bash -c "[ \$(grep -c '^CALL' '$FAKE_CALLS') = 1 ] && grep -q 'usage limit' '$PH/state/last_failure'"

reset_fake "200${T}{\"ok\":true}"
FAKE_CLAUDE_MODE=empty pipe run --only tech; rc=$?
check "no section files → failure alert" bash -c "[ $rc = 1 ] && grep -q 'no section files' '$PH/state/last_failure'"

reset_fake "200${T}{\"ok\":true}"
sed -i '' 's/^MAX_SECONDS=.*/MAX_SECONDS=4/' "$TMP/pipe.env"
s0="$(date +%s)"; FAKE_CLAUDE_MODE=sleep pipe run --only tech; rc=$?; el=$(( $(date +%s) - s0 ))
check "timeout kills claude and alerts (exit $rc after ${el}s)" bash -c "[ $rc = 1 ] && [ $el -lt 30 ] && grep -q 'timed out' '$PH/state/last_failure'"
check "no orphaned fake-claude process" bash -c "! pgrep -f 'fake-claude.sh' >/dev/null"
sed -i '' 's/^MAX_SECONDS=.*/MAX_SECONDS=60/' "$TMP/pipe.env"

reset_fake "200${T}{\"ok\":true}" "401${T}{\"ok\":false,\"description\":\"Unauthorized\"}"
FAKE_CLAUDE_MODE=ok pipe run --only tech; rc=$?
before="$(grep -c "^$TODAY	" "$PH/state/seen.tsv")"
check "Telegram failure mid-send → exit 1, nothing committed" bash -c "[ $rc = 1 ] && grep -q 'Telegram send failed' '$PH/state/last_failure'"
check "token never appears in any log" bash -c "! grep -rq '$FAKE_TOKEN' '$PH/logs' '$PH/state'"

mkdir -p "$PH/state/run.lock"; echo "$$" >"$PH/state/run.lock/pid"
FAKE_CLAUDE_MODE=ok pipe run --dry-run --only tech; rc=$?
check "concurrent run refused while lock held" bash -c "[ $rc = 1 ] && grep -q 'already in progress' '$TMP/pipe.out'"
rm -rf "$PH/state/run.lock"

pipe status; check "status runs" grep -q 'Last run' "$TMP/pipe.out"
pipe logs; check "logs shows latest log" grep -q 'Morning Brief' "$TMP/pipe.out"
pipe run --only nonsense; check "bad --only is rejected" grep -q "Unknown section" "$TMP/pipe.out"
