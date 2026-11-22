# shellcheck shell=bash
# Source health: learn which websites keep failing and stop asking the research run to fetch them.
#
# Each run, Claude writes sources.tsv in its run dir: domain <TAB> ok|fail <TAB> short reason.
# "ok" means the page was read (even if nothing relevant was on it); "fail" means it could not be
# read (blocked, 403, cookie/login wall, timeout, error).
#
# state/source_health.tsv: domain, fail_days_in_a_row, last_fail_date, last_ok_date, blocked_until,
#                          strikes, last_reason
# - a failure counts once per day (two runs on the same day don't double-count);
# - SOURCE_FAIL_DAYS failing days in a row → blocked: 14 days the first time, 30 days after that;
# - when a block expires the site is tried once more; one more failure re-blocks it straight away;
# - any successful read resets everything.
# Blocked sites are listed in the prompt ("do not fetch"), and `./brief sources` shows the table.

SOURCE_HEALTH_FILE="$STATE_DIR/source_health.tsv"

# sources_update <run_dir> <today>: fold this run's sources.tsv into the health file.
# Writes <run_dir>/newly_blocked.tsv (domain, blocked_until, reason) for sites blocked by this run.
sources_update() {
  local run_dir="$1" today="$2" tmp
  : >"$run_dir/newly_blocked.tsv"
  [ -s "$run_dir/sources.tsv" ] || return 0
  mkdir -p "$STATE_DIR"; [ -f "$SOURCE_HEALTH_FILE" ] || : >"$SOURCE_HEALTH_FILE"
  tmp="$(mktemp "$SOURCE_HEALTH_FILE.XXXXXX")"
  TODAY="$today" FAILDAYS="${SOURCE_FAIL_DAYS:-3}" NEWB="$run_dir/newly_blocked.tsv" \
  perl -CSD -MPOSIX -e '
    use strict; use warnings;
    sub plus { my ($iso, $n) = @_; my ($y,$m,$d) = $iso =~ /^(\d{4})-(\d\d)-(\d\d)$/;
               POSIX::strftime("%Y-%m-%d", localtime(POSIX::mktime(0,0,12,$d+$n,$m-1,$y-1900))) }
    sub dom { my $s = lc shift; $s =~ s/^\s+|\s+$//g; $s =~ s{^[a-z]+://}{}; $s =~ s{[/?#:].*$}{}; $s =~ s/^www\.//; $s }
    my ($health, $run) = @ARGV; my $today = $ENV{TODAY};
    my (%h, @order);
    open my $H, "<:encoding(UTF-8)", $health or die;
    while (<$H>) { chomp; my @f = split /\t/, $_, -1; next unless $f[0]; $f[$_] //= "" for 0..6;
                   $f[1] ||= 0; $f[5] ||= 0; $h{$f[0]} = [@f]; push @order, $f[0] }
    close $H;
    # This run: a domain counts as ok if any of its pages read fine.
    my (%st, %why, @seen);
    open my $R, "<:encoding(UTF-8)", $run or die;
    while (<$R>) { s/\r//g; chomp; my ($d, $s, $r) = split /\t/, $_, 3; next unless defined $s;
                   $d = dom($d); $s = lc $s; $s =~ s/\s//g; next unless $d =~ /\./ && $s =~ /^(ok|fail)$/;
                   next if $s eq "fail" && ($r // "") =~ /not (opened|tried|read|fetched|attempted)|skipp|only search|didn.?t (open|try|fetch)/i;   # never tried: not a failure
                   push @seen, $d unless exists $st{$d};
                   $st{$d} = "ok" if $s eq "ok"; $st{$d} //= "fail";
                   ($r //= "") =~ s/[\t\n]/ /g; $why{$d} = substr($r, 0, 80) if $s eq "fail" && !$why{$d} }
    close $R;
    open my $N, ">>:encoding(UTF-8)", $ENV{NEWB} or die;
    for my $d (@seen) {
      unless ($h{$d}) { $h{$d} = [$d, 0, "", "", "", 0, ""]; push @order, $d }
      my $r = $h{$d};
      if ($st{$d} eq "ok") { @$r[1,3,4,5] = (0, $today, "", 0); next }
      next if $r->[2] eq $today;                          # already counted today
      $r->[1]++; $r->[2] = $today; $r->[6] = $why{$d} // "";
      my $blocked = $r->[4] ne "" && $r->[4] gt $today;
      if ($r->[1] >= $ENV{FAILDAYS} && !$blocked) {
        $r->[4] = plus($today, $r->[5] ? 30 : 14); $r->[5]++;
        print $N join("\t", $d, $r->[4], $r->[6]), "\n";
      }
    }
    for my $d (@order) { print join("\t", @{ $h{$d} }), "\n" }
  ' "$SOURCE_HEALTH_FILE" "$run_dir/sources.tsv" >"$tmp" && mv "$tmp" "$SOURCE_HEALTH_FILE" || rm -f "$tmp"
}

# Domains blocked as of <today>: domain <TAB> blocked_until <TAB> reason
sources_blocked() {
  [ -s "$SOURCE_HEALTH_FILE" ] || return 0
  awk -F'\t' -v OFS='\t' -v t="$1" '$5 != "" && $5 > t { print $1, $5, $7 }' "$SOURCE_HEALTH_FILE"
}

# Prompt fragment for {{BLOCKED_SOURCES}}.
sources_blocked_note() {
  local rows d until why out=""
  rows="$(sources_blocked "$1")"
  if [ -z "$rows" ]; then
    printf '%s\n' "# Sites to skip
None right now."
    return
  fi
  while IFS="$TAB" read -r d until why; do
    [ -n "$d" ] || continue
    out="$out- $d${why:+ ($why)}
"
  done <<EOF
$rows
EOF
  printf '%s\n' "# Sites to skip
These sites have failed to load on several recent days. Do NOT fetch or open them in this run (not with
WebFetch, not in Chrome), even if sources.md lists them. Use the section's other sources or WebSearch
instead, and don't mention them in notes.txt or sources.tsv.
$out"
}

# Footer lines for sites this run just blocked.
sources_footer_lines() {
  local f="$1" d until why
  [ -s "$f" ] || return 0
  while IFS="$TAB" read -r d until why; do
    [ -n "$d" ] || continue
    printf '🚫 Stopped using %s for now (failed %s days running; will retry %s)\n' "$d" "${SOURCE_FAIL_DAYS:-3}" "$(date_pretty "$until")"
  done <"$f"
}

# ./brief sources [--reset <domain>]
cmd_sources() {
  local today d
  today="$(today_iso)"
  if [ "${1:-}" = "--reset" ]; then
    d="${2:-}"; [ -n "$d" ] || die "Usage: ./brief sources --reset <domain>"
    d="$(printf '%s' "$d" | tr 'A-Z' 'a-z' | sed -E 's#^[a-z]+://##; s#[/?:].*$##; s#^www\.##')"
    [ -s "$SOURCE_HEALTH_FILE" ] && grep -q "^$d$TAB" "$SOURCE_HEALTH_FILE" || die "No record for $d."
    grep -v "^$d$TAB" "$SOURCE_HEALTH_FILE" >"$SOURCE_HEALTH_FILE.tmp"; mv "$SOURCE_HEALTH_FILE.tmp" "$SOURCE_HEALTH_FILE"
    say "${C_GRN}✅ $d reset: it will be fetched again from the next run.${C_OFF}"
    return 0
  fi
  [ -n "${1:-}" ] && die "Usage: ./brief sources [--reset <domain>]"
  if [ ! -s "$SOURCE_HEALTH_FILE" ]; then
    say "No source history yet (it builds up as runs happen)."
    return 0
  fi
  say "${C_BOLD}Website health${C_OFF} (a site is skipped after ${SOURCE_FAIL_DAYS:-3} failing days in a row)"
  say ""
  awk -F'\t' -v t="$today" '
    { if ($5 != "" && $5 > t) { st = "🚫 skipped until " $5; k = 0 }
      else if ($2 > 0)        { st = "⚠️  failing " $2 " day" ($2 == 1 ? "" : "s") " in a row"; k = 1 }
      else                    { st = "✅ ok"; k = 2 }
      printf "%d\t%s\t  %-26s %-34s %s\n", k, $1, $1, st, (k < 2) ? $7 : "last ok " $4 }' "$SOURCE_HEALTH_FILE" | sort -t "$TAB" -k1,1n -k2,2 | cut -f3-
  say ""
  say "${C_DIM}Bring a site back now: ./brief sources --reset <domain>${C_OFF}"
}
