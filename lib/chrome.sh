# shellcheck shell=bash
# Which Chrome is THIS Mac's? Every Chrome signed in to the same claude.ai account is reachable
# through Claude in Chrome, and the extension's "isLocal" flag is not reliable when several
# Macs are connected. So `./brief chrome-check` identifies this Mac's browser for certain:
#   1. a tiny claude turn opens a tagged probe tab in EVERY connected browser
#      (https://example.com/?morningbrief-probe=<deviceId>);
#   2. AppleScript asks the local Google Chrome which tagged tab it has (AppleScript only ever
#      reaches this machine), which gives this Mac's deviceId;
#   3. the deviceId is saved to state/chrome_device (per machine, gitignored), probe tabs are closed.
# Runs then call select_browser with exactly that deviceId, or don't use Chrome at all.

CHROME_DEVICE_FILE="$STATE_DIR/chrome_device"
PROBE_KEY="morningbrief-probe"

chrome_device_id()   { cut -f1 "$CHROME_DEVICE_FILE" 2>/dev/null | head -1; }
chrome_device_name() { cut -f2 "$CHROME_DEVICE_FILE" 2>/dev/null | head -1; }

# URLs of all tabs in the local Google Chrome, one per line. Fails if AppleScript access is denied.
local_chrome_urls() {
  osascript -e 'set out to ""
tell application "Google Chrome"
  repeat with w in windows
    repeat with t in tabs of w
      set out to out & (URL of t) & linefeed
    end repeat
  end repeat
end tell
return out' 2>"$1"
}

close_local_probe_tabs() {
  osascript -e 'tell application "Google Chrome"
  repeat with w in windows
    close (every tab of w whose URL contains "'"$PROBE_KEY"'")
  end repeat
end tell' >/dev/null 2>&1 || true
}

# chrome_claude <dir> <prompt> <tools> [resume_session_id]: one small claude turn; prints the result text.
# Sessions are kept (no --no-session-persistence) so a follow-up call can --resume: each session has
# its own Chrome tab group, and only that session can see and close the tabs it opened.
chrome_claude() {
  local dir="$1" prompt="$2" tools="$3" resume="${4:-}" out
  local resume_args=""
  [ -n "$resume" ] && resume_args="--resume $resume"
  # shellcheck disable=SC2086
  out="$(cd "$dir" && printf '%s\n' "$prompt" |
    "$CLAUDE_BIN" -p $resume_args --model "$MODEL" --chrome --output-format json --permission-mode dontAsk --permission-prompts none \
      --strict-mcp-config --allowedTools "$tools" \
      --disallowedTools "mcp__claude-in-chrome__switch_browser" 2>>"$dir/stderr")"
  printf '%s' "$out" >>"$dir/results.jsonl"; printf '\n' >>"$dir/results.jsonl"
  printf '%s' "$out" >"$dir/last.json"
  claude_result_fields "$dir/last.json" | sed -n 's/^result=//p'
}

session_of() { perl -MJSON::PP -e 'local $/; my $d = eval { decode_json(<STDIN>) } or exit; print $d->{session_id} // ""' <"$1" 2>/dev/null; }

# Close the probe tabs that the probe session opened in other computers' browsers (resumes that session).
close_remote_probe_tabs() {
  local dir="$1" ids="$2" session="$3"
  [ -n "$(printf '%s' "$ids" | tr -d ' ')" ] && [ -n "$session" ] || return 0
  chrome_claude "$dir" "Now clean up. For each of these deviceIds: $ids
call mcp__claude-in-chrome__select_browser with it, then close (mcp__claude-in-chrome__tabs_close_mcp) the tab you opened there earlier in this session (the one at https://example.com/?$PROBE_KEY=...). Call no other tools. Reply with one line: DONE <number of tabs closed>." \
    "mcp__claude-in-chrome__select_browser,mcp__claude-in-chrome__tabs_context_mcp,mcp__claude-in-chrome__tabs_close_mcp" "$session"
}

chrome_save_device() {
  mkdir -p "$STATE_DIR"
  printf '%s\t%s\t%s\n' "$1" "${2:-}" "$(now_human)" >"$CHROME_DEVICE_FILE"
}

cmd_chrome_check() {
  local d res probed urls found n others name probe_session
  [ -n "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ] || die "claude not found"

  # Manual override: ./brief chrome-check --use <deviceId>
  if [ "${1:-}" = "--use" ]; then
    [ -n "${2:-}" ] || die "Usage: ./brief chrome-check --use <deviceId>"
    chrome_save_device "$2" "set manually"
    say "${C_GRN}✅ Saved: runs on this Mac will only use Chrome device $2.${C_OFF}"
    return 0
  fi

  chrome_running || { open -ga "Google Chrome" 2>/dev/null; sleep 8; }
  d="$RUNS_DIR/chrome-check-$(TZ=$BRIEF_TZ date '+%Y%m%d-%H%M%S')"; mkdir -p "$d"
  say "Finding this Mac's Chrome among the browsers connected to your Claude account…"
  say "${C_DIM}(opens a test tab at example.com in each connected browser, then closes them; uses a little of your plan)${C_OFF}"

  res="$(chrome_claude "$d" "Follow these steps exactly. Call no other tools.
1. Call mcp__claude-in-chrome__list_connected_browsers.
2. For EVERY browser in that list (ignore isLocal and inUse), in order:
   a. call mcp__claude-in-chrome__select_browser with its deviceId;
   b. call mcp__claude-in-chrome__tabs_context_mcp with createIfEmpty true;
   c. call mcp__claude-in-chrome__tabs_create_mcp to open a new tab;
   d. call mcp__claude-in-chrome__navigate to send that new tab to https://example.com/?$PROBE_KEY=<that deviceId>
   Do NOT close these tabs.
3. Reply with one line per browser, nothing else:
   PROBED <deviceId> <browser name>
   or FAILED <deviceId> <short error>
   If list_connected_browsers fails or is empty, reply: NONE <error text>" \
    "mcp__claude-in-chrome__list_connected_browsers,mcp__claude-in-chrome__select_browser,mcp__claude-in-chrome__tabs_context_mcp,mcp__claude-in-chrome__tabs_create_mcp,mcp__claude-in-chrome__navigate")"
  printf '%s\n' "$res" >"$d/probe.txt"
  probe_session="$(session_of "$d/last.json")"
  # The result text may arrive on one line; pull out every "PROBED <id> <name>" pair.
  printf '%s\n' "$res" | perl -ne 'while (/PROBED\s+([0-9a-fA-F-]{36})\s+(.*?)(?=\s+(?:PROBED|FAILED)\s|\s*$)/g) { print "$1\t$2\n" }' >"$d/probed.tsv"
  probed="$(cut -f1 "$d/probed.tsv")"

  if [ -z "$probed" ]; then
    case "$res" in
      *"not connected"*|NONE*)
        say "${C_RED}❌ No Chrome is connected to your Claude account.${C_OFF}"
        say "   → On THIS Mac: open Chrome, sign the Claude extension in to the same account as Claude Code"
        say "     (claude auth status), quit Chrome (⌘Q), reopen it, then run ./brief chrome-check again." ;;
      *) say "${C_RED}❌ Chrome check failed:${C_OFF} ${res:-no result (see $d)}" ;;
    esac
    return 1
  fi

  sleep 3
  if ! urls="$(local_chrome_urls "$d/osascript.err")"; then
    say "${C_YEL}⚠️  macOS didn't let this terminal read Chrome's tabs ($(head -c 200 "$d/osascript.err")).${C_OFF}"
    say "   → Allow it: System Settings → Privacy & Security → Automation → your terminal app → Google Chrome: ON."
    say "     Then run ./brief chrome-check again."
    say "   Or set it by hand: look at THIS Mac's Chrome for the example.com tab. Its address ends in"
    say "   ?$PROBE_KEY=<deviceId>. Then run: ./brief chrome-check --use <deviceId>"
    say "   Browsers probed:"; printf '%s\n' "$res" | sed 's/^/     /'
    return 1
  fi
  found="$(printf '%s\n' "$urls" | sed -n "s/.*$PROBE_KEY=\([0-9a-fA-F-]\{36\}\).*/\1/p" | sort -u)"
  n="$(printf '%s\n' "$found" | grep -c .)"
  close_local_probe_tabs
  others="$(printf '%s\n' "$probed" | grep -v -x -F "${found:-none}" | tr '\n' ' ')"
  if [ -n "$(printf '%s' "$others" | tr -d ' ')" ]; then
    say "${C_DIM}Closing the test tabs on the other computers…${C_OFF}"
    close_remote_probe_tabs "$d" "$others" "$probe_session" >"$d/cleanup.txt"
  fi

  if [ "$n" = 1 ]; then
    name="$(awk -F'\t' -v id="$found" '$1 == id { print $2; exit }' "$d/probed.tsv")"
    chrome_save_device "$found" "$name"
    say "${C_GRN}✅ This Mac's Chrome is ${name:-connected} (device $found). Saved; runs here will only ever use it.${C_OFF}"
    [ -n "$(printf '%s' "$others" | tr -d ' ')" ] && say "   Other computers' browsers on your account ($others) will never be used from this Mac."
    return 0
  fi
  if [ "$n" = 0 ]; then
    say "${C_RED}❌ None of the connected browsers is this Mac's Chrome.${C_OFF} Connected: $(tr '\t\n' ' ;' <"$d/probed.tsv")"
    say "   → On THIS Mac: open Chrome, sign the Claude extension in to the same account as Claude Code,"
    say "     quit Chrome (⌘Q), reopen it, then run ./brief chrome-check again."
  else
    say "${C_RED}❌ Found several probe tabs in this Mac's Chrome ($found).${C_OFF} Run ./brief chrome-check again."
  fi
  return 1
}

# Prompt fragment telling the research run exactly which browser to use.
chrome_prompt_note() {
  local id
  id="$(chrome_device_id)"
  if [ -z "$id" ]; then
    printf '%s\n' "# Chrome
This Mac's Chrome has not been identified yet, so do NOT use any Claude in Chrome tool in this run.
For sources marked Chrome, use WebSearch/WebFetch (and the fallbacks in sources.md). Add this line to notes.txt:
Chrome: not set up on this Mac (run ./brief chrome-check)"
    return
  fi
  printf '%s\n' "# Chrome
Claude in Chrome is ENABLED for this run. Use it only for sources marked \"Tool: Chrome\" (or as the stated fallback).
Several computers' browsers may be connected to this account. This Mac's browser has deviceId $id.
- FIRST call list_connected_browsers. If $id is in the list, call select_browser with deviceId $id. Then continue.
- Use ONLY that browser. Never select any other deviceId, never trust isLocal/inUse, never call switch_browser.
- If $id is not in the list, or select_browser fails, do NOT use any Chrome tool. Use the fallbacks, and add this line to notes.txt:
  Chrome: this Mac's browser not connected (run ./brief chrome-check)"
}
