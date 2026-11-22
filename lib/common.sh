# shellcheck shell=bash
# Common helpers: paths, config, logging, redaction, dates.
# Sourced by ./brief. Bash 3.2 compatible (macOS /bin/bash).

# ---- paths (everything relative to the repo root; BRIEF_HOME overrides data dirs for tests)
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DATA_DIR="${BRIEF_HOME:-$REPO_DIR}"
BRIEF_BIN="${BRIEF_BIN:-$REPO_DIR/brief}"
CONFIG_FILE="${BRIEF_CONFIG:-$REPO_DIR/config.env}"
PROMPTS_DIR="$REPO_DIR/prompts"
STATE_DIR="$DATA_DIR/state"
ARCHIVE_DIR="$DATA_DIR/archive"
RUNS_DIR="$DATA_DIR/runs"
LOGS_DIR="$DATA_DIR/logs"
SEEN_FILE="$STATE_DIR/seen.tsv"
LOCK_DIR="$STATE_DIR/run.lock"
LABEL="com.morningbrief.daily"
PLIST_TEMPLATE="$REPO_DIR/launchd/$LABEL.plist.template"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"

# All dates are IST regardless of the machine's zone.
BRIEF_TZ="Asia/Kolkata"

# Current run log (set by start_log). Empty means log only to the terminal.
LOG_FILE="${LOG_FILE:-}"

# ---- output
if [ -t 1 ]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_OFF=$'\033[0m'
else
  C_BOLD=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_OFF=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s\n' "$*"; log_only "INFO  $*"; }
warn() { printf '%s⚠️  %s%s\n' "$C_YEL" "$*" "$C_OFF" >&2; log_only "WARN  $*"; }
err()  { printf '%s❌ %s%s\n' "$C_RED" "$*" "$C_OFF" >&2; log_only "ERROR $*"; }
die()  { err "$*"; exit 1; }

# Replace the bot token (and anything shaped like a bot token) with <redacted>.
redact() {
  local tok="${TELEGRAM_BOT_TOKEN:-}"
  if [ -n "$tok" ]; then
    TOK="$tok" perl -pe 'BEGIN{$t=quotemeta $ENV{TOK}} s/$t/<redacted>/g; s/\b\d{6,}:[A-Za-z0-9_-]{30,}\b/<redacted>/g'
  else
    perl -pe 's/\b\d{6,}:[A-Za-z0-9_-]{30,}\b/<redacted>/g'
  fi
}

# Write a line to the run log only (never to the terminal).
log_only() {
  [ -n "$LOG_FILE" ] || return 0
  printf '%s %s\n' "$(TZ=$BRIEF_TZ date '+%Y-%m-%d %H:%M:%S')" "$*" | redact >>"$LOG_FILE"
}

# Log to file and terminal.
log() { printf '%s\n' "$*"; log_only "$*"; }

start_log() {
  mkdir -p "$LOGS_DIR"
  LOG_FILE="$LOGS_DIR/run-$(TZ=$BRIEF_TZ date '+%Y%m%d-%H%M%S').log"
  : >"$LOG_FILE"
  ln -sf "$(basename "$LOG_FILE")" "$LOGS_DIR/latest.log"
}

# ---- config
load_config() {
  # Defaults first, then the file overrides.
  TELEGRAM_BOT_TOKEN=""; TELEGRAM_CHAT_ID=""
  MODEL="sonnet"; RUN_HOUR=6; RUN_MINUTE=0; MAX_SECONDS=2400
  CLAUDE_BIN=""; SEEN_RETENTION_DAYS=120
  MAX_DAILY_ATTEMPTS=3; RETRY_MINUTES=30
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
  fi
  # Never let a config file re-introduce API credentials.
  unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
  if [ -z "$CLAUDE_BIN" ] || [ ! -x "$CLAUDE_BIN" ]; then
    CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
  fi
}

config_exists() { [ -f "$CONFIG_FILE" ]; }

require_telegram_config() {
  config_exists || die "config.env not found. Run: cp config.env.example config.env && chmod 600 config.env"
  [ -n "$TELEGRAM_BOT_TOKEN" ] || die "TELEGRAM_BOT_TOKEN is empty in config.env (get one from @BotFather)."
  [ -n "$TELEGRAM_CHAT_ID" ] || die "TELEGRAM_CHAT_ID is empty in config.env (run ./brief chat-id)."
}

# Set KEY="value" in config.env, replacing an existing line or appending.
config_set() {
  local key="$1" val="$2" tmp
  tmp="$(mktemp "${CONFIG_FILE}.XXXXXX")"
  if grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
    KEY="$key" VAL="$val" perl -pe 's/^\Q$ENV{KEY}\E=.*/$ENV{KEY}="$ENV{VAL}"/' "$CONFIG_FILE" >"$tmp"
  else
    cat "$CONFIG_FILE" >"$tmp"
    printf '%s="%s"\n' "$key" "$val" >>"$tmp"
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$CONFIG_FILE"
}

# ---- dates (BSD date; all IST)
today_iso()      { TZ=$BRIEF_TZ date '+%Y-%m-%d'; }
now_human()      { TZ=$BRIEF_TZ date '+%Y-%m-%d %H:%M:%S IST'; }
date_add_days()  { TZ=$BRIEF_TZ date -j -v"${2}"d -f '%Y-%m-%d' "$1" '+%Y-%m-%d'; }   # date_add_days 2026-11-22 +3
# Pretty "Tue 24 Nov" for an ISO date.
date_pretty()    { TZ=$BRIEF_TZ date -j -f '%Y-%m-%d' "$1" '+%a %-d %b'; }
weekday_long()   { TZ=$BRIEF_TZ date -j -f '%Y-%m-%d' "$1" '+%A'; }
# Whole days from $1 to $2 (ISO dates).
days_between() {
  local a b
  a="$(TZ=$BRIEF_TZ date -j -f '%Y-%m-%d %H:%M:%S' "$1 12:00:00" '+%s')"
  b="$(TZ=$BRIEF_TZ date -j -f '%Y-%m-%d %H:%M:%S' "$2 12:00:00" '+%s')"
  echo $(( (b - a) / 86400 ))
}
epoch_now() { date '+%s'; }

# ---- machine
model_name() { system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Name/{print $2; exit}'; }
is_mac_mini() {
  [ "${BRIEF_FORCE_MAC_MINI:-}" = "1" ] && return 0
  case "$(model_name)" in "Mac mini"*) return 0 ;; *) return 1 ;; esac
}

# Section ids in output order, plus file names and headings (bash 3.2: no assoc arrays).
ALL_SECTIONS="day india world tech events internships"
section_file() {
  case "$1" in
    day) echo "05-day.txt" ;; india) echo "10-india.txt" ;; world) echo "15-world.txt" ;;
    tech) echo "20-tech.txt" ;; events) echo "30-events.txt" ;;
    internships) echo "50-internships.txt" ;;
    *) return 1 ;;
  esac
}
section_label() {
  case "$1" in
    day) echo "Today" ;; india) echo "India" ;; world) echo "World" ;;
    tech) echo "Tech & AI" ;; events) echo "Events & Competitions" ;;
    internships) echo "Internships" ;;
  esac
}
valid_section() { section_file "$1" >/dev/null 2>&1; }
