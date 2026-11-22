# shellcheck shell=bash
# Telegram Bot API: plain-text sendMessage with splitting, retries, 429 handling.
# The bot token is passed to curl through a config on stdin (-K -), so it never
# appears in `ps` output, argv or logs.

TG_API_BASE="${TG_API_BASE:-https://api.telegram.org}"
CURL_BIN="${CURL_BIN:-curl}"
TG_MAX_BYTES="${TG_MAX_BYTES:-3800}"   # Telegram limit is 4096 chars; bytes overestimate, so this is safe.
TG_RETRIES=3
TG_HTTP=""

# Sleep, unless tests asked us not to (they record the requested delay instead).
tg_sleep() {
  if [ "${TG_NO_SLEEP:-}" = "1" ]; then
    [ -n "${TG_SLEEP_LOG:-}" ] && echo "sleep $1" >>"$TG_SLEEP_LOG"
    return 0
  fi
  sleep "$1"
}

# tg_call <method> [curl args...]: sets TG_BODY (response) and TG_HTTP (status code).
# Must not be called inside $(...) or the globals are lost.
tg_call() {
  local method="$1"; shift
  local out code
  out="$(mktemp -t mbtg)"
  code="$(printf 'url = "%s/bot%s/%s"\n' "$TG_API_BASE" "$TELEGRAM_BOT_TOKEN" "$method" |
    "$CURL_BIN" -K - -sS --max-time 30 -o "$out" -w '%{http_code}' "$@" 2> >(redact >&2))" || true
  TG_HTTP="${code:-000}"
  TG_BODY="$(cat "$out" 2>/dev/null)"
  rm -f "$out"
}

tg_is_ok()         { grep -q '"ok"[[:space:]]*:[[:space:]]*true'; }
tg_description()   { perl -ne 'print $1 if /"description"\s*:\s*"((?:[^"\\]|\\.)*)"/'; }
tg_retry_after()   { perl -ne 'print $1 if /"retry_after"\s*:\s*(\d+)/'; }

# Split a UTF-8 text file into chunks of at most TG_MAX_BYTES bytes, on line boundaries.
# A single line that is too long is hard-split on character (not byte) boundaries.
# Usage: tg_split <file> <outdir>   → writes outdir/chunk-001.txt ...; prints the count.
tg_split() {
  local file="$1" outdir="$2"
  mkdir -p "$outdir"
  MAX="$TG_MAX_BYTES" OUTDIR="$outdir" perl -CSD -e '
    use strict; use warnings; use Encode qw(encode_utf8);
    my $max = $ENV{MAX}; my $dir = $ENV{OUTDIR};
    my @chunks; my $cur = ""; my $curb = 0;
    my $flush = sub { if ($cur =~ /\S/) { $cur =~ s/\n+\z/\n/; push @chunks, $cur; } $cur = ""; $curb = 0; };
    local $/ = undef; my $text = <STDIN>; $text = "" unless defined $text;
    my @lines = split /(?<=\n)/, $text;
    for my $line (@lines) {
      my $lb = length encode_utf8($line);
      if ($lb > $max) {
        $flush->();
        my $piece = ""; my $pb = 0;
        for my $ch (split //, $line) {
          my $cb = length encode_utf8($ch);
          if ($pb + $cb > $max) { push @chunks, $piece; $piece = ""; $pb = 0; }
          $piece .= $ch; $pb += $cb;
        }
        ($cur, $curb) = ($piece, $pb);
        next;
      }
      $flush->() if $curb + $lb > $max;
      # Avoid starting a chunk with blank lines.
      next if $curb == 0 && $line =~ /^\s*$/;
      $cur .= $line; $curb += $lb;
    }
    $flush->();
    my $i = 0;
    for my $c (@chunks) {
      $i++;
      open my $fh, ">", sprintf("%s/chunk-%03d.txt", $dir, $i) or die $!;
      print $fh $c; close $fh;
    }
    print scalar(@chunks), "\n";
  ' <"$file"
}

# Send one chunk file. $2 = 1 for silent (no notification sound).
tg_send_chunk() {
  local file="$1" silent="${2:-1}" attempt=1 body ra desc
  while [ "$attempt" -le "$TG_RETRIES" ]; do
    tg_call sendMessage \
      --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
      --data-urlencode "text@$file" \
      --data-urlencode 'link_preview_options={"is_disabled":true}' \
      --data-urlencode "disable_notification=$([ "$silent" = 1 ] && echo true || echo false)"
    body="$TG_BODY"
    if printf '%s' "$body" | tg_is_ok; then
      return 0
    fi
    desc="$(printf '%s' "$body" | tg_description)"
    log_only "Telegram sendMessage failed (HTTP $TG_HTTP, attempt $attempt/$TG_RETRIES): ${desc:-no response}"
    case "$TG_HTTP" in
      429)
        ra="$(printf '%s' "$body" | tg_retry_after)"
        tg_sleep "$(( ${ra:-5} + 1 ))"
        ;;
      400|401|403|404)
        # Not retryable: bad token, bad chat id, bot blocked, malformed request.
        TG_LAST_ERROR="HTTP $TG_HTTP: ${desc:-request rejected}"
        return 1
        ;;
      *)
        tg_sleep "$(( attempt * 3 ))"
        ;;
    esac
    attempt=$(( attempt + 1 ))
  done
  TG_LAST_ERROR="HTTP $TG_HTTP after $TG_RETRIES attempts: ${desc:-no response}"
  return 1
}

# Send a whole text file (split as needed). $2 = 1 silent, 0 with sound.
# Only the first chunk of a non-silent message makes a sound.
tg_send_file() {
  local file="$1" silent="${2:-1}" tmp n i s
  [ -s "$file" ] || return 0
  tmp="$(mktemp -d -t mbsplit)"
  n="$(tg_split "$file" "$tmp")"
  i=1
  while [ "$i" -le "$n" ]; do
    s="$silent"; [ "$i" -gt 1 ] && s=1
    if ! tg_send_chunk "$(printf '%s/chunk-%03d.txt' "$tmp" "$i")" "$s"; then
      rm -rf "$tmp"
      return 1
    fi
    [ "$i" -lt "$n" ] && tg_sleep 1
    i=$(( i + 1 ))
  done
  rm -rf "$tmp"
  return 0
}

# Send a literal string.
tg_send_text() {
  local tmp rc
  tmp="$(mktemp -t mbtext)"
  printf '%s\n' "$1" >"$tmp"
  tg_send_file "$tmp" "${2:-1}"; rc=$?
  rm -f "$tmp"
  return $rc
}

# getMe: verifies the token without sending anything. Sets TG_BOT_NAME on success.
tg_getme() {
  local body
  tg_call getMe; body="$TG_BODY"
  if printf '%s' "$body" | tg_is_ok; then
    TG_BOT_NAME="$(printf '%s' "$body" | perl -ne 'print "\@$1" if /"username"\s*:\s*"([^"]+)"/')"
    return 0
  fi
  TG_LAST_ERROR="HTTP $TG_HTTP: $(printf '%s' "$body" | tg_description)"
  return 1
}

cmd_test_telegram() {
  require_telegram_config
  tg_getme || die "Bot token rejected (${TG_LAST_ERROR}). Check TELEGRAM_BOT_TOKEN in config.env."
  if tg_send_text "✅ Morning Brief bot is connected" 0; then
    say "${C_GRN}✅ Sent a test message via $TG_BOT_NAME to chat $TELEGRAM_CHAT_ID. Check Telegram.${C_OFF}"
  else
    die "Send failed: ${TG_LAST_ERROR}. If it's 'chat not found', message your bot first and re-run ./brief chat-id."
  fi
}

cmd_chat_id() {
  config_exists || die "config.env not found. Run: cp config.env.example config.env && chmod 600 config.env"
  [ -n "$TELEGRAM_BOT_TOKEN" ] || die "Put your bot token in config.env first (TELEGRAM_BOT_TOKEN=...)."
  local body found
  tg_call getUpdates; body="$TG_BODY"
  printf '%s' "$body" | tg_is_ok || die "getUpdates failed (HTTP $TG_HTTP: $(printf '%s' "$body" | tg_description)). Check the token."
  found="$(printf '%s' "$body" | perl -MJSON::PP -e '
    local $/; my $d = eval { decode_json(<STDIN>) } or exit 0; my %seen;
    for my $u (@{ $d->{result} || [] }) {
      for my $k (qw(message edited_message channel_post my_chat_member)) {
        my $c = $u->{$k} && $u->{$k}{chat} or next;
        next if $seen{$c->{id}}++;
        my $name = $c->{title} // join(" ", grep defined, $c->{first_name}, $c->{last_name});
        $name .= " (\@$c->{username})" if $c->{username};
        printf "%s\t%s\t%s\n", $c->{id}, $c->{type}, $name;
      }
    }')"
  if [ -z "$found" ]; then
    say "No chats found yet."
    say "→ Open your bot in Telegram, send it any message (e.g. \"hi\"), then run ./brief chat-id again."
    return 1
  fi
  say "Chats that messaged your bot:"
  printf '%s\n' "$found" | while IFS="$(printf '\t')" read -r id type name; do
    say "  chat id: ${C_BOLD}$id${C_OFF}   ($type: $name)"
  done
  say ""
  say "Put yours in config.env:  TELEGRAM_CHAT_ID=\"<chat id>\""
}
