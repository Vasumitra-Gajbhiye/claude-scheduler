# Morning Brief

A daily Telegram digest written by Claude Code running headless (`claude -p`) on a **Claude Pro subscription**. It runs every morning at 06:00 IST on an always-on Mac Mini.

It researches seven sections:
- 📆 Today: what today is known for (national/international days, anniversaries, festivals)
- 🇮🇳 India: the top 5 stories, from The Hindu read in your logged-in Chrome
- 🌍 World: the top 3 global stories
- 💻 Tech & AI: the top 3 stories
- 📅 Bangalore events (Luma, in Chrome)
- 🏆 Competitions
- 💼 Internships: only ones paying ₹50,000/month or more (or well-known big-firm programmes that pay above that)

The counts, sources and rules per section live in `prompts/sources.md`; edit them freely.

Then it sends them as plain-text Telegram messages, one per section, with a deterministic ⏰ Closing-soon reminder list. Only the first message buzzes your phone. It's one-way: the bot never reads your replies.

```
launchd 06:00, at login, on wake, every 30 min ─▶ brief run --scheduled
                   ├─ due? (past 06:00, not delivered today, < 3 attempts today), else exit silently
                   ├─ lock, wait for network, prune memory, make sure Chrome + extension are up
                   ├─ claude -p --model sonnet --chrome  (sandboxed, read-only, no shell)
                   │    writes 05-day.txt … 50-internships.txt, items.tsv, notes.txt
                   ├─ bash builds header, ⏰ Closing soon, "couldn't check" footer
                   ├─ Telegram sendMessage (split, retried)
                   └─ only if everything sent: remember items, archive, mark success
```

Everything is bash plus tools macOS ships with (curl, perl, awk, sed, launchd, plutil). There are no Python or Node dependencies.

---

## Billing: subscription only, never API keys

- **Auth is your normal `/login` session** (OAuth, stored in the macOS keychain), so runs draw on your Pro plan's usage limits.
- `brief` runs `unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN` before it ever calls `claude`. If any of these were set, Claude Code would use it instead of your subscription.
- **Don't use `claude setup-token` or `CLAUDE_CODE_OAUTH_TOKEN`.** With those credentials, Claude Code keeps Chrome integration off, so `--chrome` would silently stop working ([docs](https://code.claude.com/docs/en/chrome)).
- **Don't use `--bare`.** It never reads the OAuth/keychain login.
- The log shows `total_cost_usd` for each run. That's Claude Code's *estimate* of what the run would have cost at API prices. On Pro, you're not billed it; the run counts against your plan's usage limits instead.
- **Re-check occasionally:**
  - As of Nov 2026, `claude -p` on Pro draws from your normal subscription limits. A planned move of headless/automated usage onto a separate credit pool was paused.
  - If Anthropic changes that, scheduled runs could start drawing from a different allowance.
  - Check the current Claude Code pricing/usage docs every few months, and watch `/status` in `claude`.
- `./brief doctor` checks that `claude auth status` reports a `claude.ai` subscription login, and that no API key is exported in your shell profiles.

---

## Quick start (testing on any Mac)

```bash
git clone https://github.com/Vasumitra-Gajbhiye/claude-scheduler.git
cd claude-scheduler
cp config.env.example config.env && chmod 600 config.env
cp prompts/profile.md.example prompts/profile.md      # then describe yourself
./brief doctor
./brief run --dry-run --only tech                       # cheapest real test, no Chrome
```

Paths are resolved from the script's own location, so the repo can live anywhere.

---

## Commands

| Command | What it does |
|---|---|
| `./brief run` | Full run now: research, send to Telegram, update memory, archive. Ignores the "already sent today" guard. |
| `./brief run --dry-run` | Full research, printed to the terminal. Sends nothing. Doesn't touch `seen.tsv` or `archive/`. |
| `./brief run --only <section>` | One section only: `day`, `india`, `world`, `tech`, `events`, `competitions`, `internships`. Combine with `--dry-run`. |
| `./brief run --scheduled` | What launchd runs. Only runs if a brief is due: past `RUN_HOUR:RUN_MINUTE`, not yet delivered today, and fewer than `MAX_DAILY_ATTEMPTS` attempts today. Otherwise it exits silently. Waits for the network, starts Chrome and waits up to 60s for the extension. |
| `./brief resend [YYYY-MM-DD]` | Re-send an archived brief (default: the latest). |
| `./brief chat-id` | Lists the chat IDs that have messaged your bot (Telegram `getUpdates`). |
| `./brief test-telegram` | Sends "✅ Morning Brief bot is connected". |
| `./brief doctor` | Health check: ✅/❌ plus a fix for each item. |
| `./brief chrome-check` | Live one-turn test that `claude -p` can actually use the Claude in Chrome extension. It's the only reliable check of the extension pairing. Uses a tiny bit of your plan. |
| `./brief install` | Fills `CLAUDE_BIN` into config, renders the LaunchAgent with absolute paths and `RUN_HOUR:RUN_MINUTE`, then `launchctl bootstrap`s it. Idempotent. **Mac Mini only.** It refuses elsewhere unless you pass `--yes`. |
| `./brief install --print` | Renders and lints the plist, prints it, installs nothing. |
| `./brief uninstall` | Unloads and removes the LaunchAgent, which pauses the brief. |
| `./brief kickstart` | Runs the real launchd job now, so you can test the launchd environment (PATH, keychain). It sends a real brief, even if one was already sent today. |
| `./brief status` | Last run, result, duration, item count, LaunchAgent state, next run. |
| `./brief logs [-f]` | Shows (or follows) the latest run log, plus launchd's stdout/stderr. |

Examples:
```bash
./brief run --dry-run --only india     # proves the logged-in Hindu read works
./brief run --dry-run                  # everything, printed here
./brief run                            # the real thing
./brief resend 2026-11-22
```

---

## Changing what you get

- **`prompts/profile.md`** is who you are and what you care about. It's **gitignored**, because this repo is public. Edit it any time; the next run uses it. A template is in `prompts/profile.md.example`.
- **`prompts/sources.md`** lists, for each section, the sites to check, how many items to include, the time window, and whether to use Chrome. Committed. Edit freely.
- **`prompts/brief.md`** is the inner prompt template: rules and output formats. Change it carefully; the bash side relies on the file names and the "URL on its own line" format.
- **Run time:** edit `RUN_HOUR` / `RUN_MINUTE` in `config.env`, then rerun `./brief install`.
- **Model:** `MODEL="sonnet"` in `config.env`. Sonnet is the lightest on Pro limits.
- **Pause:** `./brief uninstall`. Resume with `./brief install`.

### config.env

| Key | Default | Meaning |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | | From @BotFather |
| `TELEGRAM_CHAT_ID` | | From `./brief chat-id` |
| `MODEL` | `sonnet` | Claude model alias |
| `RUN_HOUR`, `RUN_MINUTE` | `6`, `0` | Daily run time (local time; keep the Mac on Asia/Kolkata) |
| `MAX_SECONDS` | `2400` | Hard timeout per run |
| `CLAUDE_BIN` | (filled by `install`) | Absolute path to `claude` on this machine |
| `CLOSING_SOON_DAYS` | `3` | Window for ⏰ Closing soon |
| `SEEN_RETENTION_DAYS` | `120` | How long sent items are remembered, unless their deadline is still ahead |
| `MAX_DAILY_ATTEMPTS` | `3` | Automatic attempts per day (catch-up plus retries after failures) |
| `RETRY_MINUTES` | `30` | How often launchd re-checks whether a brief is due. Rerun `./brief install` after changing it. |

### Missed or failed runs (catch-up)

The LaunchAgent checks at 06:00, whenever you log in, when the Mac wakes, and every `RETRY_MINUTES`. Each check runs a brief only if one is **due**:
- it's past 06:00;
- today's brief hasn't been delivered yet;
- there have been fewer than `MAX_DAILY_ATTEMPTS` attempts today.

So:
- **Mac off, logged out or asleep at 06:00** (power cut, restart, FileVault password screen): the brief runs as soon as you log in or the Mac wakes. It waits up to 2 minutes for the network and 60s for Chrome first.
- **Logging in before 06:00** does nothing early. The 06:00 run happens as normal.
- **A run fails** (Chrome not ready, network, usage limit…): you get the ⚠️ alert, which says "Will retry automatically in about 30 min (attempt 1 of 3 today)". After 3 failed attempts it stops for the day and the alert says so. Fix the problem and run `./brief run`.
- **Never twice a day:** once delivered, every later check that day exits silently. Checks that find nothing due write no log file. `./brief status` shows the last decision ("Last check") and today's attempt count.

---

## Files

```
brief                     CLI entry point
lib/                      common, telegram, state, claude, run, launchd, doctor
prompts/brief.md          inner prompt template ({{PLACEHOLDERS}} filled each run)
prompts/sources.md        sources per section            (edit me)
prompts/profile.md        who you are       (gitignored; edit me)
config.env                your secrets      (gitignored, chmod 600)
launchd/…plist.template   LaunchAgent template
tests/run-tests.sh        offline test suite (fake curl + fake claude; never sends)

state/seen.tsv            everything already sent: date_sent, type, deadline, title, url
state/last_success        date of the last delivered brief
state/last_failure        time, reason, log of the last failure
state/last_run            summary for ./brief status
archive/YYYY-MM-DD[-N]/   every delivered brief, exactly as sent
runs/<timestamp>/         scratch dir per run (prompt, claude JSON, raw outputs); pruned after 7 days
logs/                     run-*.log per run, latest.log, launchd.out/err.log
```

`state/`, `archive/`, `runs/` and `logs/` are gitignored.

---

## How the inner run is sandboxed

The research run is told it's unattended and read-only. On top of that, the permission layer enforces this:

- `--permission-mode dontAsk --permission-prompts none`: anything that would prompt is denied, so nothing can block waiting for a click.
- `--allowedTools`: `WebSearch`, `WebFetch`, and `Read(...)`/`Edit(...)` scoped to that run's own directory (`Edit` covers Write).
- Only the **read-only** Claude in Chrome tools are allowed: tabs context/create/close, navigate, get_page_text, read_page, find.
- `--disallowedTools`: `Bash`, plus the Chrome tools that can act on a page (computer, form_input, file_upload, upload_image, javascript_tool, browser_batch, gif_creator). It can't click, type, log in, register or submit anything.
- `--strict-mcp-config`: your other MCP servers and claude.ai connectors (Gmail, Notion, …) are not loaded. Chrome still comes in via `--chrome`.
- `--chrome` is only passed when a section needs it, so `--only tech` runs with `--no-chrome`.
- `seen.tsv` is copied into the run dir, so the run never reads anything outside it.
- `MAX_SECONDS` is enforced by a watchdog that kills claude's whole process group.

The prompt also tells it that web page content is untrusted data, that it must never construct URLs, and that it must close its own tabs.

---

## Deploy to the Mac Mini

The MacBook is for building and testing. The schedule lives on the Mac Mini.

1. **Clone:**
   ```bash
   cd ~ && git clone https://github.com/Vasumitra-Gajbhiye/claude-scheduler.git && cd claude-scheduler
   ```
2. **Copy your two private files across.** They are gitignored, so they are not in the clone:
   - `config.env` (bot token and chat ID)
   - `prompts/profile.md`

   Use AirDrop, or from the MacBook:
   ```bash
   scp config.env prompts/profile.md <you>@<mac-mini>.local:~/claude-scheduler/   # then move profile.md into prompts/
   ```
   Then on the Mac Mini: `chmod 600 config.env`. **Never commit either file.** The repo is public.
3. **First-time setup there:** install Claude Code, log in, set up Claude in Chrome, set the energy and auto-login settings, then run `./brief install`. The exact steps are in [Mac Mini setup](#mac-mini-setup).
4. **Updating later:** `git pull` on the Mac Mini. Rerun `./brief install` only if you changed the run time or moved the repo.

### Mac Mini setup

- **Claude Code:** `curl -fsSL https://claude.ai/install.sh | bash`, then `claude` → `/login` with your Pro account → `/status` must show the Pro plan.
- **Claude in Chrome:**
  - Install the extension (version ≥ 1.0.36) from the Chrome Web Store.
  - Sign in with the **same account and org** as Claude Code.
  - Run `claude --chrome` once and accept the dialog.
  - Run `/chrome` and check it shows "Status: Enabled" and "Extension: Installed".
  - Run `./brief chrome-check`. It must say ✅ connected.
- **Sites:**
  - Log in to The Hindu in that Chrome profile.
  - In the Claude extension's settings (site permissions), allow thehindu.com, luma.com, lu.ma, unstop.com and devfolio.co. Unattended runs can't click "allow".
  - Then `./brief run --dry-run --only india` and `--only events`. If `notes.txt` mentions a permission prompt, the site still isn't allowed.
- **Stay awake and logged in:**
  - Keep FileVault **on** and automatic login **off**. The Mac then always needs your password at startup.
  - Energy settings that prevent sleep.
  - `sudo pmset repeat wakeorpoweron MTWRFSU 05:55:00`.
  - Chrome in Login Items.
  - Stay logged in. Lock the screen (Ctrl-⌘-Q) instead of logging out. The 06:00 run works while the screen is locked.
- **Schedule:**
  - `./brief install`, then `./brief kickstart`, then `./brief logs -f`.
  - Click **Always Allow** if the keychain asks about `claude`.
- **Check:** `./brief doctor` → all green.

**FileVault on (recommended here).**
- FileVault encrypts the whole disk and asks for your password at every startup. Nobody can use the Mac or read its disk without it.
- The cost: after a power cut or restart, nothing runs until you log in. The [catch-up](#missed-or-failed-runs-catch-up) then sends that day's brief as soon as you do.
- The only setup that needs no human after a restart is FileVault off plus automatic login, which leaves the disk readable to anyone who takes the Mac.

---

## Troubleshooting

Start with `./brief doctor`, then `./brief logs`. Every failure also arrives on Telegram as "⚠️ Morning brief failed: …", with the last log lines.

**"Claude usage limit reached"**
- The run hit your Pro plan's session or weekly limit. Nothing was sent or saved.
- Rerun with `./brief run` after the reset time in the message.
- Lower the cost per run: `--only` while testing, fewer sources in `sources.md`, and keep `MODEL="sonnet"`.
- Avoid heavy interactive Claude use right before 06:00.

**"Browser extension is not connected" / India or Events fall back to WebFetch (footer: "Couldn't check")**
- Run `./brief chrome-check`. It tells you in about 10 seconds whether `claude -p` can reach the extension.
- A running native-host process, which `doctor` checks, does *not* prove the extension is signed in to the right account.
- The Hindu blocks WebFetch. While Chrome is down, the India section uses the fallback outlets listed in `sources.md`, and the footer says so.
- Chrome must be running with the Claude extension signed in to the **same claude.ai account and organization** as Claude Code.
- Fix: open Chrome, check the extension's login, restart Chrome, then `claude --chrome` → `/chrome`.
- Make sure Chrome is in Login Items on the Mac Mini.

**Chrome opened on a different computer (e.g. the MacBook) during a Mac Mini run**
- Every Chrome signed in to your claude.ai account is reachable from Claude Code, wherever it is.
- The extension's `isLocal` flag is not reliable: with two Macs connected, both can show as local.
- `./brief chrome-check` identifies this Mac's browser for certain:
  - it opens a tagged example.com tab in every connected browser;
  - it asks the local Chrome, through AppleScript, which tag it has;
  - it saves that device ID in `state/chrome_device` (per machine, not in git);
  - it closes the test tabs.
- Runs then select exactly that device. If it isn't connected, the run doesn't use Chrome at all and the footer says "Chrome: this Mac's browser not connected".
- Run `./brief chrome-check` once on each Mac, and again after reinstalling Chrome or the extension.
- macOS asks once whether your terminal may control Google Chrome. Allow it. It can be changed later under System Settings → Privacy & Security → Automation.
- If that's not possible, find the example.com tab on this Mac, copy the ID after `?morningbrief-probe=`, and run `./brief chrome-check --use <deviceId>`.

**Chrome asks for permission / sites blocked**
- Unattended runs deny anything that would prompt.
- Allow the sites in the Claude extension's settings (see the Mac Mini setup).
- Run `./brief run --dry-run --only india` interactively and read `notes.txt` in the run dir.

**macOS keychain prompt mentioning `claude`**
- The first launchd run may ask for access to the login keychain, where Claude Code's login lives. Click **Always Allow**.
- If you click Deny, or no one is there to click, the run fails as "not logged in".
- Run `./brief kickstart` while you're at the Mac Mini so you can answer it once.

**launchd never fires**
- `./brief status` should say "LaunchAgent: ✅ loaded".
- Check `logs/launchd.err.log`. `launchctl print gui/$(id -u)/com.morningbrief.daily` shows the job's state and last exit code.
- The Mac must be logged in (screen locked is fine) and awake at the run time: energy settings plus the `pmset repeat` wake.
- If it wasn't, the brief catches up at your next login or wake. `./brief status` → "Last check" shows what the scheduler last decided and why.
- "skip: 3 failed attempts today" means automatic retries are used up for the day. Run `./brief logs`, fix the problem, then `./brief run`.
- After moving the repo or changing the time, rerun `./brief install`.

**Telegram 401 Unauthorized:** the bot token is wrong or was revoked. Copy it again from @BotFather (`/token`) into `config.env`.

**Telegram 400 "chat not found":**
- The chat ID is wrong, or you've never messaged the bot.
- Send it "hi", then run `./brief chat-id`, update `config.env`, and run `./brief test-telegram`.

**Telegram 403 "bot was blocked by the user":** unblock the bot in Telegram.

**"Another run is already in progress":** a run holds `state/run.lock`. A stale lock clears itself after 2×`MAX_SECONDS`, or as soon as its process is gone.

**Timed out:**
- Raise `MAX_SECONDS`, or trim `sources.md`.
- The log shows how far it got. `runs/<timestamp>/` keeps the partial output for 7 days.

---

## Tests

```bash
tests/run-tests.sh
```

Offline: it uses a fake `curl` and a fake `claude`, never sends anything, and never calls the model.

It covers:
- the Telegram splitter (10k chars with emoji; every chunk ≤ 3800 bytes, valid UTF-8, split on line boundaries);
- retry, 429 `retry_after` and 401 handling;
- token redaction;
- the `seen.tsv` prune and Closing-soon logic (past, today, +2d and +10d deadlines);
- locks (live, dead and stale);
- prompt rendering and plist rendering;
- the full pipeline: dry run vs real run, `--scheduled` skip, resend, usage-limit, empty-output, timeout and Telegram failure paths.
