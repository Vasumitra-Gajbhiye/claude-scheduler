# shellcheck shell=bash
# State: run lock, seen.tsv memory, closing-soon, archive, last_* markers.

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

# ---- seen.tsv: date_sent, type, deadline, title, url
seen_init() { mkdir -p "$STATE_DIR"; [ -f "$SEEN_FILE" ] || : >"$SEEN_FILE"; }

# Drop rows older than the retention window whose deadline is empty or already past.
# Usage: seen_prune <today> <retention_days>   (prints the number of rows dropped)
seen_prune() {
  local today="$1" days="$2" cutoff tmp before after
  seen_init
  cutoff="$(date_add_days "$today" "-$days")"
  tmp="$(mktemp "$SEEN_FILE.XXXXXX")"
  awk -F'\t' -v OFS='\t' -v cutoff="$cutoff" -v today="$today" '
    NF < 5 { next }
    $1 < cutoff && ($3 == "" || $3 < today) { next }
    { print }' "$SEEN_FILE" >"$tmp"
  before="$(wc -l <"$SEEN_FILE" | tr -d ' ')"; after="$(wc -l <"$tmp" | tr -d ' ')"
  mv "$tmp" "$SEEN_FILE"
  echo $(( before - after ))
}

# Normalise Claude's items.tsv: exactly 4 fields, known type, valid-or-empty deadline, URL present.
# Usage: items_clean <in> <out>
items_clean() {
  [ -f "$1" ] || { : >"$2"; return 0; }
  tr -d '\r' <"$1" | awk -F'\t' -v OFS='\t' '
    NF >= 4 {
      t = $1; d = $2; title = $3; u = $4
      gsub(/^[ \t]+|[ \t]+$/, "", t); gsub(/^[ \t]+|[ \t]+$/, "", d); gsub(/^[ \t]+|[ \t]+$/, "", u)
      if (t !~ /^(news|tech|event|competition|internship)$/) next
      if (u !~ /^https?:\/\//) next
      if (d !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) d = ""
      print t, d, title, u
    }' >"$2"
}

# Count rows of a type in a cleaned items file.
items_count() { awk -F'\t' -v t="$2" '$1 == t { n++ } END { print n + 0 }' "$1" 2>/dev/null; }

# Append a run's cleaned items to seen.tsv with the send date in front.
seen_append() {
  local items="$1" today="$2"
  seen_init
  [ -s "$items" ] || return 0
  awk -F'\t' -v OFS='\t' -v d="$today" '{ print d, $1, $2, $3, $4 }' "$items" >>"$SEEN_FILE"
}

# Build the deterministic "Closing soon" message from seen.tsv.
# Items whose deadline is today..today+N, deduped by URL, sorted by deadline.
# Usage: closing_soon <today> <days> [seen_file]   (prints the message, or nothing)
closing_soon() {
  local today="$1" days="$2" seen="${3:-$SEEN_FILE}" end rows n=0 out="" d title url kind dd when verb
  [ -s "$seen" ] || return 0
  end="$(date_add_days "$today" "+$days")"
  rows="$(awk -F'\t' -v OFS='\t' -v today="$today" -v end="$end" '
    NF >= 5 && $3 != "" && $3 >= today && $3 <= end && ($2 == "competition" || $2 == "internship" || $2 == "event") {
      if (seen[$5]++) next
      print $3, $2, $4, $5
    }' "$seen" | sort -t "$TAB" -k1,1 -k3,3)"
  [ -n "$rows" ] || return 0
  out="⏰ CLOSING SOON"
  while IFS="$TAB" read -r d kind title url; do
    [ -n "$d" ] || continue
    n=$(( n + 1 ))
    dd="$(days_between "$today" "$d")"
    case "$dd" in 0) when="today" ;; 1) when="tomorrow" ;; *) when="in $dd days" ;; esac
    if [ "$kind" = "event" ]; then verb="happens"; else verb="closes"; fi
    out="$out

$n. $title
$verb $(date_pretty "$d") ($when)
$url"
  done <<EOF
$rows
EOF
  printf '%s\n' "$out"
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
