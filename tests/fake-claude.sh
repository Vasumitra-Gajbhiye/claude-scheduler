#!/bin/bash
# Fake `claude -p` for pipeline tests. Reads the rendered prompt on stdin, writes section
# files + items.tsv + notes.txt for the sections listed in it, prints a result JSON.
# FAKE_CLAUDE_MODE: ok (default) | usage | error | sleep | empty
prompt="$(cat)"
printf '%s\n' "$@" >fake-args.txt
env | grep -E '^(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN)=' >fake-env.txt
printf '%s' "$prompt" >fake-prompt.txt
mode="${FAKE_CLAUDE_MODE:-ok}"
# The to-do (tasks) run: FAKE_TASKS_MODE ok (default) | unsafe | nonotion | error
if printf '%s' "$prompt" | grep -q 'You are the to-do step'; then
  tm="${FAKE_TASKS_MODE:-ok}"
  [ "$tm" = error ] && { echo '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":2,"result":"tasks broke","permission_denials":[]}'; exit 1; }
  t0="$(TZ=Asia/Kolkata date +%F)"; t1="$(TZ=Asia/Kolkata date -v+1d +%F)"; t9="$(TZ=Asia/Kolkata date -v+9d +%F)"; t3="$(TZ=Asia/Kolkata date -v+3d +%F)"
  {
    printf 'task\t11111111222233334444555555555555\tApply: Sunday outing\t%sT23:30\tOuting\tbot\thttps://forms.office.com/r/abc\t\n' "$t0"
    printf 'task\t2222222222223333444455555555555a\tSubmit: Mid-term feedback\t%s\tTo-do\tbot\t\t\n' "$t1"
    printf 'task\t33333333-2222-3333-4444-555555555555\tRead chapter 4\t%s\t\tme\t\t\n' "$t9"
    printf 'exam\t4444444422223333444455555555555b\tProb Mid-sem\t%sT10:00\tMid-sem\tbot\t\tR-101 · Ch 1-5\n' "$t3"
    printf 'bogus\tnope\n'
  } >tasks.tsv
  printf 'created\ttask\t2222222222223333444455555555555a\tSubmit: Mid-term feedback\t%s\tk1\n' "$t1" >actions.tsv
  printf '%s|Course Office|Mid-term feedback form\ttask\tyes\tfeedback form\tCourse Office\n%s|IT|Maintenance\tignore\tno\tIT notice\tITHelpdesk\n%s|Course Office|Consent form\tskipped\tno\tpane did not load\tCourse Office\n' "$t0" "$t0" "$t0" >mail.tsv
  rs=ok; [ "$tm" = unsafe ] && rs=unsafe
  nt=ok; [ "$tm" = nonotion ] && nt=fail
  printf 'outlook=ok\nreadstate=%s\nnotion=%s\nouting_week=yes\noldest_row=%s\n' "$rs" "$nt" "${FAKE_TASKS_OLDEST:-$(TZ=Asia/Kolkata date -v-3d +%F)}" >status.txt
  : >notes.txt
  echo '{"type":"result","subtype":"success","is_error":false,"num_turns":9,"duration_ms":30000,"total_cost_usd":0.2,"result":"1 created, 3 open, 1 exam","permission_denials":[]}'
  exit 0
fi
case "$mode" in
  sleep) sleep 300; exit 0 ;;
  usage) echo '{"type":"result","subtype":"success","is_error":true,"num_turns":1,"duration_ms":900,"total_cost_usd":0.01,"result":"Claude usage limit reached. Your limit will reset at 11am.","permission_denials":[]}'; exit 1 ;;
  error) echo '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":3,"duration_ms":1000,"result":"something broke","permission_denials":[]}'; exit 1 ;;
  empty) echo '{"type":"result","subtype":"success","is_error":false,"num_turns":2,"duration_ms":1000,"total_cost_usd":0.02,"result":"done","permission_denials":[]}'; exit 0 ;;
esac
today="$(TZ=Asia/Kolkata date +%F)"; plus2="$(TZ=Asia/Kolkata date -v+2d +%F)"
# next Mon-Thu and next Saturday (1-7 days ahead)
weekday="$(for i in 1 2 3 4 5 6 7; do x="$(TZ=Asia/Kolkata date -v+${i}d +%u)"; if [ "$x" -le 4 ]; then TZ=Asia/Kolkata date -v+${i}d +%F; break; fi; done)"
saturday="$(for i in 1 2 3 4 5 6 7; do x="$(TZ=Asia/Kolkata date -v+${i}d +%u)"; if [ "$x" = 6 ]; then TZ=Asia/Kolkata date -v+${i}d +%F; break; fi; done)"
: >items.tsv; : >notes.txt
printf "thehindu.com\tok\t\ndevpost.com\tfail\t403\nluma.com\tok\t\n" >sources.tsv
printf '%s\n' "$prompt" | sed -n 's/^- \([a-z]*\) → \(.*\)$/\1 \2/p' | while read -r sec path; do
  case "$sec" in
    day)   printf '📆 TODAY\n\n1. Test Day\nWhy it matters.\n' >"$path" ;;
    world) printf '🌍 WORLD\n\n1. Summit ends\nWhy.\nhttps://www.bbc.com/news/w1\n' >"$path"
           printf 'world\t\tSummit ends\thttps://www.bbc.com/news/w1\n' >>items.tsv ;;
    india) printf '🇮🇳 INDIA\n\n1. **Parliament** passes bill\nWhy it matters.\nhttps://www.thehindu.com/news/national/a1\n\n2. RBI holds rates\nWhy.\nhttps://www.thehindu.com/business/a2\n' >"$path"
           printf 'news\t\tParliament passes bill\thttps://www.thehindu.com/news/national/a1\nnews\t\tRBI holds rates\thttps://www.thehindu.com/business/a2\n' >>items.tsv ;;
    tech)  printf '💻 TECH & AI\n\n1. New model launch\nWhy.\nhttps://example.com/tech1\n' >"$path"
           printf 'tech\t\tNew model launch\thttps://example.com/tech1\n' >>items.tsv ;;
    events) printf "📅 EVENTS & COMPETITIONS\n\n1. Fake Hackathon (Org)\nOnline · Deadline soon · Prize ₹1L\nFit.\nhttps://unstop.com/c1\n\n2. Weekday Meetup\nMon · 6 PM · Indiranagar (offline)\nWhy.\nhttps://luma.com/weekday\n\n3. Weekend Builders Day\nSat · 10 AM · Koramangala (offline)\nWhy.\nhttps://luma.com/weekend\n" >"$path"
           printf "hackathon\t%s\tFake Hackathon\thttps://unstop.com/c1\t\tonline\tOnline · Prize ₹1L\n" "$plus2" >>items.tsv
           printf "event\t\tWeekday Meetup\thttps://luma.com/weekday\t%s\tbangalore\tMon · Indiranagar\n" "$weekday" >>items.tsv
           printf "event\t\tWeekend Builders Day\thttps://luma.com/weekend\t%s\tBengaluru (offline)\tSat · Koramangala\n" "$saturday" >>items.tsv ;;
    internships) printf '💼 INTERNSHIPS\n\n1. SWE Intern (BigCo)\nDeadline: not stated · Remote · ✅ open to 1st years\nFit.\nhttps://example.com/i1\n' >"$path"
           printf 'internship\t\tSWE Intern\thttps://example.com/i1\nbogus\t\tbad row\thttps://x\n' >>items.tsv ;;
  esac
done
printf "devpost.com via WebFetch: 403\nluma.com via Chrome: only today visible\n" >>notes.txt
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":12,"duration_ms":61000,"total_cost_usd":0.42,"usage":{"input_tokens":10,"output_tokens":20},"result":"wrote sections","permission_denials":[]}'
