# shellcheck shell=bash
# Sourced by tests/run-tests.sh: to-dos & exams (Outlook → Notion): the guard hook, the nag rules,
# and the `brief tasks` / brief pipelines with a fake claude.

# ---------------------------------------------------------------- guard
section "To-do guard (lib/hooks/guard.sh)"
GR="$TMP/g/run"; GD="$GR.guard"; mkdir -p "$GR" "$GD"
printf 'RUN_DIR=%s\nLEDGER=%s/ledger\nDS_IDS=aaaaaaaabbbb4ccc8ddd000000000001 aaaaaaaabbbb4ccc8ddd000000000002\nCHROME_DEVICE=dev1\nDRY=0\n' "$GR" "$GD" >"$GD/guard.conf"
: >"$GD/ledger"
gpre()  { printf '%s' "$1" | "$REPO_DIR/lib/hooks/guard.sh" pre "$GD" >/dev/null 2>&1; }
gpost() { printf '%s' "$1" | "$REPO_DIR/lib/hooks/guard.sh" post "$GD" >/dev/null 2>&1; }
allowed() { gpre "$1"; }
blocked() { gpre "$1"; [ $? = 2 ]; }
C=mcp__claude-in-chrome__; N=mcp__claude_ai_Notion__
check "navigate to the Outlook inbox → allowed" allowed "{\"tool_name\":\"${C}navigate\",\"tool_input\":{\"tabId\":1,\"url\":\"https://outlook.office.com/mail/inbox\"}}"
check "navigate to outlook.cloud.microsoft/mail/ → allowed" allowed "{\"tool_name\":\"${C}navigate\",\"tool_input\":{\"tabId\":1,\"url\":\"https://outlook.cloud.microsoft/mail/\"}}"
check "compose deeplink → blocked" blocked "{\"tool_name\":\"${C}navigate\",\"tool_input\":{\"tabId\":1,\"url\":\"https://outlook.office.com/mail/deeplink/compose?to=a@b.c\"}}"
check "Outlook options page → blocked" blocked "{\"tool_name\":\"${C}navigate\",\"tool_input\":{\"tabId\":1,\"url\":\"https://outlook.office.com/mail/options/mail/forwarding\"}}"
check "a link from an email → blocked" blocked "{\"tool_name\":\"${C}navigate\",\"tool_input\":{\"tabId\":1,\"url\":\"https://evil.example/x?d=secret\"}}"
check "inbox URL with a query string → blocked" blocked "{\"tool_name\":\"${C}navigate\",\"tool_input\":{\"tabId\":1,\"url\":\"https://outlook.office.com/mail/inbox?action=compose\"}}"
check "click on a ref never seen in the message list → blocked" blocked "{\"tool_name\":\"${C}computer\",\"tool_input\":{\"tabId\":1,\"action\":\"left_click\",\"ref\":\"ref_300\"}}"
LIST='  button \"Reply\" [ref_129]\n  listbox \"Message list No conversations selected\" [ref_279]\n   generic [ref_280]\n    option \"Unread Course Office Mid-term feedback form\" [ref_300]\n     button \"Mark as read\" [ref_303]\n    option \"IT Maintenance\" [ref_398]\n generic [ref_415]\n  option \"Elsewhere\" [ref_999]'
gpost "{\"tool_name\":\"${C}read_page\",\"tool_input\":{\"tabId\":1},\"tool_response\":[{\"type\":\"text\",\"text\":\"$LIST\"}]}"
check "read_page records only the message-list rows" bash -c "[ \"\$(cut -f2 '$GD/clickable.tsv' | tr '\n' ' ')\" = 'ref_300 ref_398 ' ]"
check "…with their Unread state" bash -c "grep -q '^1	ref_300	1	0' '$GD/clickable.tsv' && grep -q '^1	ref_398	0	0' '$GD/clickable.tsv'"
check "click on Reply → blocked" blocked "{\"tool_name\":\"${C}computer\",\"tool_input\":{\"tabId\":1,\"action\":\"left_click\",\"ref\":\"ref_129\"}}"
check "click on an option outside the message list → blocked" blocked "{\"tool_name\":\"${C}computer\",\"tool_input\":{\"tabId\":1,\"action\":\"left_click\",\"ref\":\"ref_999\"}}"
check "click by coordinates → blocked" blocked "{\"tool_name\":\"${C}computer\",\"tool_input\":{\"tabId\":1,\"action\":\"left_click\",\"ref\":\"ref_300\",\"coordinate\":[10,10]}}"
check "typing → blocked" blocked "{\"tool_name\":\"${C}computer\",\"tool_input\":{\"tabId\":1,\"action\":\"type\",\"text\":\"hello\"}}"
check "key press → blocked" blocked "{\"tool_name\":\"${C}computer\",\"tool_input\":{\"tabId\":1,\"action\":\"key\",\"text\":\"cmd+Enter\"}}"
check "scroll_to a ref → allowed" allowed "{\"tool_name\":\"${C}computer\",\"tool_input\":{\"tabId\":1,\"action\":\"scroll_to\",\"ref\":\"ref_398\"}}"
check "a short wait → allowed" allowed "{\"tool_name\":\"${C}computer\",\"tool_input\":{\"tabId\":1,\"action\":\"wait\",\"duration\":1}}"
check "a long wait → blocked" blocked "{\"tool_name\":\"${C}computer\",\"tool_input\":{\"tabId\":1,\"action\":\"wait\",\"duration\":60}}"
check "scrolling the list → allowed" allowed "{\"tool_name\":\"${C}computer\",\"tool_input\":{\"tabId\":1,\"action\":\"scroll\",\"coordinate\":[400,400],\"scroll_direction\":\"down\"}}"
check "click on a message row from the list → allowed" allowed "{\"tool_name\":\"${C}computer\",\"tool_input\":{\"tabId\":1,\"action\":\"left_click\",\"ref\":\"ref_300\"}}"
check "next click before re-reading the list → blocked" blocked "{\"tool_name\":\"${C}computer\",\"tool_input\":{\"tabId\":1,\"action\":\"left_click\",\"ref\":\"ref_398\"}}"
gpost "{\"tool_name\":\"${C}read_page\",\"tool_input\":{\"tabId\":1},\"tool_response\":\"listbox \\\"Message list\\\" [ref_279]\\n option \\\"Unread Course Office Mid-term feedback form\\\" [ref_300]\\n option \\\"IT Maintenance\\\" [ref_398]\"}"
check "still unread after opening → no tripwire" [ ! -e "$GD/readstate_unsafe" ]
check "after re-reading, the next click is allowed" allowed "{\"tool_name\":\"${C}computer\",\"tool_input\":{\"tabId\":1,\"action\":\"left_click\",\"ref\":\"ref_398\"}}"
# Tripwire: an opened unread message that turns read stops all further clicks.
gpost "{\"tool_name\":\"${C}read_page\",\"tool_input\":{\"tabId\":1},\"tool_response\":\"listbox \\\"Message list\\\" [ref_279]\\n option \\\"Course Office Mid-term feedback form\\\" [ref_300]\\n option \\\"IT Maintenance\\\" [ref_398]\"}"
check "a clicked message that lost its Unread mark trips the wire" [ -e "$GD/readstate_unsafe" ]
check "…and every later click is blocked" blocked "{\"tool_name\":\"${C}computer\",\"tool_input\":{\"tabId\":1,\"action\":\"left_click\",\"ref\":\"ref_398\"}}"
check "navigate clears the tab's clickable rows" bash -c "printf '%s' '{\"tool_name\":\"${C}navigate\",\"tool_input\":{\"tabId\":1,\"url\":\"https://outlook.office.com/mail/inbox\"}}' | '$REPO_DIR/lib/hooks/guard.sh' pre '$GD' && [ ! -s '$GD/clickable.tsv' ]"
check "select_browser: this Mac → allowed" allowed "{\"tool_name\":\"${C}select_browser\",\"tool_input\":{\"deviceId\":\"dev1\"}}"
check "select_browser: another computer → blocked" blocked "{\"tool_name\":\"${C}select_browser\",\"tool_input\":{\"deviceId\":\"macbook\"}}"
check "Notion create in Exams → allowed" allowed "{\"tool_name\":\"${N}notion-create-pages\",\"tool_input\":{\"parent\":{\"data_source_id\":\"collection://aaaaaaaa-bbbb-4ccc-8ddd-000000000002\"},\"pages\":[{\"properties\":{\"Name\":\"x\"}}]}}"
check "Notion create under another page → blocked" blocked "{\"tool_name\":\"${N}notion-create-pages\",\"tool_input\":{\"parent\":{\"page_id\":\"ccccccccdddd4eee8fff000000000004\"},\"pages\":[]}}"
check "Notion create as a draft page → blocked" blocked "{\"tool_name\":\"${N}notion-create-pages\",\"tool_input\":{\"creation_mode\":\"draft\",\"pages\":[]}}"
check "Notion update of a row the user made → blocked" blocked "{\"tool_name\":\"${N}notion-update-page\",\"tool_input\":{\"page_id\":\"cccccccc-dddd-4eee-8fff-000000000003\",\"command\":\"update_properties\",\"properties\":{}}}"
gpost "{\"tool_name\":\"${N}notion-create-pages\",\"tool_input\":{},\"tool_response\":\"{\\\"pages\\\":[{\\\"id\\\":\\\"11112222-3333-4444-5555-666677778888\\\"}]}\"}"
check "created page ids are recorded" grep -qx 11112222333344445555666677778888 "$GD/created_pages.txt"
check "Notion update_properties on a bot row (by URL) → allowed" allowed "{\"tool_name\":\"${N}notion-update-page\",\"tool_input\":{\"page_id\":\"https://www.notion.so/Foo-11112222333344445555666677778888\",\"command\":\"update_properties\",\"properties\":{\"Done\":\"__YES__\"}}}"
check "Notion replace_content on a bot row → blocked" blocked "{\"tool_name\":\"${N}notion-update-page\",\"tool_input\":{\"page_id\":\"11112222333344445555666677778888\",\"command\":\"replace_content\",\"new_str\":\"\"}}"
check "Notion delete → blocked" blocked "{\"tool_name\":\"${N}notion-delete-pages\",\"tool_input\":{}}"
check "Gmail send → blocked" blocked '{"tool_name":"mcp__claude_ai_Gmail__send_message","tool_input":{}}'
check "WebFetch → blocked" blocked '{"tool_name":"WebFetch","tool_input":{"url":"https://example.com"}}'
check "Bash → blocked" blocked '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
check "Write inside the run dir → allowed" allowed "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$GR/tasks.tsv\"}}"
check "Write to the guard's own state → blocked" blocked "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$GD/clickable.tsv\"}}"
check "Write with ../ escape → blocked" blocked "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$GR/../run.guard/guard.conf\"}}"
sed -i '' 's/^DRY=0/DRY=1/' "$GD/guard.conf"
check "dry run: Notion create → blocked" blocked "{\"tool_name\":\"${N}notion-create-pages\",\"tool_input\":{\"parent\":{\"data_source_id\":\"aaaaaaaabbbb4ccc8ddd000000000002\"},\"pages\":[]}}"
check "every block is logged" bash -c "[ \$(wc -l <'$GD/blocked.log') -ge 20 ]"
# Tripwire when Outlook re-renders the list (new refs) or the page is reloaded.
GR2="$TMP/g2/run"; GD2="$GR2.guard"; mkdir -p "$GR2" "$GD2"; sed "s#$GR#$GR2#; s#^DRY=1#DRY=0#" "$GD/guard.conf" >"$GD2/guard.conf"
g2pre()  { printf '%s' "$1" | "$REPO_DIR/lib/hooks/guard.sh" pre "$GD2" >/dev/null 2>&1; }
g2post() { printf '%s' "$1" | "$REPO_DIR/lib/hooks/guard.sh" post "$GD2" >/dev/null 2>&1; }
g2post "{\"tool_name\":\"${C}read_page\",\"tool_input\":{\"tabId\":7},\"tool_response\":\"listbox \\\"Message list\\\" [ref_1]\\n option \\\"Unread Prof X Tomorrow's session\\\" [ref_168]\"}"
g2pre "{\"tool_name\":\"${C}computer\",\"tool_input\":{\"tabId\":7,\"action\":\"left_click\",\"ref\":\"ref_168\"}}"
g2post "{\"tool_name\":\"${C}read_page\",\"tool_input\":{\"tabId\":7},\"tool_response\":\"listbox \\\"Message list\\\" [ref_1]\\n option \\\"Unread Prof X Tomorrow's session\\\" [ref_401]\"}"
check "re-rendered row (new ref), still unread → no tripwire" [ ! -e "$GD2/readstate_unsafe" ]
g2pre "{\"tool_name\":\"${C}navigate\",\"tool_input\":{\"tabId\":7,\"url\":\"https://outlook.office.com/mail/inbox\"}}"
g2post "{\"tool_name\":\"${C}read_page\",\"tool_input\":{\"tabId\":7},\"tool_response\":\"listbox \\\"Message list\\\" [ref_1]\\n option \\\"Prof X Tomorrow's session\\\" [ref_502]\"}"
check "opened message shows as read under a new ref after a reload → tripwire" [ -e "$GD2/readstate_unsafe" ]

# ---------------------------------------------------------------- nag rules
section "To-do nag rules (tasks_compose), Thu 26 Nov 2026"
SAVE_STATE_DIR="$STATE_DIR"; STATE_DIR="$TMP/tstate"; mkdir -p "$STATE_DIR"
TASKS_NAGS="$STATE_DIR/task_nags.tsv"; TASKS_NEW="$STATE_DIR/tasks_new.tsv"; : >"$TASKS_NAGS"; : >"$TASKS_NEW"
TASKS_ENABLED=1; NOTION_TASKS_DS=x; NOTION_EXAMS_DS=y
SN="$TMP/snap.tsv"
{
  printf 'task\taaaa\tApply: Sunday outing\t2026-11-26T17:00\tOuting\tbot\thttps://forms.office.com/r/x\t\n'
  printf 'task\tbbbb\tSubmit: Feedback\t2026-11-27\tTo-do\tbot\t\t\n'
  printf 'task\tcccc\tPrepare: Prob Mid-sem\t2026-12-05\tExam prep\tbot\t\t\n'
  printf 'task\tdddd\tPay hostel fee\t2026-11-25\t\tme\t\t\n'
  printf 'task\teeee\tFar away thing\t2026-12-20\t\tme\t\t\n'
  printf 'task\tffff\tLong overdue\t2026-11-20\t\tme\t\t\n'
  printf 'exam\txxxx\tProb Mid-sem\t2026-11-29T10:00\tMid-sem\tbot\t\tR-101\n'
  printf 'exam\tyyyy\tEcon Quiz 2\t2026-12-03\tQuiz\tbot\t\t\n'
  printf 'exam\tzzzz\tStats Quiz\t2026-11-26T14:30\tQuiz\tbot\t\t\n'
} >"$SN"
M="$TMP/msg.txt"; R="$TMP/rec.txt"
tasks_compose morning 2026-11-26 0600 "$SN" "$M" "$R"
check "morning: heading" bash -c "head -1 '$M' | grep -q '📝 TO-DO & EXAMS'"
check "morning: overdue task first, marked ❗ with 'still open'" bash -c "grep -A1 '^1\. ❗ Pay hostel fee' '$M' | grep -q 'was due yesterday'"
check "morning: due today shows ⏰ and the time" bash -c "grep -A1 '⏰ Apply: Sunday outing' '$M' | grep -q 'due today, 5 PM'"
check "morning: link printed on its own line" grep -qx 'https://forms.office.com/r/x' "$M"
check "morning: due tomorrow is ⏰" grep -q '⏰ Submit: Feedback' "$M"
check "morning: in 9 days listed without ⏰" bash -c "grep -A1 'Prepare: Prob Mid-sem' '$M' | grep -q 'in 9 days'"
check "morning: >14 days out and >3 days overdue left out" bash -c "! grep -q 'Far away\|Long overdue' '$M'"
check "morning: exams within 2 weeks, today's marked ⏰" bash -c "grep -q '• Stats Quiz: ⏰ today, 2:30 PM' '$M' && grep -q '• Prob Mid-sem: Sun 29 Nov, 10 AM (in 3 days) · R-101' '$M' && grep -q 'Econ Quiz 2' '$M'"
check "morning: never records nags or buzzes on its own" bash -c "[ ! -s '$R' ] && [ ! -f '$M.sound' ]"

TASKS_OUTING_WEEK=no
tasks_compose evening 2026-11-26 1900 "$SN" "$M" "$R"
check "evening: heading with the date" bash -c "head -1 '$M' | grep -q '🌙 TO-DO CHECK · Thu 26 Nov'"
check "evening: due tomorrow under DUE SOON" bash -c "sed -n '/DUE SOON/,/MISSED/p' '$M' | grep -q 'Submit: Feedback'"
check "evening: today 5 PM already passed → MISSED, not due soon" bash -c "sed -n '/MISSED/,/EXAMS/p' '$M' | grep -q 'Apply: Sunday outing' && ! sed -n '/DUE SOON/,/MISSED/p' '$M' | grep -q 'Sunday outing'"
check "evening: yesterday's open task → MISSED" bash -c "sed -n '/MISSED/,/EXAMS/p' '$M' | grep -q 'Pay hostel fee'"
check "evening: exams 3 and 7 days out reminded, 9-day task not" bash -c "grep -q '• Prob Mid-sem' '$M' && grep -q '• Econ Quiz 2' '$M' && ! grep -q 'Prepare: Prob' '$M'"
check "evening: Thursday with no outing email → heads-up" grep -q 'No Sunday-outing email seen this week' "$M"
check "evening: nothing due today still open → silent" [ ! -f "$M.sound" ]
check "evening: nag keys to remember" bash -c "grep -qx 'missed:aaaa' '$R' && grep -qx 'missed:dddd' '$R' && grep -qx 'exam3:xxxx' '$R' && grep -qx 'exam7:yyyy' '$R' && grep -qx 'outing:2026-11-23' '$R'"
tasks_record_nags 2026-11-26 "$R"
tasks_compose evening 2026-11-26 1930 "$SN" "$M" "$R"
check "second evening run: missed/exam/heads-up not repeated" bash -c "! grep -q 'MISSED\|EXAMS\|outing email' '$M'"
check "…but what's still due soon is (until it's ticked)" grep -q 'Submit: Feedback' "$M"

printf 'task\tgggg\tSubmit: Essay\t2026-11-26T23:59\tAssignment\tbot\t\t\n' >"$TMP/snap2.tsv"
tasks_compose evening 2026-11-26 1900 "$TMP/snap2.tsv" "$M" "$R"
check "evening: due later today → buzzes" [ -f "$M.sound" ]
printf 'task\thhhh\tSubmit: Lab\t2026-11-27T09:00\tAssignment\tbot\t\t\n' >"$TMP/snap3.tsv"
tasks_compose evening 2026-11-26 1900 "$TMP/snap3.tsv" "$M" "$R"
check "evening: due tomorrow morning → buzzes" [ -f "$M.sound" ]

printf 'task\tcccc\tPrepare: Prob Mid-sem\t2026-12-05\tExam prep\tbot\t\t\n' >"$TMP/snap4.tsv"
TASKS_OUTING_WEEK=yes
tasks_compose evening 2026-11-23 1900 "$TMP/snap4.tsv" "$M" "$R"
check "evening: nothing near → no message at all" [ ! -s "$M" ]
TASKS_OUTING_WEEK=no
tasks_compose evening 2026-11-23 1900 "$TMP/snap4.tsv" "$M" "$R"
check "evening: no outing heads-up on a Monday" [ ! -s "$M" ]
printf 'kkkk\t2026-11-23\ttask\tSubmit: New thing\t2026-12-01\n' >"$TASKS_NEW"
tasks_compose evening 2026-11-23 1900 "$TMP/snap4.tsv" "$M" "$R"
check "evening: rows added from email today are announced once" bash -c "grep -q 'ADDED FROM EMAIL TODAY' '$M' && grep -q '• Submit: New thing (due Tue 1 Dec)' '$M' && grep -qx 'new:kkkk' '$R'"
printf 'task\tkkkk\tSubmit: New thing\t2026-12-01\tTo-do\tbot\t\t\n' >"$TMP/snap5.tsv"
tasks_compose morning 2026-11-24 0600 "$TMP/snap5.tsv" "$M" "$R"
check "morning after: new row carries 🆕" grep -q 'Submit: New thing 🆕' "$M"
tasks_compose morning 2026-11-26 0600 "$TMP/snap5.tsv" "$M" "$R"
check "two days later: no 🆕" bash -c "! grep -q '🆕' '$M'"

printf 'task\tAAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\tOk row\t2026-11-30T17:05:00+05:30\tTo-do\tBot\thttps://x.y/z\t\nexam\tnot-an-id\tBad\t2026-11-30\t\t\t\t\nnote\t1\t2\t3\n' >"$TMP/raw.tsv"
tasks_parse "$TMP/raw.tsv" "$TMP/parsed.tsv"
check "tasks_parse: normalises id, time and added_by; drops bad rows" bash -c "[ \"\$(cat '$TMP/parsed.tsv')\" = \"\$(printf 'task\taaaaaaaabbbbccccddddeeeeeeeeeeee\tOk row\t2026-11-30T17:05\tTo-do\tbot\thttps://x.y/z\t')\" ]"
STATE_DIR="$SAVE_STATE_DIR"; TASKS_NAGS="$STATE_DIR/task_nags.tsv"; TASKS_NEW="$STATE_DIR/tasks_new.tsv"; TASKS_ENABLED=0; NOTION_TASKS_DS=""; NOTION_EXAMS_DS=""

# ---------------------------------------------------------------- pipelines
section "To-do pipelines (fake claude + fake curl)"
PT="$TMP/tasks"; mkdir -p "$PT"
cp "$TMP/pipe.env" "$TMP/tasks.env"
sed -i '' 's/^MAX_SECONDS=.*/MAX_SECONDS=60/' "$TMP/tasks.env"
printf 'TASKS_ENABLED=1\nNOTION_TASKS_DS="collection://aaaaaaaa-bbbb-4ccc-8ddd-000000000001"\nNOTION_EXAMS_DS="aaaaaaaa-bbbb-4ccc-8ddd-000000000002"\nTASKS_MAX_SECONDS=60\n' >>"$TMP/tasks.env"
tp() { BRIEF_HOME="$PT" BRIEF_CONFIG="$TMP/tasks.env" CURL_BIN="$TESTS_DIR/fake-curl.sh" TG_NO_SLEEP=1 BRIEF_SKIP_CHROME=1 BRIEF_SKIP_NETWORK_WAIT=1 \
  "$REPO_DIR/brief" "$@" >"$TMP/pipe.out" 2>&1; }

reset_fake "200${T}{\"ok\":true}"
BRIEF_NOW_HM=1900 tp tasks --slot evening --dry-run; rc=$?
check "tasks --dry-run exits 0 and sends nothing" bash -c "[ $rc = 0 ] && [ ! -s '$FAKE_CALLS' ]"
check "…prints the evening message" grep -q 'TO-DO CHECK' "$TMP/pipe.out"
check "…and changes no state" bash -c "[ ! -f '$PT/state/tasks_snapshot.tsv' ] && [ ! -s '$PT/state/notion_bot_pages.txt' ] && [ ! -f '$PT/state/tasks_last_evening' ]"
trd="$(ls -d "$PT"/runs/*-tasks-evening-dry | tail -1)"
check "the prompt says DRY RUN and the guard is in dry mode" bash -c "grep -q '# DRY RUN' '$trd/prompt.md' && grep -qx 'DRY=1' '$trd.guard/guard.conf'"
check "claude ran with the guard settings, dontAsk, no --strict-mcp-config" bash -c "grep -qx -- --settings '$trd/fake-args.txt' && grep -qx '$trd.guard/settings.json' '$trd/fake-args.txt' && grep -qx dontAsk '$trd/fake-args.txt' && ! grep -qx -- --strict-mcp-config '$trd/fake-args.txt'"
check "no web tools, Gmail and other connectors denied" bash -c "a=\$(grep -A1 -x -- --allowedTools '$trd/fake-args.txt' | tail -1); d=\$(grep -A1 -x -- --disallowedTools '$trd/fake-args.txt' | tail -1); ! printf '%s' \"\$a\" | grep -q 'WebFetch\|WebSearch\|Gmail\|Bash' && printf '%s' \"\$d\" | grep -q 'mcp__claude_ai_Gmail' && printf '%s' \"\$d\" | grep -q 'WebFetch' && printf '%s' \"\$d\" | grep -q 'notion-delete-pages'"
check "guard hooks point at lib/hooks/guard.sh pre/post" bash -c "grep -q \"lib/hooks/guard.sh' pre\" '$trd.guard/settings.json' && grep -q \"lib/hooks/guard.sh' post\" '$trd.guard/settings.json'"
check "prompt has the data sources and no unfilled placeholders" bash -c "grep -q 'collection://aaaaaaaa-bbbb-4ccc-8ddd-000000000001' '$trd/prompt.md' && ! grep -q '{{' '$trd/prompt.md'"
check "no views configured → the prompt falls back to rows mode" grep -q 'in "rows" mode with a Date filter' "$trd/prompt.md"
NOTION_TASKS_VIEW="https://www.notion.so/aaa?v=bbb"; NOTION_EXAMS_VIEW="https://www.notion.so/ccc?v=ddd"
check "views configured → view mode with both view URLs" bash -c "n=\"\$1\"; printf '%s' \"\$n\" | grep -q 'in \"view\" mode' && printf '%s' \"\$n\" | grep -q 'view_url https://www.notion.so/aaa?v=bbb' && printf '%s' \"\$n\" | grep -q 'view_url https://www.notion.so/ccc?v=ddd'" _ "$(tasks_notion_read_note)"
NOTION_TASKS_VIEW=""; NOTION_EXAMS_VIEW=""

reset_fake "200${T}{\"ok\":true}"
BRIEF_NOW_HM=1900 tp tasks --slot evening; rc=$?
check "tasks (evening) delivers" bash -c "[ $rc = 0 ] && [ \$(grep -c '^CALL' '$FAKE_CALLS') = 1 ]"
check "…saves the snapshot (bad rows dropped, ids normalised)" bash -c "[ \$(wc -l <'$PT/state/tasks_snapshot.tsv') = 4 ] && grep -q '33333333222233334444555555555555' '$PT/state/tasks_snapshot.tsv'"
check "…remembers the rows the bot created" grep -qx 2222222222223333444455555555555a "$PT/state/notion_bot_pages.txt"
check "…remembers processed mail, but not skipped rows" bash -c "[ \$(wc -l <'$PT/state/mail_seen.tsv') = 2 ] && ! grep -q 'Consent form' '$PT/state/mail_seen.tsv'"
check "…marks the evening check done" [ "$(cat "$PT/state/tasks_last_evening")" = "$TODAY" ]
lastmsg() { printf '%s/message.txt' "$(ls -d "$PT"/runs/*-tasks-evening | tail -1)"; }
check "…message mentions the task added today" grep -q 'ADDED FROM EMAIL TODAY' "$(lastmsg)"
reset_fake "200${T}{\"ok\":true}"
BRIEF_NOW_HM=1900 tp tasks --slot evening
trd="$(ls -d "$PT"/runs/*-tasks-evening | tail -1)"
check "second run passes processed mail to the prompt" bash -c "grep -q 'Mid-term feedback form' '$trd/processed.tsv'"

check "inbox read far enough back → no shortfall note" bash -c "! grep -q 'Only checked mail back' \"\$1\"" _ "$(lastmsg)"
reset_fake "200${T}{\"ok\":true}"
FAKE_TASKS_OLDEST="$TODAY" BRIEF_NOW_HM=1900 tp tasks --slot evening
check "inbox not paged back far enough → 📭 note" grep -q 'Only checked mail back to' "$(lastmsg)"
reset_fake "200${T}{\"ok\":true}"
FAKE_TASKS_MODE=unsafe BRIEF_NOW_HM=1900 tp tasks --slot evening
check "read-state tripwire → warning in the message" grep -q 'mark items as read' "$(lastmsg)"

reset_fake "200${T}{\"ok\":true}"
FAKE_TASKS_MODE=nonotion BRIEF_NOW_HM=1900 tp tasks --slot evening; rc=$?
check "Notion unreachable → exit 1 and a ⚠️ alert" bash -c "[ $rc = 1 ] && [ \$(grep -c '^CALL' '$FAKE_CALLS') = 1 ] && grep -q 'To-do check failed' '$TMP/pipe.out'"

# Scheduled: the evening check rides on the brief's LaunchAgent.
rm -f "$PT/state/tasks_last_evening" "$PT/state/tasks_attempts"
printf '%s\n' "$TODAY" >"$PT/state/last_success"
reset_fake "200${T}{\"ok\":true}"
BRIEF_NOW_HM=1500 tp run --scheduled
check "15:00 after the brief → nothing (evening not due)" [ ! -s "$FAKE_CALLS" ]
BRIEF_NOW_HM=1930 tp run --scheduled; rc=$?
check "19:30 after the brief → evening to-do check runs" bash -c "[ $rc = 0 ] && [ -s '$FAKE_CALLS' ] && [ \"\$(cat '$PT/state/tasks_last_evening')\" = '$TODAY' ]"
reset_fake "200${T}{\"ok\":true}"
BRIEF_NOW_HM=2000 tp run --scheduled
check "20:00 → already done today, silent" [ ! -s "$FAKE_CALLS" ]

# The brief itself: to-dos run first, the 📝 section is part of the brief.
rm -f "$PT/state/last_success" "$PT/state/attempts"
reset_fake "200${T}{\"ok\":true}"
BRIEF_NOW_HM=0600 FAKE_CLAUDE_MODE=ok tp run --dry-run
check "brief dry run includes the 📝 section from this run's snapshot" bash -c "grep -q '📝 TO-DO & EXAMS' '$TMP/pipe.out' && grep -q '📝 To-do: 3 open, 1 exam(s)' '$TMP/pipe.out'"
reset_fake "200${T}{\"ok\":true}"
BRIEF_NOW_HM=0600 FAKE_CLAUDE_MODE=ok FAKE_TASKS_MODE=error tp run; rc=$?
check "to-do check fails → the brief is still delivered" bash -c "[ $rc = 0 ] && [ \"\$(cat '$PT/state/last_success')\" = '$TODAY' ]"
check "…with a footer note and the last known list" bash -c "a=\$(ls -d '$PT'/archive/* | tail -1); grep -q 'To-do check: claude exited' \$a/90-footer.txt && grep -q 'check failed' \$a/55-todo.txt"
reset_fake "200${T}{\"ok\":true}"
FAKE_CLAUDE_MODE=ok tp run --dry-run --only tech
check "--only runs skip the to-do check" bash -c "! grep -q 'Outlook' '$TMP/pipe.out'"
