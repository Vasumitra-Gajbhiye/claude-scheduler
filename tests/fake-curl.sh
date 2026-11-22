#!/bin/bash
# Fake curl for tests. Reads the -K config from stdin (to capture the URL),
# records each call to $FAKE_CALLS, and replies with the next line of $FAKE_RESPONSES
# ("<http_code><TAB><json body>"). Never touches the network.
out=""; args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -K) shift 2 ;;   # config comes from stdin
    -w) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
cfg="$(cat)"
url="$(printf '%s' "$cfg" | sed -n 's/^url = "\(.*\)"$/\1/p')"
n=$(( $(cat "$FAKE_COUNTER" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$FAKE_COUNTER"
{ printf 'CALL %s %s\n' "$n" "${url##*/}"; for a in "${args[@]}"; do
    case "$a" in text@*) printf '  text-bytes=%s\n' "$(wc -c <"${a#text@}" | tr -d ' ')";; *) printf '  %s\n' "$a";; esac
  done; } >>"$FAKE_CALLS"
line="$(sed -n "${n}p" "$FAKE_RESPONSES")"
[ -z "$line" ] && line="$(tail -1 "$FAKE_RESPONSES")"
code="${line%%	*}"; body="${line#*	}"
printf '%s' "$body" >"$out"
printf '%s' "$code"
