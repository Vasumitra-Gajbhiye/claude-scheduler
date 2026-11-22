# shellcheck shell=bash
# ./brief doctor: health checks, each with a one-line fix.

D_FAIL=0; D_WARN=0
d_ok()   { printf '  ✅ %s\n' "$1"; }
d_bad()  { printf '  ❌ %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s→ %s%s\n' "$C_DIM" "$2" "$C_OFF"; D_FAIL=$(( D_FAIL + 1 )); }
d_warn() { printf '  ⚠️  %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s→ %s%s\n' "$C_DIM" "$2" "$C_OFF"; D_WARN=$(( D_WARN + 1 )); }
d_info() { printf '  ℹ️  %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s→ %s%s\n' "$C_DIM" "$2" "$C_OFF"; }
d_head() { printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_OFF"; }

# Shell profile files that export API credentials (prints "file:line" per hit).
profile_credential_hits() {
  local f
  for f in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zshenv" "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.profile"; do
    [ -f "$f" ] || continue
    grep -nE '^[[:space:]]*(export[[:space:]]+)?(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN)=' "$f" 2>/dev/null |
      cut -d: -f1 | sed "s|^|${f/#$HOME/~}:|"
  done
}

cmd_doctor() {
  local mini=0 v auth hits perm tz free_kb pm sched fv fvn al lr li am st le
  is_mac_mini && mini=1
  say "${C_BOLD}Morning Brief doctor${C_OFF}  ($(model_name), macOS $(sw_vers -productVersion))"
  [ "$mini" = 1 ] || say "${C_DIM}This isn't the Mac Mini, so the always-on checks are informational.${C_OFF}"

  # 1. claude
  d_head "Claude Code"
  if [ -n "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ]; then
    v="$("$CLAUDE_BIN" --version 2>/dev/null | head -1)"
    d_ok "claude found: $CLAUDE_BIN ($v)"
  else
    d_bad "claude not found" "Install: curl -fsSL https://claude.ai/install.sh | bash   (then ./brief install on the Mac Mini)"
  fi
  if config_exists; then
    v="$(sed -n 's/^CLAUDE_BIN="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$CONFIG_FILE" | tail -1)"
    if [ -z "$v" ]; then
      if [ "$mini" = 1 ]; then d_warn "CLAUDE_BIN not set in config.env" "Run ./brief install (fills it in)"; else d_info "CLAUDE_BIN not set in config.env (filled in by ./brief install on the Mac Mini; using PATH here)"; fi
    elif [ ! -x "$v" ]; then
      d_bad "CLAUDE_BIN in config.env doesn't exist: $v" "Rerun ./brief install on this machine"
    fi
  fi

  # 2. subscription auth, not API keys
  hits="$(env | grep -E '^(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN)=' | cut -d= -f1 | tr '\n' ' ')"
  if [ -n "$hits" ]; then
    d_warn "Set in your environment: $hits(brief unsets these before calling claude)" "Remove them from your shell setup so interactive claude also uses your subscription"
  fi
  hits="$(profile_credential_hits)"
  if [ -n "$hits" ]; then
    d_bad "API credential exported in shell profile: $(echo $hits)" "Delete that line, open a new terminal. Claude Code would bill the key instead of your Pro plan."
  else
    d_ok "No ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN / CLAUDE_CODE_OAUTH_TOKEN in shell profiles"
  fi
  if [ -n "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ]; then
    auth="$(env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN "$CLAUDE_BIN" auth status 2>/dev/null |
      perl -MJSON::PP -e 'local $/; my $d = eval { decode_json(<STDIN>) } or exit 1;
        printf "%s|%s|%s|%s", ($d->{loggedIn} ? 1 : 0), $d->{authMethod} // "", $d->{subscriptionType} // "", $d->{loginExpiresAt} // ""')"
    if [ -z "$auth" ]; then
      d_warn "Couldn't read 'claude auth status'" "Run claude, then /status: it must show your Claude Pro account"
    else
      IFS='|' read -r li am st le <<EOF
$auth
EOF
      if [ "$li" = 1 ] && [ "$am" = "claude.ai" ]; then
        d_ok "Logged in with a claude.ai subscription (plan: ${st:-unknown}), not an API key"
        case "$st" in pro|max|team|enterprise|ultra) ;; *) d_warn "Plan reported as '${st:-unknown}'" "Expected 'pro'. Check /status in claude" ;; esac
      elif [ "$li" = 1 ]; then
        d_bad "Logged in via '$am', not a claude.ai subscription" "In claude: /logout, then /login with your Pro account (never setup-token)"
      else
        d_bad "Not logged in" "Run claude, then /login with your Claude Pro account"
      fi
    fi
  fi

  # 3-4. Chrome + extension
  d_head "Chrome"
  if [ -d "/Applications/Google Chrome.app" ] || [ -d "$HOME/Applications/Google Chrome.app" ]; then
    if chrome_running; then d_ok "Google Chrome installed and running"; else d_warn "Google Chrome installed but not running" "Open Chrome (and add it to Login Items on the Mac Mini)"; fi
  else
    d_bad "Google Chrome not installed" "Install from https://www.google.com/chrome/"
  fi
  if [ -f "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.anthropic.claude_code_browser_extension.json" ]; then
    d_ok "Claude in Chrome native messaging host installed"
  else
    d_bad "Claude in Chrome native host missing" "Install the Claude extension (≥1.0.36), then run claude --chrome once and /chrome"
  fi
  if chrome_connected; then
    d_ok "Claude in Chrome native host is running"
    d_info "That doesn't prove the extension is signed in to this account. Verify with: ./brief chrome-check"
  else
    d_warn "Claude in Chrome native host not running (extension not active)" "Open Chrome, check the Claude extension is signed in (same account/org as Claude Code), run /chrome in claude"
  fi

  # 5-6. config + telegram
  d_head "Config & Telegram"
  if config_exists; then
    perm="$(stat -f %Lp "$CONFIG_FILE")"
    if [ "$perm" = 600 ]; then d_ok "config.env exists (chmod 600)"; else d_bad "config.env permissions are $perm" "chmod 600 config.env"; fi
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
      d_ok "Telegram token and chat id filled in"
      if tg_getme; then d_ok "Telegram bot token valid ($TG_BOT_NAME); nothing sent"
      else d_bad "Telegram rejected the token (${TG_LAST_ERROR:-no response})" "Re-copy the token from @BotFather into config.env"; fi
    else
      [ -n "$TELEGRAM_BOT_TOKEN" ] || d_bad "TELEGRAM_BOT_TOKEN empty" "@BotFather → /newbot, paste the token into config.env"
      [ -n "$TELEGRAM_CHAT_ID" ] || d_bad "TELEGRAM_CHAT_ID empty" "Message your bot, then ./brief chat-id and paste it into config.env"
    fi
  else
    d_bad "config.env missing" "cp config.env.example config.env && chmod 600 config.env"
  fi
  if [ -f "$PROMPTS_DIR/profile.md" ]; then d_ok "prompts/profile.md present"
  else d_bad "prompts/profile.md missing (it's gitignored)" "Copy it from your other Mac, or: cp prompts/profile.md.example prompts/profile.md and edit"; fi
  case "${MODEL:-}" in sonnet) d_ok "Model: sonnet" ;; "") d_bad "MODEL empty" "MODEL=\"sonnet\" in config.env" ;; *) d_info "Model: $MODEL (sonnet is lightest on Pro limits)" ;; esac

  # 7-9. always-on (Mac Mini)
  d_head "Schedule & always-on$([ "$mini" = 1 ] || echo ' (Mac Mini only)')"
  if launchd_loaded; then
    d_ok "LaunchAgent loaded; next run $(next_run_text)"
  elif [ "$mini" = 1 ]; then
    d_bad "LaunchAgent not loaded" "./brief install"
  else
    d_info "Mac Mini only: LaunchAgent not installed here (expected; don't install on this Mac)"
  fi
  tz="$(readlink /etc/localtime 2>/dev/null | sed 's|.*zoneinfo/||')"
  if [ "$tz" = "Asia/Kolkata" ]; then d_ok "Time zone: Asia/Kolkata"
  else d_bad "Time zone is '$tz'" "System Settings → General → Date & Time → Time zone: Kolkata/Asia (or: sudo systemsetup -settimezone Asia/Kolkata)"; fi
  pm="$(pmset -g 2>/dev/null | awk '$1 == "sleep" { print $2; exit }')"
  sched="$(pmset -g sched 2>/dev/null | grep -iE 'repeating|wakepoweron|wake.*(MTWRFSU|every)' | head -1)"
  if [ "$pm" = 0 ] || [ -n "$sched" ]; then
    d_ok "Power: $([ "$pm" = 0 ] && echo 'system sleep disabled')$([ "$pm" = 0 ] && [ -n "$sched" ] && echo '; ')$([ -n "$sched" ] && echo 'repeating wake scheduled')"
  elif [ "$mini" = 1 ]; then
    d_bad "Mac may sleep through 06:00 (sleep=$pm, no repeating wake)" "System Settings → Energy → Prevent automatic sleeping; and: sudo pmset repeat wakeorpoweron MTWRFSU 05:55:00"
  else
    d_info "Mac Mini only: sleep is ${pm:-?} min and there's no repeating wake (fine for a laptop)"
  fi
  fv="$(fdesetup status 2>/dev/null)"
  fvn=""; case "$fv" in *On*) fvn=" (FileVault is on)" ;; esac
  al="$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)"
  case "$fv" in
    *On*) d_ok "FileVault on, password needed at startup. A brief missed while the Mac was off runs as soon as you log in." ;;
    *)    if [ -n "$al" ]; then d_ok "Automatic login enabled ($al)"
          else d_info "FileVault off, no automatic login. A missed brief runs as soon as you log in."; fi ;;
  esac

  # 10-11. disk + last run
  d_head "Health"
  free_kb="$(df -k "$REPO_DIR" | awk 'NR==2 { print $4 }')"
  if [ "${free_kb:-0}" -gt 2097152 ]; then d_ok "Disk space: $(( free_kb / 1048576 )) GB free"
  else d_bad "Low disk space: $(( ${free_kb:-0} / 1024 )) MB free" "Free up space (logs/ and runs/ are safe to clear)"; fi
  if [ -f "$STATE_DIR/last_run" ]; then
    lr="$(last_run_get status)"
    case "$lr" in
      ok*) d_ok "Last run: $lr at $(last_run_get time)" ;;
      *) d_bad "Last run: $lr at $(last_run_get time): $(last_run_get reason)" "./brief logs" ;;
    esac
  else
    d_info "No runs yet. Try: ./brief run --dry-run --only tech"
  fi
  if [ -d "$LOCK_DIR" ]; then d_warn "A run lock exists ($LOCK_DIR)" "If no run is active, it is cleared automatically once stale, or rm -rf it"; fi

  say ""
  if [ "$D_FAIL" = 0 ]; then
    say "${C_GRN}${C_BOLD}All checks passed${C_OFF}$([ "$D_WARN" -gt 0 ] && echo " ($D_WARN warning(s))")."
  else
    say "${C_RED}${C_BOLD}$D_FAIL problem(s)${C_OFF}$([ "$D_WARN" -gt 0 ] && echo ", $D_WARN warning(s)"). Fix the ❌ items above."
  fi
  [ "$D_FAIL" = 0 ]
}
