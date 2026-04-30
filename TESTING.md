# Testing franky-do against a real Slack workspace

This is the manual smoke that CI can't carry. By the end of it
you'll have a working `@franky-do` bot answering `@`-mentions
and a `/franky-do` slash command resetting threads in your
Slack workspace.

Estimated time: **15–25 minutes** for a first-time setup. Most
of it is clicking through Slack's app configuration UI.

## What you'll need

- A Slack workspace where you can install apps. If you're not
  an admin, you'll need approval (or just use a personal/test
  workspace — free tier works fine).
- An Anthropic API key (`sk-ant-...`) **or** a `CLAUDE_CODE_OAUTH_TOKEN`
  from `claude setup-token`.
- A built `franky-do` binary (`zig build` from this directory).
- Network egress on TCP/443 to `slack.com` and
  `wss-primary.slack.com` (Socket Mode is bot-initiated, so no
  inbound public endpoint required).

## Step 1 — Create the Slack app

**Fast path (recommended):** the repo ships a Slack App Manifest
that provisions Steps 2–5 in one shot.

1. Open <https://api.slack.com/apps> and click **Create New App**.
2. Choose **From a manifest**.
3. Pick the workspace to develop in.
4. Paste the contents of [`slack-app-manifest.yaml`](./slack-app-manifest.yaml)
   into the YAML tab.
5. Click **Next → Create**.

The app lands with Socket Mode on, scopes added, events
subscribed, and the `/franky-do` slash command registered. Skip
to **Step 2** below for the App-Level Token (the only piece the
manifest schema can't express), then jump to Step 6 for install.

---

**Manual path (skip if you used the manifest):** click through
each section below by hand.

1. Open <https://api.slack.com/apps> and click **Create New
   App**.
2. Choose **From scratch**.
3. Name it (e.g. `franky-do`) and pick the workspace to develop
   in. You can install it to other workspaces later.

You'll land on the app's settings page. Keep that browser tab
open — you'll bounce between sections.

## Step 2 — Enable Socket Mode

1. In the left sidebar, click **Socket Mode**.
2. Toggle **Enable Socket Mode** on.
3. Slack will prompt you to generate an **App-Level Token**.
   - **Token Name**: anything (e.g. `franky-do-socket`)
   - **Scopes**: add `connections:write` — required.
   - Optionally add `authorizations:read` and
     `app_configurations:write` if you want to inspect / modify
     app configs through this token. Not needed for v0.1.
   - Click **Generate**.
4. **Copy the token** (starts with `xapp-…`). Store it somewhere
   safe — Slack only shows it once. This is your `SLACK_APP_TOKEN`.

> **Security:** The app-level token can open new Socket Mode
> connections. Treat it like a credential.

## Step 3 — Configure OAuth scopes

This is the bot user's permissions. Without these, even a
correctly-installed bot can't read mentions or post messages.

1. In the sidebar, click **OAuth & Permissions**.
2. Under **Scopes → Bot Token Scopes**, click **Add an OAuth
   Scope** and add each of:

   | Scope | Why |
   |---|---|
   | `app_mentions:read` | Receive `app_mention` events |
   | `chat:write` | Post messages and updates |
   | `im:history` | Read DMs sent to the bot |
   | `im:read` | Detect DM channels |
   | `im:write` | Reply in DMs |
   | `commands` | Receive `/franky-do` slash-command invocations |
   | `reactions:read` | Receive `reaction_added` events (Phase 7 — abort/retry via emoji) |

   You can come back and add more later (e.g. `channels:read`,
   `groups:read`) if you want richer behavior.

## Step 4 — Subscribe to bot events

1. In the sidebar, click **Event Subscriptions**.
2. Toggle **Enable Events** on.
   - You do **not** need a Request URL — Socket Mode delivers
     events over the WebSocket. Slack should grey out that
     field automatically once Socket Mode is on.
3. Expand **Subscribe to bot events** and add:

   | Event | Why |
   |---|---|
   | `app_mention` | Fires when someone `@`-mentions the bot |
   | `message.im` | DMs to the bot |
   | `reaction_added` | Bot users react with ❌ to abort or ↩️ to retry (Phase 7) |

   Save Changes at the bottom.

## Step 5 — Register the slash command

1. In the sidebar, click **Slash Commands** → **Create New
   Command**.
2. Fill in:
   - **Command**: `/franky-do`
   - **Request URL**: leave blank (Socket Mode delivers it).
     Slack actually requires *something* in this field, but
     since Socket Mode is enabled it's ignored. You can put
     `https://example.com` as a placeholder.
   - **Short Description**: `Manage franky-do bot`
   - **Usage Hint**: `reset | help`
3. Click **Save**.

## Step 6 — Install to the workspace

1. In the sidebar, click **Install App** (top of the sidebar).
2. Click **Install to Workspace**.
3. Slack shows a permission summary — review and click **Allow**.
4. After install you'll get a **Bot User OAuth Token** (starts
   with `xoxb-…`). Copy it. This is your `SLACK_BOT_TOKEN`.

You should also see a **Workspace ID** somewhere on the page,
or you can grab it from any URL in your workspace
(`https://app.slack.com/client/<TXXXXXX>/...` — the `T...`
chunk is the team ID).

## Step 7 — Invite the bot to a channel

The bot can only see `@`-mentions in channels it's been invited
to.

In any channel: type `/invite @franky-do`. (Replace with your
app's actual name if you renamed it.) For DMs, just open a DM
with the bot — no invite needed.

## Step 8 — Persist tokens with `franky-do install`

```sh
cd franky-do
zig build
./zig-out/bin/franky-do install \
    --workspace T0123456 \
    --xapp xapp-1-… \
    --xoxb xoxb-… \
    --name "My Workspace"
```

This writes `~/.franky-do/workspaces/T0123456/auth.json` (mode
0600). Verify with `franky-do list`.

You can skip this step and pass the tokens via env vars
(`SLACK_APP_TOKEN` / `SLACK_BOT_TOKEN`) instead — useful for
ephemeral test runs.

## Step 9 — Provide LLM credentials

Set one of these in your shell environment:

```sh
export ANTHROPIC_API_KEY=sk-ant-…
# or
export CLAUDE_CODE_OAUTH_TOKEN=…
```

`franky-do run` requires at least one. Without them it bails
with a clear error message.

## Step 10 — Run

Single workspace from disk:

```sh
ANTHROPIC_API_KEY=sk-ant-… ./zig-out/bin/franky-do run --workspace T0123456
```

Or single workspace from env:

```sh
SLACK_APP_TOKEN=xapp-1-… \
SLACK_BOT_TOKEN=xoxb-… \
ANTHROPIC_API_KEY=sk-ant-… \
./zig-out/bin/franky-do run
```

Or every installed workspace in parallel:

```sh
ANTHROPIC_API_KEY=sk-ant-… ./zig-out/bin/franky-do run --all
```

Expected output:

```
franky-do connected: team_id=T0123456 bot_user_id=UBOTID
franky-do listening on Slack Socket Mode (Ctrl-C to quit)
```

If the connection drops, the process currently exits — Phase
6's read loop is one-shot. Just re-run.

## Step 11 — Test it

### Test A: app_mention

1. In a channel where you invited the bot, type `@franky-do
   what does the README say?`
2. Within a few seconds you should see a `_thinking…_`
   placeholder, then streamed updates as the model responds.
3. The bot has access to the working directory franky-do was
   started in via the `read` / `ls` / `find` / `grep` /
   `write` / `edit` tools. So it can actually read README.md.

### Test B: DM

1. Open a DM with the bot (just type its name in the Slack
   sidebar).
2. Send `hello`. The bot answers in the DM.
3. The thread anchor is the channel itself — every message is
   part of one continuous session per DM.

### Test C: Threading

1. Reply to a non-thread message in a channel by `@franky-do
   continue from above`. The bot replies in-thread; subsequent
   replies in the same thread reuse the same agent session.
2. Start a different thread with `@franky-do new question`.
   The bot starts a fresh session — no context bleed.

### Test D: Slash command

1. In any channel, type `/franky-do help`. The bot posts the
   command list.
2. In a thread you've been chatting with the bot, type
   `/franky-do reset`. The bot drops that thread's session and
   confirms with "Session reset. The next mention starts
   fresh."
3. `/franky-do stats` posts a workspace token + cost summary
   (Phase 8). For per-session detail run `franky-do stats` on
   the host instead — that prints a Markdown table.

### Test E: Reactions-as-control (Phase 7)

1. `@franky-do explain something complicated` and let the
   reply start streaming.
2. While it's streaming, react to the bot's message with
   `:x:` (❌). The bot aborts the in-flight turn and posts
   `✋ aborted by <@your_user>` in the thread.
3. React to the same message with
   `:leftwards_arrow_with_hook:` (↩️). The bot posts
   `↩️ retrying last prompt` and re-runs the prompt fresh.
4. Reactions on the user's `@`-mention work too — same
   semantics. The bot resolves either ts back to the thread
   via its `reply_anchors` LRU cache (1024 most-recent slots).

> **No `reactions:read` scope?** The bot will still answer
> mentions and slash commands, but emoji reactions will be
> silently dropped — Slack never delivers `reaction_added`
> events to apps without that scope. If you forgot to add it
> in Step 3, do so now and reinstall the app to your workspace.

### Test F: Token + cost dashboard (Phase 8)

After running a couple of conversations, on the host:

```sh
./zig-out/bin/franky-do stats
```

You'll see a Markdown table like:

```
ulid                       model                              input    output     cost
-------------------------- ---------------------------- --------- --------- --------
01JAB…                     claude-sonnet-4-6                12300      2150  $0.0691
01JCD…                     claude-sonnet-4-6                 4500      1200  $0.0315
-------------------------- ---------------------------- --------- --------- --------
2 session(s)                                              16800      3350  $0.1006
```

Sessions whose `model` field doesn't match a row in the bot's
hardcoded pricing table show `n/a` cost; the totals line then
notes how many sessions weren't priced. Edit
`src/pricing.zig` to add new model families.

## Troubleshooting

### "auth.test failed: …"

The tokens are wrong or the bot user has no scopes. Re-check
**OAuth & Permissions** has all the scopes from Step 3, and
that you copied the **Bot User OAuth Token** (not the User
OAuth Token, not the App-Level Token).

### "socket mode connect failed: …"

- The App-Level Token is missing `connections:write` scope —
  recreate it in **Socket Mode**.
- The token is from a different app — Socket Mode tokens are
  per-app.
- Network egress to `wss-primary.slack.com:443` is blocked by
  a corporate firewall.

### Bot connects but never answers `@`-mentions

- The bot user wasn't invited to the channel. `/invite
  @franky-do` in the channel.
- `app_mention` event isn't subscribed in **Event Subscriptions
  → Subscribe to bot events**.
- The bot is connected but the app config wasn't reinstalled
  after adding scopes/events. Go to **Install App** and click
  **Reinstall to Workspace**. (Slack's confusing rule: scope/event
  changes need a reinstall.)
- The franky-do process ran out of LLM credentials mid-message.
  Watch the bot's stderr for errors.

### Slash command shows "this command isn't supported"

- The command wasn't registered in **Slash Commands**.
- The app wasn't reinstalled after adding the slash command —
  reinstall.
- Socket Mode wasn't enabled, so Slack tried to POST to the
  Request URL placeholder you gave.

### Bot answers but text never updates (still `_thinking…_`)

- Slack's rate limit on `chat.update` is per-channel. If the
  bot is also being mentioned heavily in the same channel,
  updates may queue. v0.1's throttler keeps under the limit
  for a single conversation.

### "no LLM credentials" at startup

`ANTHROPIC_API_KEY` and `CLAUDE_CODE_OAUTH_TOKEN` are both
unset. Set one and re-run.

## Limits and risks

Read [franky-do.md §12 (security model)](./franky-do.md#12-security-model)
before deploying outside of testing. Highlights:

- **Anyone in the Slack workspace** with bot mention access can
  use the bot's full tool set against the workspace directory.
  Read/write/edit/grep/find/ls — no per-user permission scoping.
- **Bash is disabled in v0.1.** Re-enabling it without a real
  sandbox is a bad idea.
- **Tokens are stored in plaintext**, file-mode 0600. Don't
  share `~/.franky-do/` with untrusted users.

## Reinstall checklist

Whenever you change scopes, events, or slash commands in the
Slack app config: **Install App → Reinstall to Workspace**.
Slack's UI is silent about this — the app keeps running with
old permissions until you force a reinstall.

## Migrating from v0.2.x to v0.3.0

v0.3.0 adds **emoji status indicators on user mentions** (👀 / 💭
/ ✅ / ❌). This requires a new OAuth scope, **`reactions:write`**,
which means existing v0.2.x installs need to be reinstalled to
pick up the new permission.

Steps:

1. Open <https://api.slack.com/apps> → your franky-do app.
2. **App Manifest** tab → paste the updated
   `slack-app-manifest.yaml` (or hand-edit the OAuth scopes block
   to add `reactions:write`).
3. Click **Save Changes**. Slack will show a yellow banner
   indicating the manifest changed.
4. **Install App** → **Reinstall to Workspace**. Approve.
5. Copy the **freshly issued** Bot Token (`xoxb-…`) — Slack
   re-issues this on every reinstall.
6. Re-persist with the new token:

   ```sh
   franky-do install --workspace T... --xapp xapp-... --xoxb xoxb-NEW-...
   ```

7. Restart your `franky-do run`. On your next `@`-mention you
   should see 👀 land within a second.

If 👀 doesn't appear after the upgrade, you're likely still
running with the old `xoxb-…` (no `reactions:write` scope). The
process logs at `FRANKY_DO_LOG=warn` will show:

```
WARN franky-do reaction reactions.add !ok name=eyes error=missing_scope
```

— which is the canonical "you forgot to reinstall" signal.

## What's not yet supported

These are documented in `franky-do.md` § 0 status table and
v0.2+ scope:

- Reconnect on Socket Mode disconnect (process exits today)
- 40k-character message splits for long responses
- OAuth install flow (you're using the manual paste-tokens flow)
- Per-thread filesystem isolation — every thread sees the same
  workspace dir
- Bash with sandbox

If any of these matter for your use case, file an issue or
patch.
