# shellcheck shell=bash
# Sourced by tests/run-tests.sh: event rules (weekend/online/90 days), smart reminders, source health.
# Uses fixed dates: Mon 2026-11-23 … Sun 2026-11-29.

# ---------------------------------------------------------------- item rules
section "Events & competitions rules (items_clean)"
MON=2026-11-23
{
  printf 'event\t\tOffline Tuesday\thttps://e/tue\t2026-11-24\tbangalore\td\n'
  printf 'event\t\tOffline Friday\thttps://e/fri\t2026-11-27\tbangalore\td\n'
  printf 'event\t\tOffline Sunday\thttps://e/sun\t2026-11-29\tBengaluru, offline\td\n'
  printf 'event\t\tOnline Wednesday\thttps://e/onl\t2026-11-25\tOnline\td\n'
  printf 'event\t\tMumbai meetup\thttps://e/mum\t2026-11-28\tMumbai\td\n'
  printf 'hackathon\t2026-11-20\tDeadline passed\thttps://e/past\t2026-12-05\tonline\td\n'
  printf 'competition\t2026-11-20\tDeadline passed, event ahead\thttps://e/pastdl\t\tonline\td\n'
  printf 'competition\t2027-03-15\tToo far out\thttps://e/far\t\tonline\td\n'
  printf 'competition\t2027-02-15\tWithin 90 days\thttps://e/ok90\t2027-02-20\tonline\td\n'
  printf 'event\t\tAlready happened\thttps://e/done\t2026-11-21\tonline\td\n'
  printf 'internship\t2026-11-01\tOld internship\thttps://e/intold\t\t\td\n'
  printf 'internship\t2026-12-10\tGood internship\thttps://e/intok\t\t\td\n'
} >"$TMP/rules.tsv"
items_clean "$TMP/rules.tsv" "$TMP/rules.clean.tsv" "$MON"
kept() { grep -q "	$1	" "$TMP/rules.clean.tsv"; }
check "offline Bangalore on a Tuesday → dropped" bash -c "! grep -q 'e/tue' '$TMP/rules.clean.tsv'"
check "offline Bangalore on Friday → kept" kept https://e/fri
check "offline 'Bengaluru, offline' on Sunday → kept, mode normalised" grep -q "e/sun	2026-11-29	bangalore" "$TMP/rules.clean.tsv"
check "online on a Wednesday → kept" kept https://e/onl
check "offline in another city → dropped" bash -c "! grep -q 'e/mum' '$TMP/rules.clean.tsv'"
check "registration deadline passed → dropped" bash -c "! grep -q 'e/past	' '$TMP/rules.clean.tsv' && ! grep -q 'e/pastdl' '$TMP/rules.clean.tsv'"
check "more than 90 days out → dropped" bash -c "! grep -q 'e/far' '$TMP/rules.clean.tsv'"
check "within 90 days → kept" kept https://e/ok90
check "already happened → dropped" bash -c "! grep -q 'e/done' '$TMP/rules.clean.tsv'"
check "internship with past deadline → dropped, future kept" bash -c "! grep -q 'e/intold' '$TMP/rules.clean.tsv' && grep -q 'e/intok' '$TMP/rules.clean.tsv'"
check "dropped list records the reason" grep -q "https://e/tue	offline on a weekday" "$TMP/rules.clean.tsv.dropped"
check "every kept row has 7 fields" bash -c "awk -F'\t' 'NF != 7 { bad = 1 } END { exit bad }' '$TMP/rules.clean.tsv'"

printf '📅 EVENTS & COMPETITIONS\n\n1. Tue thing\nd\nhttps://e/tue\n\n2. Fri thing\nd\nhttps://e/fri\n\n3. Mumbai\nd\nhttps://e/mum\n' |
  filter_section_items "$TMP/rules.clean.tsv.dropped" >"$TMP/filtered.txt"
check "section text: dropped items removed, the rest renumbered" bash -c "grep -q '^1. Fri thing' '$TMP/filtered.txt' && ! grep -q 'Tue thing\|Mumbai' '$TMP/filtered.txt' && head -1 '$TMP/filtered.txt' | grep -q EVENTS"
printf '📅 EVENTS & COMPETITIONS\n\n1. Tue thing\nd\nhttps://e/tue\n' | filter_section_items "$TMP/rules.clean.tsv.dropped" >"$TMP/filtered2.txt"
check "section with every item dropped → no item links left" [ "$(section_item_count "$TMP/filtered2.txt")" = 0 ]

# ---------------------------------------------------------------- reminders
section "Smart reminders"
REM_SAVE="$REMINDERS_FILE"
REMINDERS_FILE="$TMP/rem.tsv"
# simulate <seen> <first_day> <last_day>: run reminders_due each day, record like a real send,
# print the day offsets (from the first day) on which the URL https://r/x was reminded.
simulate() {
  local seen="$1" start="$2" n="$3" i day out=""
  : >"$REMINDERS_FILE"; : >"$TMP/none.tsv"
  for i in $(seq 0 "$n"); do
    day="$(date_add_days "$start" "+$i")"
    reminders_due "$day" "$seen" "$TMP/none.tsv" "$REMINDERS_FILE" "$TMP/rmsg.txt" "$TMP/rurls.txt"
    if grep -qx 'https://r/x' "$TMP/rurls.txt" 2>/dev/null; then out="$out $i"; reminders_record "$day" "$TMP/rurls.txt"; fi
  done
  echo "${out# }"
}
printf '2026-11-23\tevent\t\tSunday meetup\thttps://r/x\t2026-11-29\tbangalore\tSun · 10 AM · HSR (offline)\n' >"$TMP/seen-r1.tsv"
got="$(simulate "$TMP/seen-r1.tsv" 2026-11-23 6)"
check "found Mon, event Sun → reminded Wed, Fri, Sat, Sun (offsets 2 4 5 6; got: $got)" [ "$got" = "2 4 5 6" ]

printf '2026-11-23\tcompetition\t2026-12-23\tBig contest\thttps://r/x\t\tonline\tOnline\n' >"$TMP/seen-r2.tsv"
got="$(simulate "$TMP/seen-r2.tsv" 2026-11-23 32)"
check "30 days out → weekly, then every 4, every 2, then daily (got: $got)" [ "$got" = "7 11 15 19 23 25 27 28 29 30" ]

printf '2026-11-23\tinternship\t2026-12-13\tSWE intern\thttps://r/x\t\t\t\n' >"$TMP/seen-r3.tsv"
got="$(simulate "$TMP/seen-r3.tsv" 2026-11-23 20)"
check "internship: no reminders until 14 days before the deadline (got: $got)" [ "${got%% *}" -ge 6 ]

printf '2026-11-20\tevent\t\tPast event\thttps://r/x\t2026-11-22\tonline\t\n' >"$TMP/seen-r4.tsv"
check "past dates are never reminded" [ -z "$(simulate "$TMP/seen-r4.tsv" 2026-11-23 5)" ]

# Message content
{
  printf '2026-11-20\tevent\t2026-11-26\tWorkshop with registration\thttps://r/reg\t2026-11-28\tbangalore\tSat · 11 AM · Indiranagar (offline)\n'
  printf '2026-11-20\thackathon\t\tOld-format row\thttps://r/old\n'
  printf '2026-11-20\tcompetition\t2026-11-25\tCloses Wed\thttps://r/wed\t\tonline\tOnline · ₹50k\n'
  printf '2026-11-20\tnews\t\tNews never reminded\thttps://r/news\t\t\t\n'
} >"$TMP/seen-r5.tsv"
printf 'competition\t2026-11-25\tCloses Wed\thttps://r/wed\t\tonline\tOnline\n' >"$TMP/today-items.tsv"
: >"$REMINDERS_FILE"
reminders_due 2026-11-23 "$TMP/seen-r5.tsv" "$TMP/none.tsv" "$REMINDERS_FILE" "$TMP/rmsg.txt" "$TMP/rurls.txt"
check "message starts with 🔔 REMINDERS" [ "$(head -1 "$TMP/rmsg.txt")" = "🔔 REMINDERS" ]
check "event with an earlier registration deadline says 'registration closes Thu 26 Nov (in 3 days)'" grep -q "registration closes Thu 26 Nov (in 3 days)" "$TMP/rmsg.txt"
check "competition says 'deadline Wed 25 Nov (in 2 days)'" grep -q "deadline Wed 25 Nov (in 2 days)" "$TMP/rmsg.txt"
check "includes the stored details line" grep -q "Sat · 11 AM · Indiranagar (offline)" "$TMP/rmsg.txt"
check "sorted by date (Wed deadline first)" [ "$(grep -m1 '^https' "$TMP/rmsg.txt")" = "https://r/wed" ]
check "old 5-column rows without dates and news are not reminded" bash -c "! grep -q 'r/old\|r/news' '$TMP/rmsg.txt'"
reminders_due 2026-11-23 "$TMP/seen-r5.tsv" "$TMP/today-items.tsv" "$REMINDERS_FILE" "$TMP/rmsg.txt" "$TMP/rurls.txt"
check "an item sent as new today is not also reminded" bash -c "! grep -q 'r/wed' '$TMP/rurls.txt'"
reminders_record 2026-11-23 "$TMP/rurls.txt"
reminders_due 2026-11-23 "$TMP/seen-r5.tsv" "$TMP/none.tsv" "$REMINDERS_FILE" "$TMP/rmsg.txt" "$TMP/rurls.txt"
check "never reminded twice on the same day" bash -c "! grep -q 'r/reg' '$TMP/rurls.txt'"
check "reminders.tsv counts reminders" grep -q "https://r/reg	2026-11-23	1" "$REMINDERS_FILE"
REMINDERS_FILE="$REM_SAVE"

# ---------------------------------------------------------------- source health
section "Source health (adaptive skipping)"
SH_SAVE="$SOURCE_HEALTH_FILE"
SOURCE_HEALTH_FILE="$TMP/health.tsv"; : >"$SOURCE_HEALTH_FILE"
mkdir -p "$TMP/srun"
day_run() {  # day_run <date> <status for devpost>
  printf 'https://www.devpost.com/hackathons\t%s\t403\nkaggle.com\tok\t\n' "$2" >"$TMP/srun/sources.tsv"
  sources_update "$TMP/srun" "$1"
}
printf 'mlh.io\tfail\tnot opened, only searched\n' >"$TMP/srun/sources.tsv"; sources_update "$TMP/srun" 2026-11-22
check "a site the run never tried ('not opened') is not counted as failing" bash -c "! grep -q mlh.io '$SOURCE_HEALTH_FILE'"
day_run 2026-11-23 fail; day_run 2026-11-23 fail
check "two failures on the same day count once" grep -q "^devpost.com	1	" "$SOURCE_HEALTH_FILE"
day_run 2026-11-24 fail
check "domain normalised (www., scheme and path stripped)" grep -q "^devpost.com	" "$SOURCE_HEALTH_FILE"
check "not blocked after 2 failing days" [ -z "$(sources_blocked 2026-11-24)" ]
day_run 2026-11-25 fail
check "blocked after 3 failing days in a row, for 14 days" [ "$(sources_blocked 2026-11-25 | cut -f1,2)" = "devpost.com	2026-12-09" ]
check "…reported as newly blocked" grep -q "^devpost.com	2026-12-09" "$TMP/srun/newly_blocked.tsv"
check "…footer line says when it will be retried" grep -q "Stopped using devpost.com for now (failed 3 days running; will retry Wed 9 Dec)" <(sources_footer_lines "$TMP/srun/newly_blocked.tsv")
render_prompt "$TMP/run1" "events" 0 2026-11-30
check "prompt tells the run not to fetch it" bash -c "grep -q 'Do NOT fetch or open them' '$TMP/run1/prompt.md' && grep -q -- '- devpost.com (403)' '$TMP/run1/prompt.md'"
check "a working site is never blocked" bash -c "! sources_blocked 2026-11-25 | grep -q kaggle"
check "block expires after 14 days" [ -z "$(sources_blocked 2026-12-09)" ]
day_run 2026-12-09 fail
check "one more failure after the retry → blocked again for 30 days" [ "$(sources_blocked 2026-12-09 | cut -f2)" = "2027-01-08" ]
day_run 2027-01-08 ok
check "a successful read clears everything" bash -c "[ -z \"\$(sources_blocked 2027-01-08)\" ] && grep -q '^devpost.com	0	' '$SOURCE_HEALTH_FILE'"
day_run 2027-01-09 fail; day_run 2027-01-10 fail; day_run 2027-01-11 fail
check "after a reset by success, the next block is 14 days again" [ "$(sources_blocked 2027-01-11 | cut -f2)" = "2027-01-25" ]
render_prompt "$TMP/run1" "events" 0 2027-03-01
check "nothing blocked → prompt says none" grep -q "None right now." "$TMP/run1/prompt.md"
out="$(cmd_sources 2>&1)"
check "./brief sources shows the table" bash -c "printf '%s' \"\$1\" | grep -q 'devpost.com'" _ "$out"
cmd_sources --reset https://www.devpost.com/ >/dev/null 2>&1
check "./brief sources --reset forgets the site" bash -c "! grep -q devpost '$SOURCE_HEALTH_FILE'"
SOURCE_HEALTH_FILE="$SH_SAVE"

# ---------------------------------------------------------------- pipeline: reminders only recorded on real sends
section "Reminders in the pipeline"
PH3="$TMP/rempipe"; mkdir -p "$PH3/state"
rp() { BRIEF_HOME="$PH3" BRIEF_CONFIG="$TMP/pipe.env" CURL_BIN="$TESTS_DIR/fake-curl.sh" TG_NO_SLEEP=1 BRIEF_SKIP_CHROME=1 BRIEF_SKIP_NETWORK_WAIT=1 \
  "$REPO_DIR/brief" "$@" >"$TMP/pipe.out" 2>&1; }
printf '%s\tevent\t\tSaved meetup\thttps://r/saved\t%s\tonline\tOnline · 7 PM\n' "$(d -2)" "$(d +3)" >"$PH3/state/seen.tsv"
reset_fake "200${T}{\"ok\":true}"
sed -i '' 's/^MAX_SECONDS=.*/MAX_SECONDS=60/' "$TMP/pipe.env"
FAKE_CLAUDE_MODE=ok rp run --dry-run --only tech
rd3="$(ls -d "$PH3"/runs/*-dry | tail -1)"
check "dry run shows the due reminder" grep -q 'https://r/saved' "$rd3/send/60-reminders.txt"
check "header counts reminders" grep -q '🔔 Reminders: 1' "$rd3/send/00-header.txt"
check "dry run does not record it" [ ! -s "$PH3/state/reminders.tsv" ]
reset_fake "200${T}{\"ok\":true}"
FAKE_CLAUDE_MODE=ok rp run --only tech
check "real run records it in reminders.tsv" grep -q "^https://r/saved	$TODAY	1" "$PH3/state/reminders.tsv"
reset_fake "200${T}{\"ok\":true}"
FAKE_CLAUDE_MODE=ok rp run --only tech
check "second run the same day doesn't remind again" bash -c "! ls '$PH3'/archive/*-2/60-reminders.txt >/dev/null 2>&1"
check "--only competitions still works (alias for events)" bash -c "BRIEF_HOME='$PH3' BRIEF_CONFIG='$TMP/pipe.env' BRIEF_SKIP_CHROME=1 FAKE_CLAUDE_MODE=ok '$REPO_DIR/brief' run --dry-run --only competitions >/dev/null 2>&1"
