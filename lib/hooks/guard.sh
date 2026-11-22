#!/bin/bash
# Tool-call guard for the tasks run (Outlook → Notion). Claude Code runs this as a hook, outside
# the model's control:
#   guard.sh pre  <guard_dir>   (PreToolUse, every tool):  exit 2 + stderr message = blocked
#   guard.sh post <guard_dir>   (PostToolUse, MCP tools):  records what the bot saw/created; never blocks
#
# <guard_dir> sits NEXT TO the run dir (runs/<ts>.guard), outside the area Claude can write, so a
# malicious email can't edit the guard's state. It holds:
#   guard.conf         RUN_DIR, LEDGER (bot-created Notion pages), DS_IDS, CHROME_DEVICE, DRY
#   clickable.tsv      tab, ref, unread(0/1), clicked(0/1): Outlook message-list rows seen via read_page
#   pending_check      set after clicking an unread message, until the list is re-read
#   readstate_unsafe   tripwire: a clicked message flipped from Unread to read → no more clicks
#   created_pages.txt  Notion page ids created in this run
#   blocked.log        every blocked call (for the run log)
#
# Rules (the tool allow/deny lists in lib/tasks.sh are the first layer; this is the second):
#   - Only an explicit set of tools may run at all.
#   - Read/Write/Edit: only inside the run dir.
#   - Chrome navigate: only the Outlook inbox URL itself (no compose/deeplink/options/login, no query).
#   - Chrome computer: only left_click by ref on a message-list row seen via read_page; no
#     coordinates, modifiers, typing or keys. So Reply/Forward/New mail/Send can never be pressed.
#   - select_browser: only this Mac's Chrome.
#   - Notion create: only into the Tasks/Exams data sources. Notion update: only update_properties on
#     pages the bot created itself. Dry runs: no Notion writes at all.

mode="${1:-}"; gdir="${2:-}"
[ -n "$gdir" ] && [ -d "$gdir" ] || { echo "guard: missing guard dir" >&2; [ "$mode" = pre ] && exit 2; exit 0; }

GUARD_MODE="$mode" GUARD_DIR="$gdir" exec perl -CS -MJSON::PP -e '
use strict; use warnings;
my $mode = $ENV{GUARD_MODE}; my $g = $ENV{GUARD_DIR};
my %c;
if (open my $f, "<", "$g/guard.conf") { while (<$f>) { chomp; $c{$1} = $2 if /^(\w+)=(.*)$/ } }
my $raw = do { local $/; <STDIN> } // "";
my $in = eval { JSON::PP->new->utf8(0)->decode($raw) } || {};
my $tool = $in->{tool_name} // "";
my $ti = ref $in->{tool_input} eq "HASH" ? $in->{tool_input} : {};

sub slurp_lines { my $p = shift; open my $h, "<", $p or return (); my @l = map { chomp; $_ } <$h>; @l }
sub append { my ($p, @l) = @_; open my $h, ">>", $p or return; print $h "$_\n" for @l }
sub norm_id {   # last UUID-ish id in a string → 32 lowercase hex
  my $s = lc(shift // ""); my @m = $s =~ /([0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12})/g;
  return "" unless @m; (my $x = $m[-1]) =~ s/-//g; $x }
sub block { my $why = shift; append("$g/blocked.log", "$tool\t$why"); print STDERR "Blocked by Morning Brief guard: $why\n"; exit 2 }
sub allow { exit 0 }
sub resp_text {  # tool_response may be a string, a list of content blocks, or an object
  my $r = $in->{tool_response};
  return $r if !ref $r;
  if (ref $r eq "ARRAY") { return join "\n", map { ref $_ eq "HASH" ? ($_->{text} // "") : (ref $_ ? "" : $_) } @$r }
  if (ref $r eq "HASH") { return $r->{text} if defined $r->{text}; return join "\n", map { resp_text_inner($_) } @{ $r->{content} || [] } if $r->{content}; return JSON::PP->new->encode($r) }
  return "";
}
sub resp_text_inner { my $b = shift; ref $b eq "HASH" ? ($b->{text} // "") : "" }

my $C = "mcp__claude-in-chrome__"; my $N = "mcp__claude_ai_Notion__";
my %ds = map { norm_id($_) => 1 } grep { length } split /\s+/, ($c{DS_IDS} // "");
my $rundir = $c{RUN_DIR} // "";

# ---------------------------------------------------------------- PostToolUse
if ($mode eq "post") {
  my $text = resp_text();
  if ($tool eq "${C}read_page") {
    # Record option rows inside the Outlook "Message list" listbox, and run the read-state tripwire.
    my $tab = $ti->{tabId} // "";
    my %rows; my @order;
    for (slurp_lines("$g/clickable.tsv")) { my @f = split /\t/; next unless @f >= 4; my $k = "$f[0]\t$f[1]"; push @order, $k unless $rows{$k}; $rows{$k} = [@f] }
    my $lb_indent; my $tripped = 0; my $seen_list = 0;
    for my $line (split /\n/, $text) {
      my ($ind) = $line =~ /^(\s*)/; my $n = length $ind;
      if ($line =~ /^\s*listbox "Message list/) { $lb_indent = $n; $seen_list = 1; next }
      next unless defined $lb_indent;
      if ($n <= $lb_indent) { undef $lb_indent; next }
      next unless $line =~ /^\s*option "(.*)" \[(ref_\d+)\]/;
      my ($label, $ref) = ($1, $2);
      my $unread = (substr($label, 0, 40) =~ /\bUnread\b/) ? 1 : 0;
      my $k = "$tab\t$ref";
      if (my $r = $rows{$k}) {
        if ($r->[3] eq "1" && $r->[2] eq "1" && !$unread) { $tripped = 1 }
        $r->[2] = $unread if $r->[3] ne "1";
      } else { $rows{$k} = [$tab, $ref, $unread, 0]; push @order, $k }
    }
    if (open my $o, ">", "$g/clickable.tsv") { print $o join("\t", @{ $rows{$_} }), "\n" for @order }
    if ($tripped) { append("$g/readstate_unsafe", "a clicked message lost its Unread mark") }
    unlink "$g/pending_check" if $seen_list;
  } elsif ($tool eq "${N}notion-create-pages") {
    my %skip = %ds;
    my @ids = grep { length && !$skip{$_} } map { norm_id($_) } ($text =~ /([0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12})/gi);
    my %u; append("$g/created_pages.txt", grep { !$u{$_}++ } @ids) if @ids;
  }
  exit 0;
}

# ---------------------------------------------------------------- PreToolUse
my %plain = map { $_ => 1 } qw(TodoWrite ToolSearch);
my %chrome_ro = map { ("$C$_" => 1) } qw(list_connected_browsers tabs_context_mcp tabs_create_mcp tabs_close_mcp get_page_text read_page find);
my %notion_ro = map { ("$N$_" => 1) } qw(notion-search notion-fetch notion-query-data-sources);

allow() if $plain{$tool} || $chrome_ro{$tool} || $notion_ro{$tool};

if ($tool =~ /^(Read|Write|Edit)$/) {
  my $p = $ti->{file_path} // "";
  block("file access outside the run dir ($p)") unless length $rundir && index($p, "$rundir/") == 0 && $p !~ m{/\.\./};
  allow();
}

if ($tool eq "${C}select_browser") {
  my $want = $c{CHROME_DEVICE} // "";
  block("only this Mac\x27s browser may be selected") unless length $want && ($ti->{deviceId} // "") eq $want;
  allow();
}

if ($tool eq "${C}navigate") {
  my $u = $ti->{url} // "";
  block("navigation is limited to the Outlook inbox (got: " . substr($u, 0, 120) . ")")
    unless $u =~ m{^https://(?:outlook\.office\.com|outlook\.office365\.com|outlook\.cloud\.microsoft)/mail/?(?:0/)?(?:inbox/?)?$};
  # A new page means new element refs: forget this tab\x27s clickable rows.
  my $tab = $ti->{tabId};
  my @keep = defined $tab ? grep { (split /\t/)[0] ne $tab } slurp_lines("$g/clickable.tsv") : ();
  if (open my $o, ">", "$g/clickable.tsv") { print $o "$_\n" for @keep }
  unlink "$g/pending_check";
  allow();
}

if ($tool eq "${C}computer") {
  my $a = $ti->{action} // "";
  # Scrolling the message list (Outlook only renders the visible rows) changes nothing.
  if ($a eq "scroll") {
    block("scroll needs a direction up/down") unless ($ti->{scroll_direction} // "") =~ /^(up|down)$/;
    block("no modifier keys") if defined $ti->{modifiers} && length $ti->{modifiers};
    allow();
  }
  block("read-state tripwire fired earlier in this run; no more clicks") if -e "$g/readstate_unsafe";
  block("only left_click on an inbox message is allowed (action: $a)") unless $a eq "left_click";
  block("clicks must use a ref, not coordinates") if defined $ti->{coordinate} || defined $ti->{start_coordinate};
  block("no modifier keys") if defined $ti->{modifiers} && length $ti->{modifiers};
  block("no text with a click") if defined $ti->{text} && length $ti->{text};
  my $ref = $ti->{ref} // ""; my $tab = $ti->{tabId} // "";
  block("re-read the message list with read_page before opening another message") if -e "$g/pending_check";
  my @rows = slurp_lines("$g/clickable.tsv"); my $hit;
  for (@rows) { my @f = split /\t/; if ($f[0] eq $tab && $f[1] eq $ref) { $hit = \@f; last } }
  block("$ref is not a message in the inbox list (read the list with read_page first)") unless $hit;
  # Mark clicked; if it was unread, require a list re-read before the next click (tripwire check).
  if (open my $o, ">", "$g/clickable.tsv") {
    for (@rows) { my @f = split /\t/; $f[3] = 1 if $f[0] eq $tab && $f[1] eq $ref; print $o join("\t", @f), "\n" }
  }
  append("$g/pending_check", $ref) if $hit->[2] eq "1";
  allow();
}

if ($tool eq "${N}notion-create-pages") {
  block("dry run: no Notion writes") if ($c{DRY} // "0") eq "1";
  my $p = $ti->{parent};
  block("pages may only be created in the Tasks or Exams database") unless ref $p eq "HASH" && defined $p->{data_source_id} && $ds{ norm_id($p->{data_source_id}) };
  block("no templates") if grep { ref $_ eq "HASH" && defined $_->{template_id} } @{ $ti->{pages} || [] };
  block("no draft/skill pages") if defined $ti->{creation_mode} || grep { ref $_ eq "HASH" && $_->{is_skill} } @{ $ti->{pages} || [] };
  allow();
}

if ($tool eq "${N}notion-update-page") {
  block("dry run: no Notion writes") if ($c{DRY} // "0") eq "1";
  block("only update_properties is allowed") unless ($ti->{command} // "") eq "update_properties";
  block("no skill/verification changes") if defined $ti->{is_skill} || defined $ti->{verification_status};
  my $id = norm_id($ti->{page_id});
  my %mine = map { $_ => 1 } grep { length } (slurp_lines($c{LEDGER} // "/nonexistent"), slurp_lines("$g/created_pages.txt"));
  block("page $id was not created by the bot; it may not be edited") unless length $id && $mine{$id};
  allow();
}

block("tool not permitted in the tasks run");
' <&0
