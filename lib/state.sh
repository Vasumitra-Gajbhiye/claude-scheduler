# shellcheck shell=bash
# State: run lock, seen.tsv memory, item rules, reminders, archive, last_* markers.

TAB="$(printf '\t')"

# ---- lock (mkdir is atomic). Stale if older than 2*MAX_SECONDS or its owner is gone.
LOCK_OWNED=0
lock_acquire() {
  mkdir -p "$STATE_DIR"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" >"$LOCK_DIR/pid"; LOCK_OWNED=1; return 0
  fi
  local pid age mtime
  pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  mtime="$(stat -f %m "$LOCK_DIR" 2>/dev/null || echo 0)"
  age=$(( $(epoch_now) - mtime ))
  if [ "$age" -gt $(( 2 * MAX_SECONDS )) ] || { [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; }; then
    log_only "Removing stale lock (pid ${pid:-?}, age ${age}s)"
    rm -rf "$LOCK_DIR"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      echo "$$" >"$LOCK_DIR/pid"; LOCK_OWNED=1; return 0
    fi
  fi
  LOCK_HOLDER="${pid:-unknown}"
  return 1
}
lock_release() {
  if [ "$LOCK_OWNED" = 1 ]; then rm -rf "$LOCK_DIR"; LOCK_OWNED=0; fi
}

# ---- seen.tsv: date_sent, type, deadline, title, url, event_date, mode, details
# (rows written before v3 have only the first 5 columns; every reader treats the rest as empty)
seen_init() { mkdir -p "$STATE_DIR"; [ -f "$SEEN_FILE" ] || : >"$SEEN_FILE"; }

# Drop rows older than the retention window unless their deadline or event date is still ahead.
# Usage: seen_prune <today> <retention_days>   (prints the number of rows dropped)
seen_prune() {
  local today="$1" days="$2" cutoff tmp before after
  seen_init
  cutoff="$(date_add_days "$today" "-$days")"
  tmp="$(mktemp "$SEEN_FILE.XXXXXX")"
  awk -F'\t' -v OFS='\t' -v cutoff="$cutoff" -v today="$today" '
    NF < 5 { next }
    $1 < cutoff && ($3 == "" || $3 < today) && ($6 == "" || $6 < today) { next }
    { print }' "$SEEN_FILE" >"$tmp"
  before="$(wc -l <"$SEEN_FILE" | tr -d ' ')"; after="$(wc -l <"$tmp" | tr -d ' ')"
  mv "$tmp" "$SEEN_FILE"
  reminders_prune
  echo $(( before - after ))
}

# Normalise Claude's items.tsv into 7 fields:
#   type, deadline, title, url, event_date, mode (online|bangalore|""), details
# and enforce the rules deterministically (in case the model didn't):
#   - events/competitions/hackathons: drop if the deadline or event date is past, if the earliest
#     upcoming date is more than HORIZON_DAYS away, if the mode is a city other than Bangalore, or if
#     it's offline in Bangalore on a Monday-Thursday;
#   - internships: drop if the deadline is past.
# URLs of dropped rows go to <out>.dropped (with the reason), so their text can be removed too.
# Usage: items_clean <in> <out> [today]
items_clean() {
  local today="${3:-$(today_iso)}"
  : >"$2.dropped"
  [ -f "$1" ] || { : >"$2"; return 0; }
  tr -d '\r' <"$1" | TODAY="$today" HORIZON="${HORIZON_DAYS:-90}" DROPPED="$2.dropped" perl -CSD -MPOSIX -ne '
    BEGIN {
      sub dnum { my ($y,$m,$d) = $_[0] =~ /^(\d{4})-(\d\d)-(\d\d)$/ or return undef;
                 my $t = POSIX::mktime(0,0,12,$d,$m-1,$y-1900); defined $t ? int(($t + 43200) / 86400) : undef }
      sub wday { my ($y,$m,$d) = $_[0] =~ /^(\d{4})-(\d\d)-(\d\d)$/; (localtime(POSIX::mktime(0,0,12,$d,$m-1,$y-1900)))[6] }
      $today = dnum($ENV{TODAY}); $max = $today + $ENV{HORIZON};
      open D, ">>", $ENV{DROPPED} or die;
    }
    chomp; my @f = split /\t/, $_, -1; next if @f < 4;
    s/^\s+|\s+$//g for @f;
    my ($t, $dl, $title, $u, $ev, $mode, $det) = (lc $f[0], @f[1..3], $f[4] // "", lc($f[5] // ""), $f[6] // "");
    $t = "competition" if $t eq "competitions"; $t = "event" if $t eq "events";
    next unless $t =~ /^(news|world|tech|event|competition|hackathon|internship)$/;
    next unless $u =~ m{^https?://\S+$};
    $dl = "" unless defined dnum($dl);
    $ev = "" unless defined dnum($ev);
    if    ($mode eq "")                                             { }
    elsif ($mode =~ /online|remote|virtual|hybrid/)                 { $mode = "online" }
    elsif ($mode =~ /bangalore|bengaluru|blr|offline|in.person/)    { $mode = "bangalore" }
    else                                                            { $mode = "other" }
    my $why = "";
    if ($t =~ /^(event|competition|hackathon)$/) {
      my @up = grep { $_ ne "" && dnum($_) >= $today } ($dl, $ev);
      if    ($dl ne "" && dnum($dl) < $today)                     { $why = "deadline passed" }
      elsif ($ev ne "" && dnum($ev) < $today)                     { $why = "already happened" }
      elsif (@up && (sort { $a <=> $b } map { dnum($_) } @up)[0] > $max) { $why = "more than $ENV{HORIZON} days away" }
      elsif ($mode eq "other")                                    { $why = "offline outside Bangalore" }
      elsif ($mode eq "bangalore" && $ev ne "" && wday($ev) >= 1 && wday($ev) <= 4) { $why = "offline on a weekday" }
    } elsif ($t eq "internship") {
      $why = "deadline passed" if $dl ne "" && dnum($dl) < $today;
    }
    $mode = "" if $mode eq "other";
    if ($why) { print D "$u\t$why\t$title\n"; next }
    $title =~ s/\t/ /g; $det =~ s/\t/ /g;
    print join("\t", $t, $dl, $title, $u, $ev, $mode, $det), "\n";
  ' >"$2"
}

# Count rows of a type in a cleaned items file.
items_count() { awk -F'\t' -v t="$2" '$1 == t { n++ } END { print n + 0 }' "$1" 2>/dev/null; }

# Append a run's cleaned items to seen.tsv with the send date in front.
seen_append() {
  local items="$1" today="$2"
  seen_init
  [ -s "$items" ] || return 0
  awk -F'\t' -v OFS='\t' -v d="$today" '{ print d, $1, $2, $3, $4, $5, $6, $7 }' "$items" >>"$SEEN_FILE"
}

# ---- reminders: re-send saved events/competitions/hackathons/internships as their date approaches.
# state/reminders.tsv: url, last_reminded_date, times_reminded
# The gap between reminders shrinks as the date gets closer:
#   22+ days left → every 7 days · 8–21 → every 4 · 3–7 → every 2 · 0–2 → daily
# measured from the later of "first sent" and "last reminded". Internships only within 14 days of
# their deadline. Never on the day an item is first sent, never twice a day, never after its date.
REMINDERS_FILE="$STATE_DIR/reminders.tsv"

# reminders_due <today> <seen> <items_sent_today> <reminders_file> <out_msg> <out_urls>
# Writes the "🔔 REMINDERS" message to <out_msg> (or nothing) and the reminded URLs to <out_urls>.
reminders_due() {
  : >"$5"; : >"$6"
  [ -s "$2" ] || return 0
  TODAY="$1" SEEN="$2" ITEMS="$3" REM="$4" OUTMSG="$5" OUTURLS="$6" perl -CSD -Mutf8 -MPOSIX -e '
    use strict; use warnings;
    sub dnum { my ($y,$m,$d) = ($_[0] // "") =~ /^(\d{4})-(\d\d)-(\d\d)$/ or return undef;
               int((POSIX::mktime(0,0,12,$d,$m-1,$y-1900) + 43200) / 86400) }
    sub pretty { my ($y,$m,$d) = $_[0] =~ /^(\d{4})-(\d\d)-(\d\d)$/; my $t = POSIX::mktime(0,0,12,$d,$m-1,$y-1900);
                 POSIX::strftime("%a", localtime $t) . " " . ($d + 0) . " " . POSIX::strftime("%b", localtime $t) }
    sub gap { my $left = shift; $left >= 22 ? 7 : $left >= 8 ? 4 : $left >= 3 ? 2 : 1 }
    sub rd { my $f = shift; return () unless $f && -f $f; open my $h, "<:encoding(UTF-8)", $f or return (); my @r = map { chomp; [split /\t/, $_, -1] } <$h>; @r }
    my $today = dnum($ENV{TODAY});
    my %new = map { ($_->[3] // "") => 1 } rd($ENV{ITEMS});
    my %last = map { ($_->[0] // "") => ($_->[1] // "") } rd($ENV{REM});
    my (%item, @order);
    for my $r (rd($ENV{SEEN})) {
      my ($sent, $type, $dl, $title, $url, $ev, $mode, $det) = map { $_ // "" } @$r[0..7];
      next unless $url && $type =~ /^(event|competition|hackathon|internship)$/;
      if (my $p = $item{$url}) { $p->{sent} = $sent if $sent gt $p->{sent}; next }
      push @order, $url;
      $item{$url} = { sent => $sent, type => $type, dl => $dl, title => $title, ev => $ev, mode => $mode, det => $det };
    }
    my @due;
    for my $url (@order) {
      my $i = $item{$url};
      next if $new{$url};
      # The next date that matters: the earliest of deadline / event date that is still ahead.
      my @c = grep { defined $_->[1] && $_->[1] >= $today } (["dl", dnum($i->{dl})], ["ev", dnum($i->{ev})]);
      @c = grep { $_->[0] eq "dl" } @c if $i->{type} eq "internship";
      next unless @c;
      my ($which, $key) = @{ (sort { $a->[1] <=> $b->[1] } @c)[0] };
      my $left = $key - $today;
      next if $i->{type} eq "internship" && $left > 14;
      my $from = dnum($i->{sent}) // $today;
      my $lr = dnum($last{$url}); $from = $lr if defined $lr && $lr > $from;
      next if $from >= $today;
      next if $today - $from < gap($left);
      my $iso = $which eq "dl" ? $i->{dl} : $i->{ev};
      my $verb = $which eq "ev" ? "happens" : ($i->{type} eq "event" ? "registration closes" : "deadline");
      my $when = $left == 0 ? "today" : $left == 1 ? "tomorrow" : "in $left days";
      push @due, [$key, $i->{title}, $url, "$verb " . pretty($iso) . " ($when)", $i->{det}];
    }
    exit 0 unless @due;
    open my $m, ">:encoding(UTF-8)", $ENV{OUTMSG} or die; open my $u, ">", $ENV{OUTURLS} or die;
    print $m "🔔 REMINDERS\n";
    my $n = 0;
    for my $d (sort { $a->[0] <=> $b->[0] || $a->[1] cmp $b->[1] } @due) {
      $n++;
      print $m "\n$n. $d->[1]\n$d->[3]\n", ($d->[4] ne "" ? "$d->[4]\n" : ""), "$d->[2]\n";
      print $u "$d->[2]\n";
    }
  '
}

# reminders_record <today> <urls_file>: remember that these URLs were reminded today.
reminders_record() {
  local today="$1" urls="$2" tmp
  [ -s "$urls" ] || return 0
  mkdir -p "$STATE_DIR"; [ -f "$REMINDERS_FILE" ] || : >"$REMINDERS_FILE"
  tmp="$(mktemp "$REMINDERS_FILE.XXXXXX")"
  awk -F'\t' -v OFS='\t' -v d="$today" '
    FNR == NR { want[$1] = 1; next }
    ($1 in want) { print $1, d, $3 + 1; done[$1] = 1; next }
    { print }
    END { for (u in want) if (!(u in done)) print u, d, 1 }' "$urls" "$REMINDERS_FILE" >"$tmp"
  mv "$tmp" "$REMINDERS_FILE"
}

# Forget reminder history for URLs no longer in seen.tsv.
reminders_prune() {
  local tmp
  [ -s "$REMINDERS_FILE" ] || return 0
  tmp="$(mktemp "$REMINDERS_FILE.XXXXXX")"
  awk -F'\t' 'FNR == NR { keep[$5] = 1; next } ($1 in keep)' "$SEEN_FILE" "$REMINDERS_FILE" >"$tmp"
  mv "$tmp" "$REMINDERS_FILE"
}

# ---- archive
# Copy a run's outgoing messages to archive/YYYY-MM-DD (or -2, -3... for repeat runs). Prints the dir.
archive_run() {
  local src="$1" today="$2" dest i=2
  mkdir -p "$ARCHIVE_DIR"
  dest="$ARCHIVE_DIR/$today"
  while [ -e "$dest" ]; do dest="$ARCHIVE_DIR/$today-$i"; i=$(( i + 1 )); done
  mkdir -p "$dest"
  cp "$src"/*.txt "$dest"/ 2>/dev/null || true
  echo "$dest"
}

latest_archive() {
  # Sort by date, then numeric suffix (2026-11-22, 2026-11-22-2, ...).
  find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
    awk -F/ '{ n = $NF; rest = substr(n, 12); s = (rest == "" ? 1 : rest + 0); printf "%s\t%08d\t%s\n", substr(n, 1, 10), s, $0 }' |
    sort | tail -1 | cut -f3
}

# ---- markers
mark_success() { printf '%s\n' "$1" >"$STATE_DIR/last_success"; }
mark_failure() { printf '%s\t%s\t%s\n' "$(now_human)" "$1" "${LOG_FILE:-}" >"$STATE_DIR/last_failure"; }
# write_last_run status duration items mode reason
write_last_run() {
  mkdir -p "$STATE_DIR"
  {
    echo "time=$(now_human)"
    echo "status=$1"
    echo "duration=$2"
    echo "items=$3"
    echo "mode=$4"
    echo "reason=$5"
    echo "log=${LOG_FILE:-}"
  } >"$STATE_DIR/last_run"
}
last_run_get() { sed -n "s/^$1=//p" "$STATE_DIR/last_run" 2>/dev/null | head -1; }

cleanup_old_runs() {
  [ -d "$RUNS_DIR" ] && find "$RUNS_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null
  [ -d "$LOGS_DIR" ] && find "$LOGS_DIR" -name 'run-*.log' -mtime +60 -delete 2>/dev/null
  return 0
}
