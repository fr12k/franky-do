# franky-do

A Slack agent bot built on the [franky](../franky/) SDK. Listens via
Slack Socket Mode, drives one stateful coding agent per Slack thread,
streams replies back into the thread.

> **Status: Phase 0 (skeleton).** The build + dependency seam works
> end-to-end; everything else is stubs. See [franky-do.md](./franky-do.md)
> §14 for the phase plan.

## Build

```sh
cd franky-do
zig build                                  # produces zig-out/bin/franky-do
zig build test                             # runs unit tests
./zig-out/bin/franky-do --version          # smoke
```

The build pulls in two dependencies:

- **`franky`** — sibling project at `../franky`, accessed only
  through the `franky.sdk` facade (no reaching past it).
- **`websocket.zig`** — vendored from
  [karlseguin/websocket.zig](https://github.com/karlseguin/websocket.zig),
  pinned to a specific commit in `build.zig.zon`. Provides the WSS
  client we'll use for Slack Socket Mode in Phase 2+.

## Quick start with a real Slack workspace

There's a step-by-step guide in [TESTING.md](./TESTING.md) that
walks you through:

1. Creating a Slack app at <https://api.slack.com/apps>
2. Enabling Socket Mode + generating the App-Level Token (`xapp-…`)
3. Adding the right OAuth scopes (`app_mentions:read`,
   `chat:write`, `commands`, `im:history`, `im:read`,
   `im:write`)
4. Subscribing to bot events (`app_mention`, `message.im`)
5. Registering the `/franky-do` slash command
6. Installing the app, capturing the Bot Token (`xoxb-…`)
7. `franky-do install --workspace T... --xapp ... --xoxb ...`
8. `ANTHROPIC_API_KEY=sk-ant-… franky-do run --workspace T...`
9. Testing `@`-mentions, DMs, and the slash command end-to-end

Read that doc first — it covers the Slack-side configuration
that's easy to miss.

## Configure & run (TL;DR for repeat users)

```sh
# Single workspace from env vars
export SLACK_APP_TOKEN=xapp-1-...
export SLACK_BOT_TOKEN=xoxb-...
export ANTHROPIC_API_KEY=sk-ant-...
./zig-out/bin/franky-do run

# Or persist tokens once, then run by team_id
./zig-out/bin/franky-do install --workspace T0123 --xapp xapp-... --xoxb xoxb-...
ANTHROPIC_API_KEY=sk-ant-... ./zig-out/bin/franky-do run --workspace T0123

# Or every installed workspace in parallel
ANTHROPIC_API_KEY=sk-ant-... ./zig-out/bin/franky-do run --all
```

Slack app config requirements (full details in
[TESTING.md](./TESTING.md)):

- Socket Mode enabled
- App-Level Token with `connections:write`
- Bot Token with: `app_mentions:read`, `chat:write`,
  `commands`, `im:history`, `im:read`, `im:write`
- Bot events: `app_mention`, `message.im`
- Slash command: `/franky-do` (Request URL placeholder; Socket
  Mode delivers it over WSS)

## Spec

The full design lives in [franky-do.md](./franky-do.md). Read that
before changing anything substantive.

## License

See repository root.
