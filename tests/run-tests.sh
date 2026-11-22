#!/bin/bash
# Offline test suite for Morning Brief. Never sends to Telegram, never calls claude.
# Usage: tests/run-tests.sh
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
export REPO_DIR
TMP="$(mktemp -d -t mbtests)"
trap 'rm -rf "$TMP"' EXIT

export BRIEF_HOME="$TMP/home"
export BRIEF_CONFIG="$TMP/config.env"
mkdir -p "$BRIEF_HOME"
FAKE_TOKEN="1234567890:AAFakeTokenForTestsOnly_abcdefghijklmn"
cat >"$BRIEF_CONFIG" <<EOF
TELEGRAM_BOT_TOKEN="$FAKE_TOKEN"
TELEGRAM_CHAT_ID="42"
MODEL="sonnet"
MAX_SECONDS=60
CLOSING_SOON_DAYS=3
SEEN_RETENTION_DAYS=120
EOF
chmod 600 "$BRIEF_CONFIG"

# shellcheck disable=SC1090
for l in common telegram state claude chrome run launchd doctor; do
  [ -f "$REPO_DIR/lib/$l.sh" ] && . "$REPO_DIR/lib/$l.sh"
done
load_config

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m✗ %s\033[0m\n' "$1"; [ $# -gt 1 ] && printf '    %s\n' "$2"; }
check() {
  local name="$1"; shift
  if "$@"; then ok "$name"; else
    bad "$name"
    # TEST_DEBUG=1 shows the tail of the last pipeline run's output on failure.
    if [ -n "${TEST_DEBUG:-}" ] && [ -f "$TMP/pipe.out" ]; then tail -8 "$TMP/pipe.out" | sed 's/^/      | /'; fi
  fi
}
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- splitter
section "Telegram splitter"
gen="$TMP/long.txt"
perl -CSD -e '
  my @e = ("☀️","🇮🇳","💻","📅","🏆","💼","⏰","✅","🕓","👨‍👩‍👧");
  my $s = ""; my $i = 0;
  while (length($s) < 10000) {
    $i++;
    $s .= "$i. ". ("word " x (($i % 9) + 1)) . $e[$i % @e] . " ünïcödé ₹2L\n";
    $s .= "https://example.com/item/$i\n\n" if $i % 3 == 0;
  }
  print $s;' >"$gen"
chars="$(perl -CSD -ne 'BEGIN{$n=0} $n+=length; END{print $n}' "$gen")"
check "fixture is ≥10,000 characters with emoji ($chars chars, $(wc -c <"$gen" | tr -d ' ') bytes)" [ "$chars" -ge 10000 ]
outd="$TMP/chunks"
n="$(tg_split "$gen" "$outd")"
check "split into multiple chunks ($n)" [ "$n" -ge 3 ]
maxb=0; allvalid=1; endsclean=1
for f in "$outd"/chunk-*.txt; do
  b="$(wc -c <"$f" | tr -d ' ')"; [ "$b" -gt "$maxb" ] && maxb="$b"
  perl -MEncode -e 'local $/; my $d=<STDIN>; eval { Encode::decode("UTF-8",$d,Encode::FB_CROAK); 1 } or exit 1' <"$f" || allvalid=0
  [ "$(tail -c 1 "$f" | od -An -c | tr -d ' ')" = '\n' ] || endsclean=0
done
check "every chunk ≤ 3800 bytes (max $maxb)" [ "$maxb" -le 3800 ]
check "every chunk is valid UTF-8 (no split emoji)" [ "$allvalid" = 1 ]
check "chunks end on a line boundary" [ "$endsclean" = 1 ]
orig_lines="$(grep -cv '^$' "$gen")"; got_lines="$(cat "$outd"/chunk-*.txt | grep -cv '^$')"
check "no content lost ($got_lines/$orig_lines non-empty lines)" [ "$orig_lines" = "$got_lines" ]
check "joined chunks equal the original (ignoring blank lines)" \
  diff -q <(grep -v '^$' "$gen") <(cat "$outd"/chunk-*.txt | grep -v '^$')
# A single giant line with emoji gets hard-split on character boundaries.
perl -CSD -e 'print "🇮🇳" x 3000, "\n"' >"$TMP/oneline.txt"
n2="$(tg_split "$TMP/oneline.txt" "$TMP/chunks2")"
v=1; for f in "$TMP"/chunks2/chunk-*.txt; do
  [ "$(wc -c <"$f" | tr -d ' ')" -le 3800 ] || v=0
  perl -MEncode -e 'local $/; my $d=<STDIN>; eval { Encode::decode("UTF-8",$d,Encode::FB_CROAK); 1 } or exit 1' <"$f" || v=0
done
check "overlong single line hard-split safely ($n2 chunks)" [ "$v" = 1 -a "$n2" -ge 6 ]
printf 'short message\n' >"$TMP/short.txt"
check "short message is one chunk" [ "$(tg_split "$TMP/short.txt" "$TMP/chunks3")" = 1 ]

# ---------------------------------------------------------------- telegram via fake curl
section "Telegram sending (fake curl, no network)"
export CURL_BIN="$TESTS_DIR/fake-curl.sh" TG_NO_SLEEP=1
export FAKE_CALLS="$TMP/calls.log" FAKE_COUNTER="$TMP/counter" FAKE_RESPONSES="$TMP/responses"
export TG_SLEEP_LOG="$TMP/sleeps.log"
reset_fake() { : >"$FAKE_CALLS"; rm -f "$FAKE_COUNTER"; : >"$TG_SLEEP_LOG"; printf '%s\n' "$@" >"$FAKE_RESPONSES"; }
T=$'\t'
LOG_FILE="$TMP/tg.log"; : >"$LOG_FILE"

reset_fake "200${T}{\"ok\":true,\"result\":{}}"
tg_send_text "hello" 0; rc=$?
check "ok response → success" [ "$rc" = 0 ]
check "header message is not silent (disable_notification=false)" grep -q 'disable_notification=false' "$FAKE_CALLS"
check "link previews disabled" grep -q 'link_preview_options={"is_disabled":true}' "$FAKE_CALLS"
check "no parse_mode sent" bash -c "! grep -q parse_mode '$FAKE_CALLS'"
check "calls sendMessage" grep -q 'CALL 1 sendMessage' "$FAKE_CALLS"

reset_fake "200${T}{\"ok\":true}"
tg_send_file "$gen" 1; rc=$?
calls="$(grep -c '^CALL' "$FAKE_CALLS")"
check "10k message sent as $calls messages, all silent" [ "$rc" = 0 -a "$calls" = "$n" ]
check "silent messages use disable_notification=true" bash -c "! grep -q 'disable_notification=false' '$FAKE_CALLS'"
check "1s pause between messages" grep -q '^sleep 1$' "$TG_SLEEP_LOG"

reset_fake "429${T}{\"ok\":false,\"error_code\":429,\"description\":\"Too Many Requests: retry after 7\",\"parameters\":{\"retry_after\":7}}" \
           "200${T}{\"ok\":true}"
tg_send_text "rate limited" 1; rc=$?
check "429 then ok → success after retry" [ "$rc" = 0 -a "$(grep -c '^CALL' "$FAKE_CALLS")" = 2 ]
check "honours retry_after (slept 8s = 7+1)" grep -q '^sleep 8$' "$TG_SLEEP_LOG"

reset_fake "500${T}{\"ok\":false}" "502${T}" "200${T}{\"ok\":true}"
tg_send_text "flaky" 1; rc=$?
check "5xx, 5xx, ok → success on 3rd try" [ "$rc" = 0 -a "$(grep -c '^CALL' "$FAKE_CALLS")" = 3 ]

reset_fake "500${T}{\"ok\":false}"
tg_send_text "down" 1; rc=$?
check "3 failures → gives up after 3 tries" [ "$rc" != 0 -a "$(grep -c '^CALL' "$FAKE_CALLS")" = 3 ]

reset_fake "401${T}{\"ok\":false,\"error_code\":401,\"description\":\"Unauthorized\"}"
tg_send_text "bad token" 1; rc=$?
check "401 → fails immediately, no retry" [ "$rc" != 0 -a "$(grep -c '^CALL' "$FAKE_CALLS")" = 1 ]
check "401 error is explained (${TG_LAST_ERROR:-})" bash -c "case '${TG_LAST_ERROR:-}' in *401*Unauthorized*) exit 0;; *) exit 1;; esac"

reset_fake "200${T}{\"ok\":true,\"result\":{\"username\":\"my_brief_bot\"}}"
tg_getme
check "getMe returns bot username" [ "${TG_BOT_NAME:-}" = "@my_brief_bot" ]

check "token never written to the run log" bash -c "! grep -q '$FAKE_TOKEN' '$LOG_FILE'"
check "redact() scrubs the token" [ "$(printf 'url bot%s/x' "$FAKE_TOKEN" | redact)" = "url bot<redacted>/x" ]

# The token must travel via stdin config, never argv: check the fake saw no token in args.
check "token never passed as a curl argument" bash -c "! grep -q '$FAKE_TOKEN' '$FAKE_CALLS'"

reset_fake "200${T}{\"ok\":true,\"result\":[{\"update_id\":1,\"message\":{\"chat\":{\"id\":987654,\"type\":\"private\",\"first_name\":\"Vasu\",\"username\":\"vasu\"}}}]}"
out="$(cmd_chat_id 2>&1)"
check "chat-id prints the chat id" bash -c "printf '%s' \"\$1\" | grep -q 987654" _ "$out"
reset_fake "200${T}{\"ok\":true,\"result\":[]}"
out="$(cmd_chat_id 2>&1)"
check "chat-id explains what to do when no chats" bash -c "printf '%s' \"\$1\" | grep -q 'send it any message'" _ "$out"
unset CURL_BIN
CURL_BIN=curl

# ---------------------------------------------------------------- more suites appended below
for extra in "$TESTS_DIR"/suite-*.sh; do
  # shellcheck disable=SC1090
  [ -f "$extra" ] && . "$extra"
done

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
