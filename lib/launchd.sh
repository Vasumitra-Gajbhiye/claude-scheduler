# shellcheck shell=bash
# LaunchAgent install / uninstall / kickstart. Per-user agent in the gui domain, so the
# job can reach the login keychain (Claude's OAuth login) and the running Chrome.

launchd_domain() { echo "gui/$(id -u)"; }
launchd_loaded() { launchctl print "$(launchd_domain)/$LABEL" >/dev/null 2>&1; }

# PATH for the job: claude's own dir first, then the usual install locations and system paths.
launchd_path() {
  local p="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" d
  if [ -n "${1:-}" ]; then
    d="$(dirname "$1")"
    case ":$p:" in *":$d:"*) ;; *) p="$d:$p" ;; esac
  fi
  echo "$p"
}

# render_plist <out_file> <claude_bin>
render_plist() {
  local out="$1" claude="$2"
  R_BRIEF="$BRIEF_BIN" R_REPO="$REPO_DIR" R_LOGS="$LOGS_DIR" R_HOUR="$((10#$RUN_HOUR))" R_MINUTE="$((10#$RUN_MINUTE))" R_INTERVAL="$(( 10#$RETRY_MINUTES * 60 ))" R_EVHOUR="$((10#${TASKS_EVENING_HOUR:-19}))" \
  R_PATH="$(launchd_path "$claude")" perl -pe '
    sub x { my $s = shift; $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s }
    s/__BRIEF__/x($ENV{R_BRIEF})/ge; s/__REPO__/x($ENV{R_REPO})/ge; s/__LOGS__/x($ENV{R_LOGS})/ge;
    s/__HOUR__/$ENV{R_HOUR}/g; s/__EVHOUR__/$ENV{R_EVHOUR}/g; s/__INTERVAL__/$ENV{R_INTERVAL}/g; s/__MINUTE__/$ENV{R_MINUTE}/g; s/__PATH__/x($ENV{R_PATH})/ge;
  ' "$PLIST_TEMPLATE" >"$out"
  plutil -lint "$out" >/dev/null
}

validate_time() {
  case "$RUN_HOUR" in ''|*[!0-9]*) die "RUN_HOUR must be 0-23 (got '$RUN_HOUR')" ;; esac
  case "$RUN_MINUTE" in ''|*[!0-9]*) die "RUN_MINUTE must be 0-59 (got '$RUN_MINUTE')" ;; esac
  [ "$((10#$RUN_HOUR))" -le 23 ] || die "RUN_HOUR must be 0-23"
  [ "$((10#$RUN_MINUTE))" -le 59 ] || die "RUN_MINUTE must be 0-59"
  case "$RETRY_MINUTES" in ''|*[!0-9]*) die "RETRY_MINUTES must be a number of minutes" ;; esac
  [ "$((10#$RETRY_MINUTES))" -ge 10 ] || die "RETRY_MINUTES must be at least 10"
}

cmd_install() {
  local print_only=0 yes=0 claude tmp
  while [ $# -gt 0 ]; do
    case "$1" in
      --print) print_only=1 ;;
      --yes) yes=1 ;;
      *) die "Unknown option for install: $1" ;;
    esac
    shift
  done
  validate_time
  claude="$(command -v claude 2>/dev/null || true)"
  [ -n "$claude" ] || claude="$CLAUDE_BIN"
  [ -n "$claude" ] && [ -x "$claude" ] || die "claude not found on PATH. Install Claude Code first: curl -fsSL https://claude.ai/install.sh | bash"

  if [ "$print_only" = 1 ]; then
    tmp="$(mktemp -t mbplist)"
    render_plist "$tmp" "$claude" || { rm -f "$tmp"; die "Rendered plist failed plutil -lint"; }
    say "${C_DIM}# plist (lint OK), would be installed to $PLIST_DEST; nothing was installed${C_OFF}"
    cat "$tmp"; rm -f "$tmp"
    return 0
  fi

  if ! is_mac_mini && [ "$yes" != 1 ]; then
    warn "This is a $(model_name), not the Mac Mini. The schedule is meant to live on the always-on Mac Mini."
    die "Refusing to install here. If you really want a LaunchAgent on this Mac, run: ./brief install --yes"
  fi
  config_exists || die "config.env not found. Run: cp config.env.example config.env && chmod 600 config.env"

  config_set CLAUDE_BIN "$claude"
  CLAUDE_BIN="$claude"
  say "✅ CLAUDE_BIN=$claude written to config.env"

  mkdir -p "$HOME/Library/LaunchAgents" "$LOGS_DIR"
  render_plist "$PLIST_DEST" "$claude" || die "Rendered plist failed plutil -lint ($PLIST_DEST)"
  say "✅ Wrote $PLIST_DEST (daily at $(printf '%02d:%02d' "$RUN_HOUR" "$RUN_MINUTE"))"

  if launchd_loaded; then
    launchctl bootout "$(launchd_domain)/$LABEL" 2>/dev/null || true
    sleep 1
  fi
  launchctl bootstrap "$(launchd_domain)" "$PLIST_DEST" || die "launchctl bootstrap failed. Try: ./brief uninstall && ./brief install"
  launchctl enable "$(launchd_domain)/$LABEL" 2>/dev/null || true
  launchd_loaded || die "LaunchAgent did not load."
  say "✅ LaunchAgent loaded: $LABEL"
  say "   Next run: $(next_run_text). If a run is missed or fails, it catches up at login or wake and retries every ${RETRY_MINUTES} min (at most ${MAX_DAILY_ATTEMPTS} attempts a day)."
  say "   Loading the agent also runs a check right now: if it's past the run time and today's brief hasn't gone out, it starts."
  say ""
  say "Test the real launchd environment now:  ./brief kickstart  then  ./brief logs -f"
}

cmd_uninstall() {
  if launchd_loaded; then
    launchctl bootout "$(launchd_domain)/$LABEL" 2>/dev/null || true
    say "✅ Unloaded $LABEL"
  else
    say "LaunchAgent was not loaded."
  fi
  if [ -f "$PLIST_DEST" ]; then
    rm -f "$PLIST_DEST"
    say "✅ Removed $PLIST_DEST"
  fi
  say "The daily brief is paused. Re-enable with ./brief install"
}

cmd_kickstart() {
  launchd_loaded || die "LaunchAgent not loaded. Run ./brief install first (on the Mac Mini)."
  # One-shot marker: lets this kicked run go ahead even if today was already delivered.
  mkdir -p "$STATE_DIR"; touch "$STATE_DIR/force_next"
  launchctl kickstart -k "$(launchd_domain)/$LABEL" || { rm -f "$STATE_DIR/force_next"; die "launchctl kickstart failed"; }
  say "✅ Started the launchd job ($LABEL) in the background. It sends a real brief to Telegram."
  say "   Follow it with: ./brief logs -f"
}
