# shellcheck shell=bash
# The inner `claude -p` research run: prompt rendering, sandboxed invocation, timeout, result parsing.

# Read-only Claude in Chrome tools. Everything else from that server (computer, form_input,
# file_upload, javascript_tool, browser_batch, ...) is left unallowed and therefore auto-denied
# under dontAsk, and the ones that can act on a page are explicitly disallowed too.
CHROME_READ_TOOLS="mcp__claude-in-chrome__tabs_context_mcp mcp__claude-in-chrome__tabs_create_mcp mcp__claude-in-chrome__tabs_close_mcp mcp__claude-in-chrome__navigate mcp__claude-in-chrome__get_page_text mcp__claude-in-chrome__read_page mcp__claude-in-chrome__find"
CHROME_DENY_TOOLS="mcp__claude-in-chrome__computer mcp__claude-in-chrome__form_input mcp__claude-in-chrome__file_upload mcp__claude-in-chrome__upload_image mcp__claude-in-chrome__javascript_tool mcp__claude-in-chrome__browser_batch mcp__claude-in-chrome__gif_creator"

CLAUDE_PGID=""

# Sections that may need the logged-in browser.
sections_need_chrome() {
  local s
  for s in $1; do
    case "$s" in india|events|competitions|internships) return 0 ;; esac
  done
  return 1
}

# render_prompt <run_dir> <sections> <chrome:0|1> <today>  → writes <run_dir>/prompt.md
render_prompt() {
  local run_dir="$1" sections="$2" chrome="$3" today="$4" s list="" note profile
  for s in $sections; do
    list="$list- $s → $run_dir/$(section_file "$s")
"
  done
  if [ "$chrome" = 1 ]; then
    note="# Chrome
Claude in Chrome is ENABLED for this run. Use it only for sources marked \"Tool: Chrome\" (or as the stated fallback)."
  else
    note="# Chrome
Claude in Chrome is NOT available in this run. For any source marked Chrome, use WebSearch/WebFetch instead, and add a line to notes.txt."
  fi
  profile="$PROMPTS_DIR/profile.md"
  [ -f "$profile" ] || profile="$PROMPTS_DIR/profile.md.example"

  RP_TODAY_ISO="$today" \
  RP_TODAY_HUMAN="$(TZ=$BRIEF_TZ date -j -f '%Y-%m-%d' "$today" '+%-d %B %Y')" \
  RP_WEEKDAY="$(weekday_long "$today")" \
  RP_END_14D="$(date_add_days "$today" +14)" \
  RP_RUN_DIR="$run_dir" \
  RP_SEEN_PATH="$run_dir/seen.tsv" \
  RP_SECTIONS="$list" \
  RP_CHROME_NOTE="$note" \
  RP_PROFILE_FILE="$profile" \
  RP_SOURCES_FILE="$PROMPTS_DIR/sources.md" \
  perl -CSD -e '
    use strict; use warnings;
    sub slurp { my $f = shift; open my $h, "<:encoding(UTF-8)", $f or die "cannot read $f: $!"; local $/; my $c = <$h>; close $h; $c }
    my $t = slurp($ARGV[0]);
    my %v = (
      TODAY_ISO => $ENV{RP_TODAY_ISO}, TODAY_HUMAN => $ENV{RP_TODAY_HUMAN}, WEEKDAY => $ENV{RP_WEEKDAY},
      END_14D => $ENV{RP_END_14D}, RUN_DIR => $ENV{RP_RUN_DIR}, SEEN_PATH => $ENV{RP_SEEN_PATH},
      SECTIONS => $ENV{RP_SECTIONS}, CHROME_NOTE => $ENV{RP_CHROME_NOTE},
      PROFILE => slurp($ENV{RP_PROFILE_FILE}), SOURCES => slurp($ENV{RP_SOURCES_FILE}),
    );
    for (keys %v) { utf8::decode($v{$_}) unless utf8::is_utf8($v{$_}) }
    $t =~ s/\{\{(\w+)\}\}/exists $v{$1} ? $v{$1} : "{{$1}}"/ge;
    die "unfilled placeholder: $1\n" if $t =~ /\{\{(\w+)\}\}/;
    print $t;
  ' "$PROMPTS_DIR/brief.md" >"$run_dir/prompt.md"
}

# Kill the claude process group (used by the watchdog and on Ctrl-C).
claude_kill() {
  [ -n "$CLAUDE_PGID" ] || return 0
  kill -TERM -- "-$CLAUDE_PGID" 2>/dev/null
  local i=0
  while kill -0 -- "-$CLAUDE_PGID" 2>/dev/null && [ "$i" -lt 10 ]; do sleep 1; i=$(( i + 1 )); done
  kill -KILL -- "-$CLAUDE_PGID" 2>/dev/null
  CLAUDE_PGID=""
}

# run_claude <run_dir> <chrome:0|1>
# Returns 0 on success; 124 on timeout; otherwise claude's exit code.
# Writes result.json, claude.stderr in the run dir.
run_claude() {
  local run_dir="$1" chrome="$2" allowed denied rc waited=0 t chrome_flag
  # Read/Edit rules are absolute (leading // = filesystem root) and scoped to this run dir.
  allowed="WebSearch,WebFetch,Read(/$run_dir/**),Edit(/$run_dir/**)"
  denied="Bash,$(echo $CHROME_DENY_TOOLS | tr ' ' ',')"
  if [ "$chrome" = 1 ]; then
    chrome_flag="--chrome"
    allowed="$allowed,$(echo $CHROME_READ_TOOLS | tr ' ' ',')"
  else
    chrome_flag="--no-chrome"
  fi

  log_only "claude: $CLAUDE_BIN -p --model $MODEL $chrome_flag (timeout ${MAX_SECONDS}s)"
  log_only "claude: allowed = $allowed"

  # setpgrp gives claude (and any MCP children) its own process group we can kill as a whole.
  # --strict-mcp-config: ignore other MCP servers/connectors (Chrome still comes from --chrome).
  (
    cd "$run_dir" || exit 1
    exec perl -e 'setpgrp(0, 0); exec @ARGV or die "exec failed: $!\n"' \
      "$CLAUDE_BIN" -p \
      --model "$MODEL" \
      "$chrome_flag" \
      --output-format json \
      --permission-mode dontAsk \
      --permission-prompts none \
      --strict-mcp-config \
      --no-session-persistence \
      --allowedTools "$allowed" \
      --disallowedTools "$denied" \
      <"$run_dir/prompt.md" >"$run_dir/result.json" 2>"$run_dir/claude.stderr"
  ) &
  CLAUDE_PGID=$!

  t=0
  while kill -0 "$CLAUDE_PGID" 2>/dev/null; do
    sleep 2; waited=$(( waited + 2 )); t=$(( t + 2 ))
    if [ "$t" -ge 60 ]; then t=0; log_only "claude: still running (${waited}s)"; fi
    if [ "$waited" -ge "$MAX_SECONDS" ]; then
      log_only "claude: timeout after ${MAX_SECONDS}s, killing process group $CLAUDE_PGID"
      claude_kill
      wait 2>/dev/null
      return 124
    fi
  done
  wait "$CLAUDE_PGID"; rc=$?
  CLAUDE_PGID=""
  return "$rc"
}

# Parse result.json into shell-friendly key=value lines (values single-line).
claude_result_fields() {
  perl -MJSON::PP -e '
    local $/; my $raw = <STDIN>; my $d = eval { decode_json($raw) };
    if (!$d) { print "parse_ok=0\n"; exit 0 }
    $d = $d->[-1] if ref $d eq "ARRAY";
    my $u = $d->{usage} || {};
    my %o = (
      parse_ok => 1,
      is_error => ($d->{is_error} ? 1 : 0),
      subtype => $d->{subtype} // "",
      num_turns => $d->{num_turns} // "",
      duration_ms => $d->{duration_ms} // "",
      total_cost_usd => defined $d->{total_cost_usd} ? sprintf("%.4f", $d->{total_cost_usd}) : "",
      api_error_status => $d->{api_error_status} // "",
      stop_reason => $d->{stop_reason} // "",
      terminal_reason => $d->{terminal_reason} // "",
      input_tokens => $u->{input_tokens} // "",
      output_tokens => $u->{output_tokens} // "",
      cache_read_tokens => $u->{cache_read_input_tokens} // "",
      cache_write_tokens => $u->{cache_creation_input_tokens} // "",
      permission_denials => scalar(@{ $d->{permission_denials} || [] }),
      denied_tools => join(",", map { $_->{tool_name} } @{ $d->{permission_denials} || [] }),
      result => $d->{result} // "",
    );
    for my $k (sort keys %o) { (my $v = $o{$k}) =~ s/[\r\n]+/ /g; print "$k=$v\n" }
  ' <"$1"
}

# Does this text look like a usage/rate limit message?
looks_like_usage_limit() {
  grep -qiE "usage limit|limit reached|rate.?limit|hit your limit|out of (extra )?usage|5-hour limit|weekly limit|quota|too many requests|\b429\b" "$@" 2>/dev/null
}
