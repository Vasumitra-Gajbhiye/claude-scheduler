#!/bin/bash
# Fake `claude -p` for pipeline tests. Reads the rendered prompt on stdin, writes section
# files + items.tsv + notes.txt for the sections listed in it, prints a result JSON.
# FAKE_CLAUDE_MODE: ok (default) | usage | error | sleep | empty
prompt="$(cat)"
printf '%s\n' "$@" >fake-args.txt
env | grep -E '^(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN)=' >fake-env.txt
printf '%s' "$prompt" >fake-prompt.txt
mode="${FAKE_CLAUDE_MODE:-ok}"
case "$mode" in
  sleep) sleep 300; exit 0 ;;
  usage) echo '{"type":"result","subtype":"success","is_error":true,"num_turns":1,"duration_ms":900,"total_cost_usd":0.01,"result":"Claude usage limit reached. Your limit will reset at 11am.","permission_denials":[]}'; exit 1 ;;
  error) echo '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":3,"duration_ms":1000,"result":"something broke","permission_denials":[]}'; exit 1 ;;
  empty) echo '{"type":"result","subtype":"success","is_error":false,"num_turns":2,"duration_ms":1000,"total_cost_usd":0.02,"result":"done","permission_denials":[]}'; exit 0 ;;
esac
today="$(TZ=Asia/Kolkata date +%F)"; plus2="$(TZ=Asia/Kolkata date -v+2d +%F)"
: >items.tsv; : >notes.txt
printf '%s\n' "$prompt" | sed -n 's/^- \([a-z]*\) → \(.*\)$/\1 \2/p' | while read -r sec path; do
  case "$sec" in
    india) printf '🇮🇳 INDIA\n\n1. **Parliament** passes bill\nWhy it matters.\nhttps://www.thehindu.com/news/national/a1\n\n2. RBI holds rates\nWhy.\nhttps://www.thehindu.com/business/a2\n' >"$path"
           printf 'news\t\tParliament passes bill\thttps://www.thehindu.com/news/national/a1\nnews\t\tRBI holds rates\thttps://www.thehindu.com/business/a2\n' >>items.tsv ;;
    tech)  printf '💻 TECH & AI\n\n1. New model launch\nWhy.\nhttps://example.com/tech1\n' >"$path"
           printf 'tech\t\tNew model launch\thttps://example.com/tech1\n' >>items.tsv ;;
    events) printf '📅 BANGALORE EVENTS\n\nNothing notable today.\n' >"$path" ;;
    competitions) printf '🏆 COMPETITIONS\n\n1. Fake Hackathon (Org)\nDeadline: soon · Prize: ₹1L · Eligibility: UG\nFit.\nhttps://unstop.com/c1\n' >"$path"
           printf 'competition\t%s\tFake Hackathon\thttps://unstop.com/c1\n' "$plus2" >>items.tsv ;;
    internships) printf '💼 INTERNSHIPS\n\n1. SWE Intern (BigCo)\nDeadline: not stated · Remote · ✅ open to 1st years\nFit.\nhttps://example.com/i1\n' >"$path"
           printf 'internship\t\tSWE Intern\thttps://example.com/i1\nbogus\t\tbad row\thttps://x\n' >>items.tsv ;;
  esac
done
echo "luma.com via Chrome: fake note" >>notes.txt
echo '{"type":"result","subtype":"success","is_error":false,"num_turns":12,"duration_ms":61000,"total_cost_usd":0.42,"usage":{"input_tokens":10,"output_tokens":20},"result":"wrote sections","permission_denials":[]}'
