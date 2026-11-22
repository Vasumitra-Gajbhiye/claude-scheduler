# shellcheck shell=bash
# To-dos & exams from Outlook → Notion → Telegram (`brief tasks`, plus the 📝 section of the brief).
#
# A separate `claude -p` run ("tasks sync") reads the Outlook inbox in Chrome (read-only, plus guarded
# clicks on inbox rows), creates/updates rows in the Notion Tasks and Exams databases, and writes a
# snapshot of what's open. Bash then decides what to nag about (deterministic, tested offline) and sends.
#   morning: runs inside the scheduled brief, before the news research; the brief gets a 📝 section
#   evening: from the same LaunchAgent at/after TASKS_EVENING_HOUR; sends only if something needs nagging
# Safety: see lib/hooks/guard.sh (second layer) and run_claude's "tasks" profile (first layer).

TASKS_SNAPSHOT="$STATE_DIR/tasks_snapshot.tsv"     # kind, page_id, title, due, type, added_by, link, info
TASKS_SNAPSHOT_AT="$STATE_DIR/tasks_snapshot_at"   # when the snapshot was taken (human)
TASKS_NAGS="$STATE_DIR/task_nags.tsv"              # nag_key, date
TASKS_LEDGER="$STATE_DIR/notion_bot_pages.txt"     # Notion page ids the bot created (only these may be edited)
TASKS_MAIL_SEEN="$STATE_DIR/mail_seen.tsv"         # date_processed, mail_key, decision
TASKS_NEW="$STATE_DIR/tasks_new.tsv"               # page_id, date_created, kind, title, due
TASKS_STATUS_FILE="$STATE_DIR/tasks_status"        # key=value from the last sync

TASKS_NOTION_TOOLS="mcp__claude_ai_Notion__notion-search mcp__claude_ai_Notion__notion-fetch mcp__claude_ai_Notion__notion-query-data-sources mcp__claude_ai_Notion__notion-create-pages mcp__claude_ai_Notion__notion-update-page"
# Every other connector server, plus the Notion tools that delete, move, restructure or message.
# (Anything not allowed is denied under dontAsk anyway, and the guard denies everything unlisted.)
TASKS_DENY_TOOLS="mcp__claude_ai_Gmail mcp__claude_ai_Google_Drive mcp__claude_ai_Google_Calendar mcp__claude_ai_Lovable mcp__claude_ai_PostHog mcp__claude_ai_Claude_Docs mcp__claude_ai_Notion__notion-delete-pages mcp__claude_ai_Notion__notion-delete-databases mcp__claude_ai_Notion__notion-move-pages mcp__claude_ai_Notion__notion-duplicate-page mcp__claude_ai_Notion__notion-update-data-source mcp__claude_ai_Notion__notion-create-database mcp__claude_ai_Notion__notion-create-view mcp__claude_ai_Notion__notion-update-view mcp__claude_ai_Notion__notion-create-comment mcp__claude_ai_Notion__notion-update-comment mcp__claude_ai_Notion__notion-delete-comment mcp__claude_ai_Notion__notion-send-message-to-session mcp__claude_ai_Notion__notion-spawn-session mcp__claude_ai_Notion__notion-stop-session mcp__claude_ai_Notion__notion-calendar-create-events mcp__claude_ai_Notion__notion-calendar-update-events mcp__claude_ai_Notion__notion-calendar-cancel-events mcp__claude_ai_Notion__notion-restore-pages mcp__claude_ai_Notion__notion-restore-version mcp__claude_ai_Notion__notion-upload-skill mcp__claude_ai_Notion__notion-update-skill-settings mcp__claude_ai_Notion__notion-convert-page-to-skill mcp__claude_ai_Notion__notion-update-sidebar-tabs mcp__claude_ai_Notion__notion-update-page-favorites mcp__claude_ai_Notion__notion-create-folder mcp__claude_ai_Notion__notion-update-folder mcp__claude_ai_Notion__notion-create-file-upload mcp__claude_ai_Notion__notion-create-attachment mcp__claude_ai_Notion__notion-create-meeting-note mcp__claude_ai_Notion__notion-convert-to-meetings-database mcp__claude_ai_Notion__notion-create-suggested-edit mcp__claude_ai_Notion__notion-resolve-suggested-edit mcp__claude_ai_Notion__notion-set-comment-reaction mcp__claude_ai_Notion__notion-set-discussion-resolved mcp__claude_ai_Notion__notion-link-meeting-note-to-calendar-event mcp__claude_ai_Notion__notion-complete-mcp-setup"

TASKS_RUN_DIR=""; TASKS_FAIL_REASON=""; TASKS_READSTATE="ok"; TASKS_OUTLOOK="skipped"; TASKS_OUTING_WEEK="no"; TASKS_OLDEST=""; TASKS_SINCE=""

tasks_configured() { [ "${TASKS_ENABLED:-0}" = 1 ] && [ -n "${NOTION_TASKS_DS:-}" ] && [ -n "${NOTION_EXAMS_DS:-}" ]; }
tasks_guard_dir()  { printf '%s.guard' "$1"; }
tasks_ds_id()      { printf '%s' "$1" | sed 's#^collection://##' | tr -d '-' | tr 'A-F' 'a-f'; }
tasks_status_get() { sed -n "s/^$1=//p" "$TASKS_STATUS_FILE" 2>/dev/null | head -1; }
# Monday of the week containing an ISO date.
week_start() { date_add_days "$1" "-$(( $(TZ=$BRIEF_TZ date -j -f '%Y-%m-%d' "$1" '+%u') - 1 ))"; }

tasks_chrome_note() {
  local id; id="$(chrome_device_id)"
  if [ -z "$id" ]; then
    printf '%s\n' "This Mac's Chrome has not been identified (./brief chrome-check), so Outlook can't be read in this run.
Do NOT use any Chrome tool. Skip steps 1-3, write outlook=skipped in status.txt, and still do step 4."
    return
  fi
  printf '%s\n' "Several computers' browsers may be connected to this account. This Mac's browser has deviceId $id.
- FIRST call list_connected_browsers. If $id is in the list, call select_browser with deviceId $id. Use ONLY that browser.
- If it isn't listed or select_browser fails: use no Chrome tool, write outlook=fail in status.txt, and still do step 4.
- Then call tabs_context_mcp with createIfEmpty: true and open your own new tab with tabs_create_mcp."
}

# How the run reads Notion: "view" mode (no quota) when saved views are configured, else rows mode.
tasks_notion_read_note() {
  if [ -n "${NOTION_TASKS_VIEW:-}" ] && [ -n "${NOTION_EXAMS_VIEW:-}" ]; then
    printf '%s\n' "  - Read each database ONCE, before Step 3, with notion-query-data-sources in \"view\" mode, page_size 100 (if has_more, repeat with start_cursor = next_cursor):
    - Tasks: view_url $NOTION_TASKS_VIEW
    - Exams: view_url $NOTION_EXAMS_VIEW
  - These views don't filter by date: filter the rows yourself. Never use rows or SQL mode (they hit a usage limit)."
  else
    printf '%s\n' "  - Read each database ONCE, before Step 3, with notion-query-data-sources in \"rows\" mode with a Date filter, limit 100. Use SQL only if rows mode fails."
  fi
}

# tasks_render_prompt <run_dir> <slot> <dry:0|1> <today> <now_hm>
tasks_render_prompt() {
  local run_dir="$1" slot="$2" dry="$3" today="$4" now_hm="$5" wk dry_note
  wk="$(week_start "$today")"
  if [ "$dry" = 1 ]; then
    dry_note="# DRY RUN
This is a dry run. Do NOT call notion-create-pages or notion-update-page at all (the guard blocks them).
Do everything else, and in actions.tsv list what you WOULD do, as would-create / would-update / would-done."
  else
    dry_note=""
  fi
  RP_TODAY_ISO="$today" \
  RP_TODAY_HUMAN="$(TZ=$BRIEF_TZ date -j -f '%Y-%m-%d' "$today" '+%-d %B %Y')" \
  RP_WEEKDAY="$(weekday_long "$today")" \
  RP_NOW_HM="$(printf '%s:%s' "${now_hm%??}" "${now_hm#??}")" \
  RP_SLOT="$slot" \
  RP_WEEK_START="$wk" RP_WEEK_END="$(date_add_days "$wk" +6)" \
  RP_SINCE_DATE="$(date_add_days "$today" "-${TASKS_MAIL_DAYS:-3}")" \
  RP_PAST_7D="$(date_add_days "$today" -7)" RP_END_60D="$(date_add_days "$today" +60)" \
  RP_RUN_DIR="$run_dir" RP_PROCESSED_PATH="$run_dir/processed.tsv" \
  RP_TASKS_DS="$(printf '%s' "$NOTION_TASKS_DS" | sed 's#^collection://##')" \
  RP_EXAMS_DS="$(printf '%s' "$NOTION_EXAMS_DS" | sed 's#^collection://##')" \
  RP_NOTION_READ="$(tasks_notion_read_note)" \
  RP_CHROME_NOTE="$(tasks_chrome_note)" RP_DRY_NOTE="$dry_note" \
  perl -CSD -e '
    use strict; use warnings;
    open my $h, "<:encoding(UTF-8)", $ARGV[0] or die "cannot read $ARGV[0]: $!"; local $/; my $t = <$h>;
    my %v = map { (my $k = $_) =~ s/^RP_//; ($k => $ENV{$_}) } grep { /^RP_/ } keys %ENV;
    for (keys %v) { utf8::decode($v{$_}) unless utf8::is_utf8($v{$_}) }
    $t =~ s/\{\{(\w+)\}\}/exists $v{$1} ? $v{$1} : "{{$1}}"/ge;
    die "unfilled placeholder: $1\n" if $t =~ /\{\{(\w+)\}\}/;
    print $t;
  ' "$PROMPTS_DIR/tasks.md" >"$run_dir/prompt.md"
}

# tasks_write_guard <run_dir> <dry:0|1>: guard state dir + settings.json with the hooks.
tasks_write_guard() {
  local run_dir="$1" dry="$2" g
  g="$(tasks_guard_dir "$run_dir")"
  mkdir -p "$g"; : >"$g/clickable.tsv"
  mkdir -p "$STATE_DIR"; [ -f "$TASKS_LEDGER" ] || : >"$TASKS_LEDGER"
  {
    echo "RUN_DIR=$run_dir"
    echo "LEDGER=$TASKS_LEDGER"
    echo "DS_IDS=$(tasks_ds_id "$NOTION_TASKS_DS") $(tasks_ds_id "$NOTION_EXAMS_DS")"
    echo "CHROME_DEVICE=$(chrome_device_id)"
    echo "DRY=$dry"
  } >"$g/guard.conf"
  GUARD="$REPO_DIR/lib/hooks/guard.sh" GDIR="$g" perl -MJSON::PP -e '
    sub shq { my $s = shift; $s =~ s/\x27/\x27\\\x27\x27/g; "\x27$s\x27" }
    my $pre  = shq($ENV{GUARD}) . " pre "  . shq($ENV{GDIR});
    my $post = shq($ENV{GUARD}) . " post " . shq($ENV{GDIR});
    print JSON::PP->new->canonical->pretty->encode({ hooks => {
      PreToolUse  => [ { matcher => ".*",     hooks => [ { type => "command", command => $pre,  timeout => 30 } ] } ],
      PostToolUse => [ { matcher => "mcp__.*", hooks => [ { type => "command", command => $post, timeout => 30 } ] } ],
    } });' >"$g/settings.json"
}

# tasks_parse <in> <out>: keep valid snapshot rows (8 fields), normalise ids and dates.
tasks_parse() {
  : >"$2"
  [ -f "$1" ] || return 0
  tr -d '\r' <"$1" | perl -CSD -ne '
    chomp; my @f = split /\t/, $_, -1; next if @f < 4;
    s/^\s+|\s+$//g for @f; push @f, "" while @f < 8;
    my ($k, $id, $title, $due, $type, $by, $link, $info) = @f[0..7];
    $k = lc $k; next unless $k =~ /^(task|exam)$/;
    ($id = lc $id) =~ s/-//g; ($id) = $id =~ /([0-9a-f]{32})/; next unless $id;
    next unless length $title;
    if ($due =~ /^(\d{4}-\d\d-\d\d)(?:[T ](\d\d):(\d\d))?/) { $due = $1 . (defined $2 ? "T$2:$3" : "") } else { $due = "" }
    $by = lc $by eq "bot" ? "bot" : "me";
    $link = "" unless $link =~ m{^https?://\S+$};
    s/[\t\n]/ /g for $title, $type, $info;
    print join("\t", $k, $id, $title, $due, $type, $by, $link, substr($info, 0, 120)), "\n";'  >"$2"
}

# tasks_sync <slot> <dry:0|1>: one claude run. Sets TASKS_RUN_DIR, TASKS_FAIL_REASON, TASKS_READSTATE,
# TASKS_OUTLOOK, TASKS_OUTING_WEEK. On success (not dry) updates the state snapshot, ledger, mail memory.
tasks_sync() {
  local slot="$1" dry="$2" today now_hm run_dir g rc fields is_error reason chrome=0 created
  today="$(today_iso)"; now_hm="${BRIEF_NOW_HM:-$(TZ=$BRIEF_TZ date '+%H%M')}"
  TASKS_FAIL_REASON=""; TASKS_READSTATE="ok"; TASKS_OUTLOOK="skipped"; TASKS_OUTING_WEEK="no"
  run_dir="$RUNS_DIR/$(TZ=$BRIEF_TZ date '+%Y%m%d-%H%M%S')-tasks-$slot"
  [ "$dry" = 1 ] && run_dir="$run_dir-dry"
  TASKS_RUN_DIR="$run_dir"
  mkdir -p "$run_dir"; g="$(tasks_guard_dir "$run_dir")"
  log_only "tasks: run dir $run_dir"

  # Mail handled on earlier runs (last 14 days), so the run doesn't open it again.
  [ -f "$TASKS_MAIL_SEEN" ] || : >"$TASKS_MAIL_SEEN"
  awk -F'\t' -v c="$(date_add_days "$today" -14)" '$1 >= c { print $2 "\t" $3 }' "$TASKS_MAIL_SEEN" >"$run_dir/processed.tsv"

  [ -n "$(chrome_device_id)" ] && chrome=1
  tasks_render_prompt "$run_dir" "$slot" "$dry" "$today" "$now_hm" || { TASKS_FAIL_REASON="could not build the to-do prompt"; return 1; }
  tasks_write_guard "$run_dir" "$dry"

  run_claude "$run_dir" "$chrome" tasks; rc=$?
  fields="$(claude_result_fields "$run_dir/result.json" 2>/dev/null)"
  printf '%s\n' "$fields" | grep -v '^result=' | sed 's/^/tasks claude: /' | while IFS= read -r l; do log_only "$l"; done
  log_only "tasks claude result: $(printf '%s\n' "$fields" | sed -n 's/^result=//p' | cut -c1-300)"
  [ -s "$run_dir/claude.stderr" ] && log_only "tasks claude stderr: $(head -c 1500 "$run_dir/claude.stderr" | tr '\n' ' ')"
  [ -s "$g/blocked.log" ] && while IFS= read -r l; do log_only "tasks guard blocked: $l"; done <"$g/blocked.log"

  # Pages the bot created are the bot's, whatever else happened in the run.
  if [ "$dry" = 0 ]; then
    created="$( { cat "$g/created_pages.txt" 2>/dev/null; awk -F'\t' '$1 == "created" { print $3 }' "$run_dir/actions.tsv" 2>/dev/null; } |
      tr 'A-F' 'a-f' | tr -d '-' | grep -E '^[0-9a-f]{32}$' )"
    [ -n "$created" ] && { cat "$TASKS_LEDGER" 2>/dev/null; printf '%s\n' "$created"; } | sort -u >"$TASKS_LEDGER.tmp" && mv "$TASKS_LEDGER.tmp" "$TASKS_LEDGER"
  fi

  if [ "$rc" = 124 ]; then TASKS_FAIL_REASON="to-do check timed out after ${TASKS_MAX_SECONDS}s"; return 1; fi
  is_error="$(printf '%s\n' "$fields" | sed -n 's/^is_error=//p')"
  if [ "$rc" != 0 ] || [ "$is_error" = 1 ]; then
    if looks_like_usage_limit "$run_dir/result.json" "$run_dir/claude.stderr"; then
      TASKS_FAIL_REASON="Claude usage limit reached"; return 1
    fi
    reason="$(printf '%s\n' "$fields" | sed -n 's/^result=//p' | cut -c1-150)"
    TASKS_FAIL_REASON="claude exited $rc: ${reason:-no details}"; return 1
  fi

  TASKS_OUTLOOK="$(sed -n 's/^outlook=//p' "$run_dir/status.txt" 2>/dev/null | head -1 | tr -d ' ')"
  TASKS_OUTLOOK="${TASKS_OUTLOOK:-fail}"
  { [ -e "$g/readstate_unsafe" ] || grep -q '^readstate=unsafe' "$run_dir/status.txt" 2>/dev/null; } && TASKS_READSTATE="unsafe"
  grep -q '^outing_week=yes' "$run_dir/status.txt" 2>/dev/null && TASKS_OUTING_WEEK="yes"
  TASKS_OLDEST="$(sed -n 's/^oldest_row=//p' "$run_dir/status.txt" 2>/dev/null | head -1 | tr -d ' ')"
  TASKS_SINCE="$(date_add_days "$today" "-${TASKS_MAIL_DAYS:-3}")"
  awk -F'\t' -v w="$(week_start "$today")" '$1 >= w && $3 == "outing"' "$TASKS_MAIL_SEEN" | grep -q . && TASKS_OUTING_WEEK="yes"

  tasks_parse "$run_dir/tasks.tsv" "$run_dir/tasks.clean.tsv"
  if ! grep -q '^notion=ok' "$run_dir/status.txt" 2>/dev/null; then
    TASKS_FAIL_REASON="couldn't read Notion"; return 1
  fi

  if [ "$dry" = 0 ]; then
    cp "$run_dir/tasks.clean.tsv" "$TASKS_SNAPSHOT"
    now_human >"$TASKS_SNAPSHOT_AT"
    if [ -s "$run_dir/mail.tsv" ]; then
      tr -d '\r' <"$run_dir/mail.tsv" | awk -F'\t' -v OFS='\t' -v d="$today" '$1 != "" && $2 != "error" && $2 != "skipped" { print d, $1, $2 }' >>"$TASKS_MAIL_SEEN"
    fi
    if [ -s "$run_dir/actions.tsv" ]; then
      tr -d '\r' <"$run_dir/actions.tsv" | awk -F'\t' -v OFS='\t' -v d="$today" '$1 == "created" && $3 != "" { gsub(/-/, "", $3); print tolower($3), d, $2, $4, $5 }' >>"$TASKS_NEW"
    fi
    tasks_prune "$today"
  fi
  {
    echo "time=$(now_human)"; echo "slot=$slot"; echo "dry=$dry"
    echo "outlook=$TASKS_OUTLOOK"; echo "readstate=$TASKS_READSTATE"; echo "outing_week=$TASKS_OUTING_WEEK"
    echo "oldest_row=$TASKS_OLDEST"
    echo "created=$(awk -F'\t' '$1 ~ /created$/' "$run_dir/actions.tsv" 2>/dev/null | wc -l | tr -d ' ')"
    echo "open=$(grep -c '^task' "$run_dir/tasks.clean.tsv" 2>/dev/null || true)"
    echo "exams=$(grep -c '^exam' "$run_dir/tasks.clean.tsv" 2>/dev/null || true)"
    echo "run_dir=$run_dir"
  } >"$TASKS_STATUS_FILE"
  return 0
}

# Forget old mail keys, new-row markers and nag records.
tasks_prune() {
  local today="$1" c f
  c="$(date_add_days "$today" -30)"
  for f in "$TASKS_MAIL_SEEN" "$TASKS_NAGS"; do
    [ -f "$f" ] || continue
    awk -F'\t' -v c="$c" -v col="$([ "$f" = "$TASKS_NAGS" ] && echo 2 || echo 1)" '$col >= c' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
  done
  [ -f "$TASKS_NEW" ] && awk -F'\t' -v c="$(date_add_days "$today" -7)" '$2 >= c' "$TASKS_NEW" >"$TASKS_NEW.tmp" && mv "$TASKS_NEW.tmp" "$TASKS_NEW"
  return 0
}

# tasks_compose <slot> <today> <now_hm> <snapshot> <out_msg> <out_record>
# The nag rules. Writes the Telegram message (or nothing) to <out_msg>, "1" to <out_msg>.sound if it
# should buzz, and the nag keys to remember (only after a successful send) to <out_record>.
#   morning (a section of the brief): open tasks due within 14 days (⏰ today/tomorrow, 🆕 new),
#     overdue ones from the last 3 days, exams within 14 days.
#   evening (own message, only if needed): tasks due within 2 days; a one-time "missed?" note per
#     task after its deadline; exams at 7, 3 and 1 days out; rows added today; and, Thu–Sat, a
#     once-a-week heads-up if no Sunday-outing email was seen this week.
tasks_compose() {
  : >"$5"; : >"$6"; rm -f "$5.sound"
  SLOT="$1" TODAY="$2" NOW_HM="$3" SNAP="$4" OUTMSG="$5" OUTREC="$6" NAGS="$TASKS_NAGS" NEWF="$TASKS_NEW" \
  OUTING_WEEK="${TASKS_OUTING_WEEK:-yes}" WEEK_START="$(week_start "$2")" perl -CSD -Mutf8 -MPOSIX -e '
    use strict; use warnings;
    sub dnum { my ($y,$m,$d) = ($_[0] // "") =~ /^(\d{4})-(\d\d)-(\d\d)/ or return undef;
               int((POSIX::mktime(0,0,12,$d,$m-1,$y-1900) + 43200) / 86400) }
    sub pretty { my ($y,$m,$d) = $_[0] =~ /^(\d{4})-(\d\d)-(\d\d)/; my $t = POSIX::mktime(0,0,12,$d,$m-1,$y-1900);
                 POSIX::strftime("%a", localtime $t) . " " . ($d + 0) . " " . POSIX::strftime("%b", localtime $t) }
    sub hm { my ($h, $m) = ($_[0] // "") =~ /T(\d\d):(\d\d)/ or return ""; my $ap = $h >= 12 ? "PM" : "AM"; my $h12 = $h % 12 || 12;
             $m eq "00" ? "$h12 $ap" : "$h12:$m $ap" }
    sub hmnum { my ($h, $m) = ($_[0] // "") =~ /T(\d\d):(\d\d)/ or return undef; $h * 100 + $m }
    sub rd { my $f = shift; return () unless $f && -f $f; open my $h, "<:encoding(UTF-8)", $f or return (); map { chomp; [split /\t/, $_, -1] } <$h> }
    sub rel { my $l = shift; $l == 0 ? "today" : $l == 1 ? "tomorrow" : $l == -1 ? "yesterday" : $l > 0 ? "in $l days" : (-$l) . " days ago" }
    sub when { my ($due, $left) = @_; my $t = hm($due); my $r = rel($left);
               ($left == 0 || $left == 1 || $left == -1) ? $r . ($t ? ", $t" : "") . " (" . pretty($due) . ")" : pretty($due) . ($t ? ", $t" : "") . " ($r)" }
    my ($slot, $now) = ($ENV{SLOT}, $ENV{NOW_HM} + 0);
    my $today = dnum($ENV{TODAY});
    my %nagged = map { ($_->[0] // "") => 1 } rd($ENV{NAGS});
    my %new; my @new_rows;
    for my $r (rd($ENV{NEWF})) { my $d = dnum($r->[1]) // next; $new{$r->[0]} = $d; push @new_rows, $r if $d == $today }
    my (@tasks, @exams);
    for my $r (rd($ENV{SNAP})) {
      my ($k, $id, $title, $due, $type, $by, $link, $info) = map { $_ // "" } @$r[0..7];
      my $d = dnum($due); next unless defined $d;
      my $x = { id => $id, title => $title, due => $due, left => $d - $today, type => $type, link => $link, info => $info, hm => hmnum($due) };
      push @{ $k eq "exam" ? \@exams : \@tasks }, $x;
    }
    @tasks = sort { $a->{left} <=> $b->{left} || ($a->{hm} // 2400) <=> ($b->{hm} // 2400) || $a->{title} cmp $b->{title} } @tasks;
    @exams = sort { $a->{left} <=> $b->{left} || $a->{title} cmp $b->{title} } @exams;
    # A task due today at a time that has already passed counts as missed.
    my $passed = sub { my $t = shift; $t->{left} < 0 || ($t->{left} == 0 && defined $t->{hm} && $t->{hm} <= $now) };
    my (@out, @rec); my $sound = 0;
    my $item = sub { my ($n, $mark, $t, $line) = @_; my $s = "$n. " . ($mark ? "$mark " : "") . $t->{title} . (exists $new{$t->{id}} && $slot eq "morning" && $new{$t->{id}} >= $today - 1 ? " 🆕" : "") . "\n$line\n"; $s .= "$t->{link}\n" if $t->{link}; $s };

    if ($slot eq "morning") {
      my @list = grep { $_->{left} >= -3 && $_->{left} <= 14 } @tasks;
      my @ex = grep { $_->{left} >= 0 && $_->{left} <= 14 } @exams;
      exit 0 unless @list || @ex;
      push @out, "📝 TO-DO & EXAMS\n";
      my $n = 0;
      for my $t (@list) {
        $n++;
        if ($passed->($t)) { push @out, $item->($n, "❗", $t, "was due " . when($t->{due}, $t->{left}) . " · still open") }
        else { push @out, $item->($n, $t->{left} <= 1 ? "⏰" : "", $t, "due " . when($t->{due}, $t->{left})) }
      }
      push @out, "Nothing due in the next 2 weeks.\n" unless @list;
      if (@ex) {
        push @out, "🎓 EXAMS";
        push @out, join "", map { "• $_->{title}: " . ($_->{left} == 0 ? "⏰ " : "") . when($_->{due}, $_->{left}) . ($_->{info} ne "" ? " · $_->{info}" : "") . "\n" } @ex;
      }
    } else {
      my @soon = grep { !$passed->($_) && $_->{left} <= 2 } @tasks;
      my @missed = grep { $passed->($_) && $_->{left} >= -3 && !$nagged{"missed:$_->{id}"} } @tasks;
      my @ex = grep { my $l = $_->{left}; ($l == 7 || $l == 3 || $l == 1) && !$nagged{"exam$l:$_->{id}"} } @exams;
      my @added = grep { !$nagged{"new:$_->[0]"} } @new_rows;
      my $wd = (localtime(POSIX::mktime(0,0,12,(split /-/, $ENV{TODAY})[2], (split /-/, $ENV{TODAY})[1]-1, (split /-/, $ENV{TODAY})[0]-1900)))[6];
      my $outing = ($wd >= 4 && $wd <= 6) && $ENV{OUTING_WEEK} ne "yes" && !$nagged{"outing:$ENV{WEEK_START}"};
      exit 0 unless @soon || @missed || @ex || @added || $outing;
      push @out, "🌙 TO-DO CHECK · " . pretty($ENV{TODAY}) . "\n";
      if (@soon) {
        push @out, "⏰ DUE SOON";
        my $n = 0;
        for my $t (@soon) {
          $n++; push @out, $item->($n, "", $t, "due " . when($t->{due}, $t->{left}));
          $sound = 1 if $t->{left} == 0 || ($t->{left} == 1 && defined $t->{hm} && $t->{hm} < 1200);
        }
      }
      if (@missed) {
        push @out, "❗ MISSED? STILL OPEN IN NOTION";
        my $n = 0;
        for my $t (@missed) { $n++; push @out, $item->($n, "", $t, "was due " . when($t->{due}, $t->{left}) . ". Tick it in Notion if it\x27s done."); push @rec, "missed:$t->{id}" }
      }
      if (@ex) {
        push @out, "🎓 EXAMS COMING UP";
        push @out, join "", map { push @rec, "exam$_->{left}:$_->{id}"; "• $_->{title}: " . when($_->{due}, $_->{left}) . ($_->{info} ne "" ? " · $_->{info}" : "") . "\n" } @ex;
      }
      if (@added) {
        push @out, "🆕 ADDED FROM EMAIL TODAY";
        push @out, join "", map { push @rec, "new:$_->[0]"; "• " . ($_->[3] // "") . (dnum($_->[4]) ? " (due " . pretty($_->[4]) . ")" : "") . "\n" } @added;
      }
      if ($outing) { push @out, "🏕️ No Sunday-outing email seen this week. Worth checking Outlook?\n"; push @rec, "outing:$ENV{WEEK_START}" }
    }
    open my $m, ">:encoding(UTF-8)", $ENV{OUTMSG} or die; print $m join("\n", @out); close $m;
    open my $r, ">", $ENV{OUTREC} or die; print $r "$_\n" for @rec; close $r;
    if ($sound) { open my $s, ">", "$ENV{OUTMSG}.sound" or die; print $s "1\n" }
  '
}

# Remember the nag keys after a successful send.
tasks_record_nags() {
  [ -s "$2" ] || return 0
  mkdir -p "$STATE_DIR"
  awk -v d="$1" '{ print $0 "\t" d }' "$2" >>"$TASKS_NAGS"
}

# The 📝 section for the brief: <out_file> <today> <now_hm> [snapshot]. Returns 1 if nothing to show.
tasks_morning_section() {
  local out="$1" today="$2" now_hm="$3" snap="${4:-$TASKS_SNAPSHOT}" at
  tasks_configured || return 1
  [ -f "$snap" ] || return 1
  tasks_compose morning "$today" "$now_hm" "$snap" "$out" "$out.rec"
  rm -f "$out.rec" "$out.sound"
  [ -s "$out" ] || { rm -f "$out"; return 1; }
  # Say how old the list is if this morning's sync didn't refresh it.
  if [ -n "${TASKS_FAIL_REASON:-}" ] && [ -f "$TASKS_SNAPSHOT_AT" ]; then
    at="$(cat "$TASKS_SNAPSHOT_AT")"
    printf '\n(From Notion as of %s: this morning'\''s check failed.)\n' "$at" >>"$out"
  fi
  return 0
}

# ------------------------------------------------------------------ scheduling
tasks_attempts_today() {
  local d n
  read -r d n <"$STATE_DIR/tasks_attempts" 2>/dev/null || { echo 0; return; }
  [ "$d" = "$1" ] && echo "${n:-0}" || echo 0
}
# Is the evening check due? (configured, past TASKS_EVENING_HOUR, not done today, attempts left)
tasks_evening_due() {
  local today="$1" now_hm
  tasks_configured || return 1
  now_hm="${BRIEF_NOW_HM:-$(TZ=$BRIEF_TZ date '+%H%M')}"
  [ "$((10#$now_hm))" -ge "$(( 10#${TASKS_EVENING_HOUR:-19} * 100 ))" ] || return 1
  [ "$(cat "$STATE_DIR/tasks_last_evening" 2>/dev/null)" = "$today" ] && return 1
  [ "$(tasks_attempts_today "$today")" -lt "${TASKS_MAX_ATTEMPTS:-2}" ] || return 1
  return 0
}

# ------------------------------------------------------------------ brief tasks
tasks_fail() {
  local reason="$1" msg
  trap - EXIT; trap run_on_exit_quiet EXIT
  err "To-do check failed: $reason"
  write_last_run "failed" "$(( $(epoch_now) - RUN_START ))s" 0 "$RUN_MODE" "$reason"
  msg="⚠️ To-do check failed: $reason

$(tail -n 8 "$LOG_FILE" 2>/dev/null | cut -c1-300 | redact)

Log: ${LOG_FILE/#$HOME/~}"
  if [ "$DRY_RUN" = 0 ] && [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
    tg_send_text "$msg" 1 || log_only "Could not send the failure alert: ${TG_LAST_ERROR:-unknown}"
  fi
  exit 1
}

tasks_on_exit() {
  local rc=$?
  claude_kill; lock_release
  if [ "$rc" != 0 ] && [ "$FAIL_HANDLED" = 0 ]; then FAIL_HANDLED=1; tasks_fail "unexpected internal error (exit $rc)"; fi
}

cmd_tasks() {
  local slot="" scheduled=0 today now_hm msg rec silent
  DRY_RUN=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --scheduled) scheduled=1 ;;
      --slot) [ $# -ge 2 ] || die "--slot needs morning or evening"; slot="$2"; shift ;;
      --slot=*) slot="${1#--slot=}" ;;
      --status) tasks_print_status; return 0 ;;
      *) die "Unknown option for tasks: $1 (see ./brief help)" ;;
    esac
    shift
  done
  tasks_configured || die "To-dos aren't set up. In config.env set TASKS_ENABLED=1, NOTION_TASKS_DS and NOTION_EXAMS_DS (see README)."
  today="$(today_iso)"; now_hm="${BRIEF_NOW_HM:-$(TZ=$BRIEF_TZ date '+%H%M')}"
  if [ -z "$slot" ]; then
    if [ "$((10#$now_hm))" -ge "$(( 10#${TASKS_EVENING_HOUR:-19} * 100 ))" ]; then slot=evening; else slot=morning; fi
  fi
  case "$slot" in morning|evening) ;; *) die "--slot must be morning or evening" ;; esac
  RUN_MODE="tasks $slot"; [ "$scheduled" = 1 ] && RUN_MODE="$RUN_MODE scheduled"; [ "$DRY_RUN" = 1 ] && RUN_MODE="$RUN_MODE dry-run"
  mkdir -p "$STATE_DIR" "$RUNS_DIR" "$LOGS_DIR"

  if ! lock_acquire; then
    [ "$scheduled" = 1 ] && { record_check "skip tasks: another run in progress (pid $LOCK_HOLDER)"; exit 0; }
    die "Another run is already in progress (pid $LOCK_HOLDER)."
  fi
  FAIL_HANDLED=0
  trap tasks_on_exit EXIT
  trap run_on_signal INT TERM
  if [ "$scheduled" = 1 ]; then
    printf '%s %s\n' "$today" "$(( $(tasks_attempts_today "$today") + 1 ))" >"$STATE_DIR/tasks_attempts"
    record_check "run: to-do check ($slot)"
  fi

  start_log
  RUN_START="$(epoch_now)"
  log "📝 To-do check ($slot): $(now_human): mode: $RUN_MODE"
  [ "$scheduled" = 1 ] && wait_for_network
  [ -n "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ] || { FAIL_HANDLED=1; tasks_fail "claude binary not found"; }
  if [ "$DRY_RUN" = 0 ]; then
    [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] || die "Telegram isn't configured (use --dry-run, or ./brief chat-id)."
  fi
  [ -n "$(chrome_device_id)" ] && ensure_chrome "$scheduled"

  log "🔎 Reading Outlook + Notion (timeout ${TASKS_MAX_SECONDS}s)…"
  if ! tasks_sync "$slot" "$DRY_RUN"; then FAIL_HANDLED=1; tasks_fail "$TASKS_FAIL_REASON"; fi
  log "   outlook: $TASKS_OUTLOOK, read state: $TASKS_READSTATE, created: $(tasks_status_get created), open tasks: $(grep -c '^task' "$TASKS_RUN_DIR/tasks.clean.tsv" || true), exams: $(grep -c '^exam' "$TASKS_RUN_DIR/tasks.clean.tsv" || true)"

  msg="$TASKS_RUN_DIR/message.txt"; rec="$TASKS_RUN_DIR/nags.txt"
  tasks_compose "$slot" "$today" "$now_hm" "$TASKS_RUN_DIR/tasks.clean.tsv" "$msg" "$rec"
  tasks_footer >>"$msg"
  silent=1; [ -f "$msg.sound" ] && silent=0

  if [ "$DRY_RUN" = 1 ]; then
    say ""; say "${C_DIM}──────── message ($([ "$silent" = 0 ] && echo 'with sound' || echo silent)) ────────${C_OFF}"
    if [ -s "$msg" ]; then cat "$msg"; else say "(nothing to send)"; fi
    say ""; say "${C_DIM}──────── Notion changes it would make (actions.tsv) ────────${C_OFF}"
    cat "$TASKS_RUN_DIR/actions.tsv" 2>/dev/null || say "(none)"
    write_last_run "ok (dry run)" "$(( $(epoch_now) - RUN_START ))s" 0 "$RUN_MODE" ""
    log "✅ Dry run complete. Files: $TASKS_RUN_DIR"
    exit 0
  fi

  if [ -s "$msg" ]; then
    log "📨 Sending to Telegram ($([ "$silent" = 0 ] && echo 'with sound' || echo silent))…"
    tg_send_file "$msg" "$silent" || { FAIL_HANDLED=1; tasks_fail "Telegram send failed: ${TG_LAST_ERROR:-unknown}"; }
    tasks_record_nags "$today" "$rec"
  else
    log "   nothing needs nagging right now; no message sent."
  fi
  [ "$slot" = evening ] && printf '%s\n' "$today" >"$STATE_DIR/tasks_last_evening"
  write_last_run "ok" "$(( $(epoch_now) - RUN_START ))s" 0 "$RUN_MODE" ""
  log "✅ To-do check done."
  cleanup_old_runs
  exit 0
}

# Warnings to append to a tasks message (or the brief's footer): read-state tripwire, Outlook failure.
tasks_footer() {
  if [ "$TASKS_READSTATE" = unsafe ]; then
    printf '\n⚠️ Outlook marked a message as read when it was opened, so no more mail was opened. In Outlook: Settings → Mail → Message handling → "Don'\''t automatically mark items as read".\n'
  fi
  # Outlook read, but not as far back as asked (e.g. the list wouldn't page): say so.
  if [ "$TASKS_OUTLOOK" = ok ] && [ -n "$TASKS_SINCE" ] && { [ -z "$TASKS_OLDEST" ] || [[ "$TASKS_OLDEST" > "$TASKS_SINCE" ]]; }; then
    printf '\n📭 Only checked mail back to %s (wanted %s); older mail is picked up next run.\n' "${TASKS_OLDEST:-the newest rows}" "$TASKS_SINCE"
  fi
  if [ "$TASKS_OUTLOOK" = fail ]; then
    printf '\n⚠️ Couldn'\''t read Outlook this time (Chrome or sign-in?). Notion reminders still work.\n'
  fi
}

tasks_print_status() {
  say "${C_BOLD}To-dos & exams${C_OFF}"
  if ! tasks_configured; then say "  Not set up (TASKS_ENABLED / NOTION_TASKS_DS / NOTION_EXAMS_DS in config.env)."; return 0; fi
  if [ -f "$TASKS_STATUS_FILE" ]; then
    say "  Last sync:     $(tasks_status_get time) ($(tasks_status_get slot)$([ "$(tasks_status_get dry)" = 1 ] && echo ', dry run'))"
    say "  Outlook:       $(tasks_status_get outlook), read state: $(tasks_status_get readstate)"
    say "  Last created:  $(tasks_status_get created) rows · open tasks: $(tasks_status_get open) · exams: $(tasks_status_get exams)"
  else
    say "  Last sync:     never"
  fi
  say "  Evening check: $(cat "$STATE_DIR/tasks_last_evening" 2>/dev/null || echo never) (daily from $(printf '%02d:00' "$((10#${TASKS_EVENING_HOUR:-19}))"))"
  say "  Bot rows:      $(grep -c . "$TASKS_LEDGER" 2>/dev/null || echo 0) Notion pages created by the bot"
  if [ -s "$TASKS_SNAPSHOT" ]; then
    say "  Snapshot ($(cat "$TASKS_SNAPSHOT_AT" 2>/dev/null)):"
    awk -F'\t' '{ printf "    %-5s %-16s %s%s\n", $1, ($4 == "" ? "-" : $4), $3, ($6 == "bot" ? "  [bot]" : "") }' "$TASKS_SNAPSHOT"
  fi
}
