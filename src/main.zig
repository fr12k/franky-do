//! franky-do — Slack agent bot.
//!
//! Phase 0 surface: a CLI that parses a single subcommand, prints
//! the version banner (proving both the `franky` and `websocket`
//! seams compile and link), and exits. Subsequent phases will
//! replace the body of `run` with real Socket Mode wiring.

const std = @import("std");
const franky = @import("franky");
const ws = @import("websocket");

const franky_do_slack = struct {
    pub const web_api = @import("slack/api.zig");
    pub const socket_mode = @import("slack/socket.zig");
};
pub const session_map = @import("session/manager.zig");
pub const agent_cache = @import("session/agent_cache.zig");
pub const agent_hibernate = @import("session/hibernation.zig");
pub const prompts_state = @import("prompts_state.zig");
pub const slack_prompts = @import("slack/prompts.zig");
pub const stream_subscriber = @import("subscribers/stream.zig");
pub const reactions_subscriber = @import("subscribers/reactions.zig");
pub const bot = @import("bot.zig");
pub const auth = @import("auth.zig");
pub const pricing = @import("pricing.zig");
pub const stats = @import("stats.zig");

pub const version = "0.5.5";

const usage =
    \\franky-do — Slack agent bot
    \\
    \\Usage:
    \\  franky-do --version
    \\  franky-do --help
    \\  franky-do install --workspace T... --xapp xapp-... --xoxb xoxb-...
    \\                                Persist Slack tokens for a workspace
    \\  franky-do uninstall --workspace T...
    \\                                Remove a workspace's stored tokens
    \\  franky-do list                Print all installed workspace IDs
    \\  franky-do run [--workspace T...] [--model <id>]
    \\                                Connect one workspace via Socket Mode
    \\  franky-do run --all           Connect every installed workspace in parallel
    \\  franky-do stats               Token usage + cost across persisted sessions
    \\
    \\Environment:
    \\  FRANKY_DO_HOME                Data dir (default: $HOME/.franky-do)
    \\  FRANKY_DO_PROFILE             Profile name (settings.json or built-in catalog) — selects provider + model + auth
    \\  FRANKY_DO_MODEL               Override the profile's model (e.g. gemini-2.5-flash). Default claude-sonnet-4-5.
    \\  FRANKY_DO_LOG                 Log level: err|warn|info|debug|trace (default: silent)
    \\  FRANKY_DO_LOG_FILE            Redirect log output from stderr to a file
    \\  FRANKY_CONNECT_TIMEOUT_MS     HTTP connect timeout (default 10000)
    \\  FRANKY_UPLOAD_TIMEOUT_MS      HTTP request-upload timeout (default 30000)
    \\  FRANKY_FIRST_BYTE_TIMEOUT_MS  HTTP first-byte timeout (default 30000) — bump for slow Ollama / cold starts
    \\  FRANKY_EVENT_GAP_TIMEOUT_MS   SSE inter-event gap timeout (default 30000)
    \\  ANTHROPIC_API_KEY             Bearer key for the Anthropic Messages API
    \\  CLAUDE_CODE_OAUTH_TOKEN       Subscription bearer (Claude Code) — alternative to API key
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // 0.17-dev: argv is collected through `std.process.Args.Iterator`
    // backed by the `init.minimal.args` array. Same shape franky's
    // own bin/main.zig uses.
    var args_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (args_list.items) |a| gpa.free(a);
        args_list.deinit(gpa);
    }
    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer it.deinit();
    while (it.next()) |raw| {
        try args_list.append(gpa, try gpa.dupe(u8, raw));
    }

    if (args_list.items.len < 2) {
        try writeStderr(io, usage);
        return;
    }
    const subcommand = args_list.items[1];

    if (std.mem.eql(u8, subcommand, "--version") or std.mem.eql(u8, subcommand, "-V")) {
        try writeVersionBanner(io);
        return;
    }
    if (std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        try writeStderr(io, usage);
        return;
    }
    if (std.mem.eql(u8, subcommand, "install")) {
        try cmdInstall(gpa, io, init.minimal.environ, args_list.items[2..]);
        return;
    }
    if (std.mem.eql(u8, subcommand, "uninstall")) {
        try cmdUninstall(gpa, io, init.minimal.environ, args_list.items[2..]);
        return;
    }
    if (std.mem.eql(u8, subcommand, "list")) {
        try cmdList(gpa, io, init.minimal.environ);
        return;
    }
    if (std.mem.eql(u8, subcommand, "run")) {
        try cmdRun(gpa, io, init.minimal.environ, init.environ_map, args_list.items[2..]);
        return;
    }
    if (std.mem.eql(u8, subcommand, "stats")) {
        try cmdStats(gpa, io, init.minimal.environ);
        return;
    }

    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "franky-do: unknown subcommand `{s}`\nrun `franky-do --help`\n", .{subcommand}) catch usage;
    try writeStderr(io, msg);
    std.process.exit(2);
}

// ── Subcommand handlers ──

const SubcommandError = error{
    MissingFlag,
    HomeUnknown,
} || std.mem.Allocator.Error;

fn cmdInstall(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    args: []const []const u8,
) !void {
    var workspace: ?[]const u8 = null;
    var xapp: ?[]const u8 = null;
    var xoxb: ?[]const u8 = null;
    var team_name: []const u8 = "";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--workspace") and i + 1 < args.len) {
            workspace = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--xapp") and i + 1 < args.len) {
            xapp = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--xoxb") and i + 1 < args.len) {
            xoxb = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--name") and i + 1 < args.len) {
            team_name = args[i + 1];
            i += 1;
        }
    }

    if (workspace == null or xapp == null or xoxb == null) {
        try writeStderr(io,
            \\install: missing flag(s)
            \\
            \\Required:
            \\  --workspace T...     Slack team ID
            \\  --xapp xapp-...      App-level token
            \\  --xoxb xoxb-...      Bot token
            \\Optional:
            \\  --name "Team Name"   Friendly team name
            \\
        );
        std.process.exit(2);
    }

    const home = try resolveHomeDir(gpa, environ);
    defer gpa.free(home);

    try auth.write(gpa, io, home, .{
        .team_id = workspace.?,
        .team_name = team_name,
        .app_token = xapp.?,
        .bot_token = xoxb.?,
        .installed_at_ms = franky.ai.stream.nowMillis(),
    });

    var msg_buf: [512]u8 = undefined;
    const msg = try std.fmt.bufPrint(
        &msg_buf,
        "Installed workspace {s} → {s}/workspaces/{s}/auth.json\n",
        .{ workspace.?, home, workspace.? },
    );
    try writeStdout(io, msg);
}

fn cmdUninstall(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    args: []const []const u8,
) !void {
    var workspace: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--workspace") and i + 1 < args.len) {
            workspace = args[i + 1];
            i += 1;
        }
    }
    if (workspace == null) {
        try writeStderr(io, "uninstall: missing --workspace T...\n");
        std.process.exit(2);
    }

    const home = try resolveHomeDir(gpa, environ);
    defer gpa.free(home);

    try auth.uninstall(gpa, io, home, workspace.?);

    var msg_buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "Uninstalled workspace {s}\n", .{workspace.?});
    try writeStdout(io, msg);
}

fn cmdList(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
) !void {
    const home = try resolveHomeDir(gpa, environ);
    defer gpa.free(home);

    const ids = try auth.list(gpa, io, home);
    defer auth.freeList(gpa, ids);

    if (ids.len == 0) {
        try writeStdout(io, "(no workspaces installed)\n");
        return;
    }
    for (ids) |id| {
        var line_buf: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "{s}\n", .{id});
        try writeStdout(io, line);
    }
}

// ── `franky-do stats` (Phase 8) ───────────────────────────────────

/// Aggregate token + cost stats across every persisted session
/// under `$FRANKY_DO_HOME/sessions/`. Output goes to stdout as a
/// Markdown-style table; pipe to a file for spreadsheet import.
fn cmdStats(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
) !void {
    const home = try resolveHomeDir(gpa, environ);
    defer gpa.free(home);

    var agg = try stats.collect(gpa, io, home);
    defer agg.deinit(gpa);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try stats.render(gpa, &out, &agg);
    try writeStdout(io, out.items);
}

// ── `franky-do run` ───────────────────────────────────────────────

const RunError = error{
    NoWorkspace,
    NoLlmCredentials,
} || std.mem.Allocator.Error;

/// Phase-6 entry point. Connects to Slack via Socket Mode, runs
/// the agent loop per `app_mention`, blocks until the WSS read
/// loop exits.
///
/// Workspace selection (in order):
///   1. `--workspace T...` flag → load `auth.json` from disk.
///   2. `SLACK_APP_TOKEN` + `SLACK_BOT_TOKEN` env vars → use those.
///
/// LLM auth (only Anthropic is wired in v0.1):
///   - `ANTHROPIC_API_KEY` env var (or `CLAUDE_CODE_OAUTH_TOKEN`).
///
/// Currently single-workspace per process; `--all` for parallel
/// multi-workspace operation is a Phase 6.x follow-up that just
/// spawns this same routine N times.
fn cmdRun(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
    args: []const []const u8,
) !void {
    // Diagnostic logging — gated on FRANKY_DO_LOG env var, off by
    // default. Reuses franky's leveled logger
    // (`franky.ai.log`); writes to stderr unless FRANKY_DO_LOG_FILE
    // points at a path. Useful levels:
    //   FRANKY_DO_LOG=info     — connect/disconnect, dispatch summary
    //   FRANKY_DO_LOG=debug    — every event type + envelope_id, dispatch decisions
    //   FRANKY_DO_LOG=trace    — full raw JSON of inbound payloads
    initLogging(io, environ);
    defer franky.ai.log.deinit();

    var workspace_arg: ?[]const u8 = null;
    var run_all = false;
    var model_arg: ?[]const u8 = null;
    // v0.3.2 — opt-OUT for the permission overlay (default true).
    // Tracks whether the user explicitly disabled prompts; the env
    // var is the second-priority signal.
    var no_prompts_flag = false;
    // v0.4.3 — opt-IN for "prompt for every tool, including the
    // default-auto_allow ones (read/ls/find/grep)". Flips
    // `Store.ask_all = true`. CLI flag has highest priority; env
    // var (`FRANKY_DO_ASK_ALL=1`) is the fallback.
    var ask_all_flag = false;
    // v0.4.7 — `--http-trace-dir <DIR>` mirror of franky CLI's flag.
    // When set, every provider call dumps the full request +
    // response to a file there for debugging. Borrowed slice into
    // argv (lives for the rest of the process). The env-var
    // fallback (`FRANKY_DO_HTTP_TRACE_DIR`) is read in
    // `resolveHttpTraceDirFromEnv` — flag wins.
    var http_trace_dir_arg: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--workspace") and i + 1 < args.len) {
            workspace_arg = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--all")) {
            run_all = true;
        } else if (std.mem.eql(u8, args[i], "--model") and i + 1 < args.len) {
            model_arg = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--no-prompts")) {
            no_prompts_flag = true;
        } else if (std.mem.eql(u8, args[i], "--ask-all")) {
            ask_all_flag = true;
        } else if (std.mem.eql(u8, args[i], "--http-trace-dir") and i + 1 < args.len) {
            http_trace_dir_arg = args[i + 1];
            i += 1;
        }
    }
    // v0.3.5 — `model_id` is now resolved via the profile chain
    // below (`sub_cfg.model` precedence: --model arg > FRANKY_DO_MODEL
    // env > FRANKY_DO_PROFILE → profile.model > built-in default).
    // `prompts_enabled` / `ask_all` are resolved inside
    // `setupAndRunBot` from the same flags, so we don't compute
    // them here.

    if (run_all) {
        // Logger already initialized at the top of cmdRun; runAll
        // spawns workers that share the same process-wide log state.
        try runAll(gpa, io, environ, environ_map);
        return;
    }

    // ── 1. resolve workspace tokens ──
    var maybe_loaded: ?auth.Auth = null;
    defer if (maybe_loaded) |*a| a.deinit(gpa);
    var bot_token: []const u8 = "";
    var app_token: []const u8 = "";

    if (workspace_arg) |team_id| {
        const home = try resolveHomeDir(gpa, environ);
        defer gpa.free(home);
        const loaded = auth.read(gpa, io, home, team_id) catch |e| switch (e) {
            error.NotInstalled => {
                try writeStderr(io, "run: workspace not installed; try `franky-do install --workspace ...`\n");
                std.process.exit(2);
            },
            else => return e,
        };
        bot_token = loaded.bot_token;
        app_token = loaded.app_token;
        maybe_loaded = loaded;
    } else if (environ.getPosix("SLACK_APP_TOKEN")) |xapp| {
        if (environ.getPosix("SLACK_BOT_TOKEN")) |xoxb| {
            app_token = xapp;
            bot_token = xoxb;
        } else {
            try writeStderr(io, "run: SLACK_APP_TOKEN set but SLACK_BOT_TOKEN missing\n");
            std.process.exit(2);
        }
    } else {
        try writeStderr(io,
            \\run: no Slack workspace configured.
            \\
            \\Either:
            \\  - install one with `franky-do install --workspace T... --xapp ... --xoxb ...`
            \\    then `franky-do run --workspace T...`
            \\  - or set $SLACK_APP_TOKEN + $SLACK_BOT_TOKEN.
            \\
        );
        std.process.exit(2);
    }

    // ── 2. (cred resolution moved to step 4, profile-driven) ──

    // ── 3. build Web API client + verify token via auth.test ──
    var api = franky_do_slack.web_api.Client.init(gpa, io, bot_token);
    defer api.deinit();
    api.app_token = app_token;
    // v0.3.9 — Slack web_api now honors HTTP_PROXY / HTTPS_PROXY /
    // NO_PROXY (and lowercase variants) via std.http.Client.initDefaultProxies,
    // same plumbing the LLM providers use. Wired by handing the
    // post-applyProfile environ_map to the Client.
    api.environ_map = environ_map;
    // v0.4.11 — Slack HTTP tracing piggybacks on the same
    // --http-trace-dir / FRANKY_DO_HTTP_TRACE_DIR knob that
    // captures LLM traffic. Resolve directly here (the flag was
    // parsed in argv-loop above; stream_opts isn't built yet).
    api.http_trace_dir = resolveHttpTraceDirFromEnv(environ_map, http_trace_dir_arg);

    var auth_test_resp = api.authTest() catch |e| {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &msg_buf,
            "run: auth.test failed: {s} (slack error: {s})\n",
            .{ @errorName(e), api.last_slack_error orelse "" },
        ) catch "run: auth.test failed\n";
        try writeStderr(io, msg);
        std.process.exit(2);
    };
    defer auth_test_resp.deinit();
    const bot_user_id = auth_test_resp.value.user_id orelse "";
    const team_id_log = auth_test_resp.value.team_id orelse "";
    var banner_buf: [256]u8 = undefined;
    const banner = std.fmt.bufPrint(
        &banner_buf,
        "franky-do connected: team_id={s} bot_user_id={s}\n",
        .{ team_id_log, bot_user_id },
    ) catch "franky-do connected\n";
    try writeStderr(io, banner);

    try setupAndRunBot(gpa, io, environ, environ_map, &api, bot_user_id, http_trace_dir_arg);
}

fn setupAndRunBot(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
    api: *franky_do_slack.web_api.Client,
    bot_user_id: []const u8,
    http_trace_dir_arg: ?[]const u8,
) !void {
    // ── 4. resolve provider via profile chain (v0.3.5) ──
    // Reads $FRANKY_DO_PROFILE → applies via franky's profile
    // system → resolveProviderIo returns provider_name + api_tag
    // + creds + model. $FRANKY_DO_MODEL still works (overrides
    // the profile's model).
    var sub_cfg: franky.coding.cli.Config = .{ .arena = std.heap.ArenaAllocator.init(gpa) };
    defer sub_cfg.deinit();

    const model_arg = environ.getPosix("FRANKY_DO_MODEL");
    if (model_arg) |m| if (m.len > 0) {
        sub_cfg.model = try sub_cfg.arena.allocator().dupe(u8, m);
    };
    const profile_name = environ.getPosix("FRANKY_DO_PROFILE");
    if (profile_name) |p| if (p.len > 0) {
        franky.coding.profiles.applyProfile(&sub_cfg, io, environ_map, p) catch |e| switch (e) {
            error.ProfileNotFound => {
                var msg_buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "run: profile '{s}' not found in settings.json or built-in catalog\n", .{p}) catch "run: profile not found\n";
                try writeStderr(io, msg);
                std.process.exit(2);
            },
            else => return e,
        };
    };
    if (sub_cfg.model == null) {
        sub_cfg.model = try sub_cfg.arena.allocator().dupe(u8, default_model_id);
    }
    const provider_info = try franky.coding.modes.print.resolveProviderIo(gpa, io, environ, &sub_cfg);

    var reg = franky.ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "anthropic-messages",
        .provider = "anthropic",
        .stream_fn = franky.ai.providers.anthropic.streamFn,
    });
    try reg.register(.{
        .api = "openai-chat-completions",
        .provider = "openai",
        .stream_fn = franky.ai.providers.openai_chat.streamFn,
    });
    try reg.register(.{
        .api = "openai-compatible-gateway",
        .provider = "gateway",
        .stream_fn = franky.ai.providers.openai_gateway.streamFn,
    });
    try reg.register(.{
        .api = "google-gemini",
        .provider = "google-gemini",
        .stream_fn = franky.ai.providers.google_gemini.streamFn,
    });

    // ── 5. assemble Bot config ──
    const tools_arr = [_]franky.agent.types.AgentTool{
        franky.coding.tools.read.tool(),
        franky.coding.tools.write.tool(),
        franky.coding.tools.edit.tool(),
        franky.coding.tools.ls.tool(),
        franky.coding.tools.find.tool(),
        franky.coding.tools.grep.tool(),
        franky.coding.tools.bash.tool(),
    };
    {
        // Audit-log the registered tool surface at info so operators
        // can confirm what the bot has wired without grepping source.
        var names: std.ArrayList(u8) = .empty;
        defer names.deinit(gpa);
        for (tools_arr, 0..) |t, idx| {
            if (idx > 0) names.append(gpa, ',') catch {};
            names.appendSlice(gpa, t.name) catch {};
        }
        franky.ai.log.log(.info, "franky-do", "tools", "count={d} names=[{s}]", .{
            tools_arr.len, names.items,
        });
    }

    var stream_opts: franky.ai.registry.StreamOptions = .{};
    stream_opts.api_key = provider_info.api_key;
    stream_opts.auth_token = provider_info.auth_token;
    stream_opts.base_url = provider_info.base_url;
    stream_opts.environ_map = environ_map;
    stream_opts.timeouts = resolveTimeoutsFromEnv(environ_map);
    stream_opts.http_trace_dir = resolveHttpTraceDirFromEnv(environ_map, http_trace_dir_arg);

    franky.ai.log.log(.info, "franky-do", "model", "model_id={s} provider={s} api={s}", .{
        provider_info.model_id, provider_info.provider_name, provider_info.api_tag,
    });
    franky.ai.log.log(.info, "franky-do", "timeouts", "connect={d}ms upload={d}ms first_byte={d}ms event_gap={d}ms", .{
        stream_opts.timeouts.connect_ms,
        stream_opts.timeouts.upload_ms,
        stream_opts.timeouts.first_byte_ms,
        stream_opts.timeouts.event_gap_ms,
    });
    if (stream_opts.http_trace_dir) |d| {
        franky.ai.log.log(.info, "franky-do", "http_trace", "dir={s}", .{d});
    } else {
        franky.ai.log.log(.debug, "franky-do", "http_trace", "disabled (set --http-trace-dir or FRANKY_DO_HTTP_TRACE_DIR to enable)", .{});
    }
    var bot_inst = bot.Bot.init(gpa, io, api, .{
        .model_id = provider_info.model_id,
        .model_provider = provider_info.provider_name,
        .model_api = provider_info.api_tag,
        .model_context_window = provider_info.context_window,
        .model_max_output = provider_info.max_output,
        .model_capabilities = provider_info.capabilities,
        .system_prompt =
        \\You are franky-do, a coding assistant in a Slack thread.
        \\Reply in plain text. Do not use markdown headings, asterisks
        \\for bold, underscores for italic, or bullet markers — Slack's
        \\mrkdwn dialect renders them inconsistently. Use blank lines
        \\to separate paragraphs. Triple-backtick code fences are OK
        \\(Slack renders them).
        \\
        \\Keep replies concise. Slack rejects messages over ~3000 chars,
        \\so franky-do automatically converts longer outputs into a
        \\file attachment in the thread. When you have a long answer
        \\(big diffs, multi-section reports, full file dumps), write a
        \\short 1-2 sentence preamble summarizing the result; the full
        \\detail will appear as an attached file the user can open
        \\inline.
        ,
        .registry = &reg,
        .tools = &tools_arr,
        .stream_options = stream_opts,
    });
    defer bot_inst.deinit();

    const no_prompts_flag = false;
    const ask_all_flag = false;
    const prompts_enabled = resolvePromptsEnabled(environ_map, no_prompts_flag);
    const ask_all = resolveAskAll(environ_map, ask_all_flag);

    bot_inst.prompts_enabled = prompts_enabled;
    var permission_store_owned: ?*franky.coding.permissions.Store = null;
    defer if (permission_store_owned) |s| freePermissionStore(gpa, s);
    if (prompts_enabled) {
        const home = try resolveHomeDir(gpa, environ);
        defer gpa.free(home);
        permission_store_owned = try initPermissionStore(gpa, io, environ_map, home, ask_all);
        bot_inst.permission_store = permission_store_owned;
        franky.ai.log.log(.info, "franky-do", "permissions", "store ready remember={s} ask_all={s} path={s}", .{
            if (resolveRememberPermissions(environ_map)) "yes" else "no",
            if (ask_all) "yes" else "no",
            permission_store_owned.?.persist_path orelse "(in-memory only)",
        });
    } else {
        franky.ai.log.log(.info, "franky-do", "permissions", "prompts disabled (--no-prompts / FRANKY_DO_PROMPTS=0)", .{});
    }

    try bot_inst.setBotUserId(bot_user_id);
    bot_inst.prompt_timeout_ms = resolvePromptTimeoutMs(environ_map);
    if (prompts_enabled) {
        franky.ai.log.log(.info, "franky-do", "prompts", "prompt_timeout_ms={d}", .{bot_inst.prompt_timeout_ms});
    }

    const knobs = resolveHibernationKnobs(environ_map);
    bot_inst.agents.cap = knobs.cache_size;
    franky.ai.log.log(.info, "franky-do", "hibernation", "cache_size={d} idle_eviction_ms={d} sweeper_interval_ms={d}", .{
        knobs.cache_size, knobs.idle_eviction_ms, knobs.sweeper_interval_ms,
    });

    var sweeper_stop = std.atomic.Value(bool).init(false);
    const sweeper_args: SweeperArgs = .{
        .bot_ptr = &bot_inst,
        .interval_ms = knobs.sweeper_interval_ms,
        .idle_ms = knobs.idle_eviction_ms,
        .stop_flag = &sweeper_stop,
    };
    const sweeper_thread = try std.Thread.spawn(.{}, sweeperMain, .{sweeper_args});
    defer {
        sweeper_stop.store(true, .release);
        sweeper_thread.join();
    }

    // ── 6. socket mode + dispatcher wiring ──
    var sm = franky_do_slack.socket_mode.SocketMode.init(gpa, io, api);
    defer sm.deinit();

    const Dispatch = struct {
        bot_ptr: *bot.Bot,
        bot_user_id_owned: []const u8,
    };
    const dispatch_state = try gpa.create(Dispatch);
    defer gpa.destroy(dispatch_state);
    const bot_user_id_dup = try gpa.dupe(u8, bot_user_id);
    defer gpa.free(bot_user_id_dup);
    dispatch_state.* = .{ .bot_ptr = &bot_inst, .bot_user_id_owned = bot_user_id_dup };

    sm.on_event_userdata = @ptrCast(dispatch_state);
    sm.on_event = struct {
        fn cb(ud: ?*anyopaque, ev: franky_do_slack.socket_mode.InboundEvent) void {
            const ds: *Dispatch = @ptrCast(@alignCast(ud.?));
            franky.ai.log.log(.debug, "franky-do", "inbound", "type={s} envelope_id={s} bytes={d}", .{
                @tagName(ev.type),
                if (ev.envelope_id.len > 0) ev.envelope_id else "(none)",
                ev.raw_json.len,
            });
            franky.ai.log.log(.trace, "franky-do", "inbound_raw", "{s}", .{ev.raw_json});
            switch (ev.type) {
                .events_api => ds.bot_ptr.dispatchSlackEvent(ds.bot_user_id_owned, ev.raw_json) catch |e|
                    franky.ai.log.log(.warn, "franky-do", "dispatch", "events_api dispatch failed: {s}", .{@errorName(e)}),
                .slash_commands => ds.bot_ptr.dispatchSlashCommand(ev.raw_json) catch |e|
                    franky.ai.log.log(.warn, "franky-do", "dispatch", "slash_commands dispatch failed: {s}", .{@errorName(e)}),
                .interactive => ds.bot_ptr.dispatchInteractive(ev.raw_json) catch |e|
                    franky.ai.log.log(.warn, "franky-do", "dispatch", "interactive dispatch failed: {s}", .{@errorName(e)}),
                else => franky.ai.log.log(.debug, "franky-do", "dispatch", "dropped: type={s}", .{@tagName(ev.type)}),
            }
        }
    }.cb;

    // ── 7. open WSS, run loop ──
    sm.connect() catch |e| {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &msg_buf,
            "run: socket mode connect failed: {s}\n",
            .{@errorName(e)},
        ) catch "run: socket mode connect failed\n";
        try writeStderr(io, msg);
        std.process.exit(2);
    };
    try writeStderr(io, "franky-do listening on Slack Socket Mode (Ctrl-C to quit)\n");
    sm.run() catch |e| {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &msg_buf,
            "run: read loop exited: {s}\n",
            .{@errorName(e)},
        ) catch "run: read loop exited\n";
        try writeStderr(io, msg);
    };
}



/// `--all` mode: enumerate installed workspaces, spawn a thread
/// per workspace, each running its own socket-mode read loop.
/// Block main thread until every worker exits.
///
/// Each per-workspace thread has its own api Client / Bot /
/// SocketMode — no shared mutable state. The Anthropic registry
/// is stateless after registration, so we share a single one.
fn runAll(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
) !void {
    const home = try resolveHomeDir(gpa, environ);
    defer gpa.free(home);

    const ids = try auth.list(gpa, io, home);
    defer auth.freeList(gpa, ids);

    if (ids.len == 0) {
        try writeStderr(io, "run --all: no workspaces installed.\n");
        std.process.exit(2);
    }

    var threads: std.ArrayList(std.Thread) = .empty;
    defer threads.deinit(gpa);

    for (ids) |team_id| {
        const args = try gpa.create(WorkspaceWorkerArgs);
        args.* = .{
            .gpa = gpa,
            .io = io,
            .environ = environ,
            .environ_map = environ_map,
            .home = home,
            .team_id = try gpa.dupe(u8, team_id),
        };
        const t = try std.Thread.spawn(.{}, workspaceWorker, .{args});
        try threads.append(gpa, t);
    }

    var msg_buf: [128]u8 = undefined;
    const msg = try std.fmt.bufPrint(
        &msg_buf,
        "franky-do run --all: {d} workspace(s) running. Ctrl-C to quit.\n",
        .{ids.len},
    );
    try writeStderr(io, msg);

    for (threads.items) |t| t.join();
}

const WorkspaceWorkerArgs = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
    home: []const u8,
    team_id: []u8,
};

fn workspaceWorker(args: *WorkspaceWorkerArgs) void {
    defer {
        args.gpa.free(args.team_id);
        args.gpa.destroy(args);
    }
    runForInstalledWorkspace(
        args.gpa,
        args.io,
        args.environ,
        args.environ_map,
        args.home,
        args.team_id,
    ) catch {};
}

/// Per-workspace run path. Mirrors `cmdRun`'s single-workspace
/// flow but with the workspace already resolved on disk and
/// LLM creds pulled from process env.
fn runForInstalledWorkspace(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
    home: []const u8,
    team_id: []const u8,
) !void {
    var loaded = auth.read(gpa, io, home, team_id) catch return;
    defer loaded.deinit(gpa);

    var api = franky_do_slack.web_api.Client.init(gpa, io, loaded.bot_token);
    defer api.deinit();
    api.app_token = loaded.app_token;
    // v0.3.9 — same proxy wiring as cmdRun.
    api.environ_map = environ_map;
    // v0.4.11 — Slack HTTP tracing wired via env (no per-workspace
    // flag in `--all` mode).
    api.http_trace_dir = resolveHttpTraceDirFromEnv(environ_map, null);

    var auth_test_resp = api.authTest() catch return;
    defer auth_test_resp.deinit();
    const bot_user_id = auth_test_resp.value.user_id orelse "";

    try setupAndRunBot(gpa, io, environ, environ_map, &api, bot_user_id, null);
}

/// `$FRANKY_DO_HOME` if set, else `$HOME/.franky-do`. Returned
/// slice is allocator-owned. Errors only when neither is set.
fn resolveHomeDir(allocator: std.mem.Allocator, environ: std.process.Environ) ![]u8 {
    if (environ.getPosix("FRANKY_DO_HOME")) |h| return try allocator.dupe(u8, h);
    if (environ.getPosix("HOME")) |h| {
        return try std.fmt.allocPrint(allocator, "{s}/.franky-do", .{h});
    }
    return SubcommandError.HomeUnknown;
}

fn writeVersionBanner(io: std.Io) !void {
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf,
        "franky-do {s} (franky {s}, websocket.zig vendored)\n",
        .{ version, franky.version },
    );
    try writeStdout(io, msg);
}

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    var wbuf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &wbuf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

fn writeStderr(io: std.Io, bytes: []const u8) !void {
    var wbuf: [256]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &wbuf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

/// v0.3.1 — session-hibernation knobs, all env-overridable.
const default_agent_cache_size: u32 = 16;
const default_idle_eviction_ms: u64 = 30 * 60 * 1000; // 30 min
const default_sweeper_interval_ms: u64 = 5 * 60 * 1000; // 5 min

const HibernationKnobs = struct {
    cache_size: u32,
    idle_eviction_ms: u64,
    sweeper_interval_ms: u64,
};

/// v0.3.6 — read from environ_map (the post-applyProfile view)
/// instead of `environ` (the immutable POSIX block) so a
/// profile's `env: {}` block can override these knobs.
fn resolveHibernationKnobs(environ_map: *const std.process.Environ.Map) HibernationKnobs {
    const cache_size = parseEnvU32(environ_map, "FRANKY_DO_AGENT_CACHE_SIZE") orelse default_agent_cache_size;
    const idle = parseEnvU64(environ_map, "FRANKY_DO_IDLE_EVICTION_MS") orelse default_idle_eviction_ms;
    const sweep = parseEnvU64(environ_map, "FRANKY_DO_SWEEPER_INTERVAL_MS") orelse default_sweeper_interval_ms;
    return .{ .cache_size = cache_size, .idle_eviction_ms = idle, .sweeper_interval_ms = sweep };
}

fn parseEnvU32(environ_map: *const std.process.Environ.Map, key: []const u8) ?u32 {
    const v = environ_map.get(key) orelse return null;
    return std.fmt.parseInt(u32, v, 10) catch null;
}

fn parseEnvU64(environ_map: *const std.process.Environ.Map, key: []const u8) ?u64 {
    const v = environ_map.get(key) orelse return null;
    return std.fmt.parseInt(u64, v, 10) catch null;
}

/// v0.3.1 — sweeper thread. Wakes every `sweeper_interval_ms`,
/// pops idle entries from the bot's agent cache, persists each,
/// drops. Runs until `stop_flag` is set; main process flips it on
/// shutdown.
const SweeperArgs = struct {
    bot_ptr: *bot.Bot,
    interval_ms: u64,
    idle_ms: u64,
    stop_flag: *std.atomic.Value(bool),
};

fn sweeperMain(args: SweeperArgs) void {
    while (!args.stop_flag.load(.acquire)) {
        nanoSleepInterruptible(args.interval_ms, args.stop_flag);
        if (args.stop_flag.load(.acquire)) break;
        const victims = args.bot_ptr.agents.popIdleOlderThan(args.idle_ms) catch |e| {
            franky.ai.log.log(.warn, "franky-do", "sweeper", "popIdleOlderThan failed: {s}", .{@errorName(e)});
            continue;
        };
        defer args.bot_ptr.allocator.free(victims);
        for (victims) |v| args.bot_ptr.persistAndFreeVictim(v);
        if (victims.len > 0) {
            franky.ai.log.log(.info, "franky-do", "sweeper", "evicted+persisted {d} idle session(s)", .{victims.len});
        }
    }
}

/// Sleep `ms` milliseconds in 100-ms slices, checking `stop_flag`
/// each slice so shutdown is responsive.
fn nanoSleepInterruptible(ms: u64, stop_flag: *std.atomic.Value(bool)) void {
    const slice_ms: u64 = 100;
    var remaining: u64 = ms;
    while (remaining > 0) {
        if (stop_flag.load(.acquire)) return;
        const this_slice: u64 = @min(remaining, slice_ms);
        if (@import("builtin").link_libc) {
            const sec_u64: u64 = this_slice / @as(u64, 1000);
            const ms_remainder: u64 = this_slice - (sec_u64 * @as(u64, 1000));
            const nsec_u64: u64 = ms_remainder * @as(u64, std.time.ns_per_ms);
            const ts = std.c.timespec{
                .sec = @intCast(sec_u64),
                .nsec = @intCast(nsec_u64),
            };
            _ = std.c.nanosleep(&ts, null);
        } else {
            const start = franky.ai.stream.nowMillis();
            const deadline = start + @as(i64, @intCast(this_slice));
            while (franky.ai.stream.nowMillis() < deadline) {}
        }
        remaining -|= this_slice;
    }
}

/// Built-in default model id, used when no `--model` flag and no
/// `FRANKY_DO_MODEL` env var is set.
const default_model_id: []const u8 = "claude-sonnet-4-5";

/// v0.3.2 — opt-out resolver for the permission overlay (design
/// §B.3.1). Default = enabled. Disabled when EITHER the
/// `--no-prompts` CLI flag is set OR `FRANKY_DO_PROMPTS=0` is in
/// the env.
fn resolvePromptsEnabled(environ_map: *const std.process.Environ.Map, no_prompts_flag: bool) bool {
    if (no_prompts_flag) return false;
    if (environ_map.get("FRANKY_DO_PROMPTS")) |v|
        if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false")) return false;
    return true;
}

/// v0.4.7 — resolver for `--http-trace-dir <DIR>` /
/// `FRANKY_DO_HTTP_TRACE_DIR` env. Mirror of franky CLI's flag.
/// The CLI flag wins; the env var is the fallback; both empty
/// → null (disabled).
///
/// Returned slice's lifetime: when the flag is set, the slice
/// borrows from argv (which lives for the process lifetime).
/// When the env var is the source, the slice borrows from
/// `environ_map`'s storage (also process-lifetime). Both are
/// safe to hand to the long-lived `stream_options` without
/// duping.
fn resolveHttpTraceDirFromEnv(
    environ_map: *const std.process.Environ.Map,
    flag: ?[]const u8,
) ?[]const u8 {
    if (flag) |v| if (v.len > 0) return v;
    if (environ_map.get("FRANKY_DO_HTTP_TRACE_DIR")) |v| if (v.len > 0) return v;
    return null;
}

/// v0.4.3 — opt-in resolver for `Store.ask_all`. Default =
/// disabled (current behavior preserved). The CLI flag
/// `--ask-all` wins; otherwise the env var
/// `FRANKY_DO_ASK_ALL=1` (or `=true`) flips it on. Anything else
/// (including the env var being absent) leaves it disabled.
///
/// Effect when enabled: every default-auto_allow tool
/// (`read`/`ls`/`find`/`grep`) demotes to "ask" and surfaces a
/// Slack permission prompt on each call, exactly like
/// `write`/`edit`/`bash` already do.
fn resolveAskAll(environ_map: *const std.process.Environ.Map, flag: bool) bool {
    if (flag) return true;
    if (environ_map.get("FRANKY_DO_ASK_ALL")) |v|
        if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true")) return true;
    return false;
}

/// v0.3.3 — per-prompt timeout resolver (design §B.3.3). Default
/// = 600_000 ms (10 minutes). Override via
/// `FRANKY_DO_PROMPT_TIMEOUT_MS`. Values <1000ms are clamped to
/// 1000ms (so a typo'd `100` doesn't auto-deny faster than the
/// drain thread can post the prompt).
fn resolvePromptTimeoutMs(environ_map: *const std.process.Environ.Map) u64 {
    const default_ms: u64 = 600_000;
    const v = environ_map.get("FRANKY_DO_PROMPT_TIMEOUT_MS") orelse return default_ms;
    const parsed = std.fmt.parseInt(u64, v, 10) catch return default_ms;
    if (parsed < 1000) return 1000;
    return parsed;
}

/// v0.3.2 — opt-out resolver for permissions persistence (design
/// §B.3.5). Default = enabled. Disabled when
/// `FRANKY_DO_REMEMBER_PERMISSIONS=0` is set.
fn resolveRememberPermissions(environ_map: *const std.process.Environ.Map) bool {
    if (environ_map.get("FRANKY_DO_REMEMBER_PERMISSIONS")) |v|
        if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false")) return false;
    return true;
}

/// v0.3.2 — initialize a permission `Store` for a bot. The Store is
/// workspace-wide (one per bot process) per design §B.3.5.
///
/// v0.4.3 — `ask_all` flips `Store.ask_all` so every
/// default-auto_allow tool (`read`/`ls`/`find`/`grep`) demotes to
/// "ask" and prompts in Slack like `write`/`edit`/`bash` already
/// do. `always_allow` entries still take precedence — flipping a
/// tool to ⏩ "always allow" once silences subsequent prompts for
/// that tool just like usual. The CSV-driven equivalents
/// (`--allow-tools` / `--deny-tools` / `--ask-tools <csv>`) are
/// still post-1.0 follow-ups; v0.4.3 ships the all-or-nothing
/// shape because that's the most common operator request.
fn initPermissionStore(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    home_dir: []const u8,
    ask_all: bool,
) !*franky.coding.permissions.Store {
    const store = try gpa.create(franky.coding.permissions.Store);
    errdefer gpa.destroy(store);
    store.* = franky.coding.permissions.Store.init(gpa);
    errdefer store.deinit();

    // v0.4.3 — runtime-only flag (NOT persisted in
    // permissions.json), matching franky CLI's `--ask-tools all`
    // semantics. Operator opts in per-run via
    // `--ask-all` / `FRANKY_DO_ASK_ALL=1`.
    store.ask_all = ask_all;

    if (resolveRememberPermissions(environ_map)) {
        const path = try std.fmt.allocPrint(gpa, "{s}/permissions.json", .{home_dir});
        // The path lives as long as the store; transferred to
        // store.persist_path. Caller frees both on bot deinit
        // via `freePermissionStore`.
        _ = franky.coding.permissions.loadFromDisk(store, gpa, io, path) catch |e| {
            franky.ai.log.log(.warn, "franky-do", "permissions", "loadFromDisk failed: {s}", .{@errorName(e)});
        };
        store.persist_path = path;
        store.persist_io = io;
    }

    return store;
}

fn freePermissionStore(gpa: std.mem.Allocator, store: *franky.coding.permissions.Store) void {
    if (store.persist_path) |p| gpa.free(p);
    store.deinit();
    gpa.destroy(store);
}

/// Read the four `FRANKY_*_TIMEOUT_MS` env vars (same names franky's
/// CLI reads via `print.resolveTimeoutsFromMap`) into a `Timeouts`
/// struct. Unset vars keep the registry's built-in defaults
/// (currently 10 s connect / 30 s upload / 30 s first-byte / 30 s
/// event-gap).
///
/// Important for slow self-hosted endpoints (Ollama under heavy
/// thinking, Cloudflare cold starts) — without this the bot
/// silently times out at 30 s while the model is still warming up.
fn resolveTimeoutsFromEnv(environ_map: *const std.process.Environ.Map) franky.ai.registry.Timeouts {
    var t: franky.ai.registry.Timeouts = .{};
    if (environ_map.get("FRANKY_CONNECT_TIMEOUT_MS")) |v|
        if (std.fmt.parseInt(u32, v, 10) catch null) |n| {
            t.connect_ms = n;
        };
    if (environ_map.get("FRANKY_UPLOAD_TIMEOUT_MS")) |v|
        if (std.fmt.parseInt(u32, v, 10) catch null) |n| {
            t.upload_ms = n;
        };
    if (environ_map.get("FRANKY_FIRST_BYTE_TIMEOUT_MS")) |v|
        if (std.fmt.parseInt(u32, v, 10) catch null) |n| {
            t.first_byte_ms = n;
        };
    if (environ_map.get("FRANKY_EVENT_GAP_TIMEOUT_MS")) |v|
        if (std.fmt.parseInt(u32, v, 10) catch null) |n| {
            t.event_gap_ms = n;
        };
    return t;
}

/// Initialize `franky.ai.log` from env. Off by default; opt-in via
/// FRANKY_DO_LOG=info|debug|trace. FRANKY_DO_LOG_FILE redirects
/// from stderr to a path if set.
fn initLogging(io: std.Io, environ: std.process.Environ) void {
    const level_str = environ.getPosix("FRANKY_DO_LOG") orelse return;
    const level = franky.ai.log.Level.fromString(level_str) orelse {
        writeStderr(io, "FRANKY_DO_LOG: unrecognized level (use err/warn/info/debug/trace)\n") catch {};
        return;
    };
    if (environ.getPosix("FRANKY_DO_LOG_FILE")) |path| {
        franky.ai.log.initWithFile(io, level, path) catch {
            writeStderr(io, "FRANKY_DO_LOG_FILE: open failed; falling back to stderr\n") catch {};
            franky.ai.log.init(io, level);
        };
    } else {
        franky.ai.log.init(io, level);
    }
    franky.ai.log.log(.info, "franky-do", "log_init", "level={s}", .{level_str});
}

// ── Phase 0 smoke tests ──

const testing = std.testing;

test "phase 0: franky.sdk is reachable through the dependency seam" {
    // Concretely: this proves `franky.sdk` exposes the named types
    // we'll need in Phase 3+. If the SDK facade is missing or
    // mis-named, this fails at compile time before runtime.
    _ = franky.sdk.Agent;
    _ = franky.sdk.Transcript;
    _ = franky.sdk.Registry;
    _ = franky.sdk.Channel;
}

test "phase 0: websocket library is reachable" {
    // Same proof for the WSS dependency. We don't construct a
    // Client here (that'd open a socket); we just reference the
    // top-level types so the import is exercised.
    _ = ws.Client;
}

test "phase 0: franky version is a non-empty string" {
    try testing.expect(franky.version.len > 0);
    // Sanity: matches semver-ish shape `<digit>.<digit>...`.
    try testing.expect(std.mem.indexOfScalar(u8, franky.version, '.') != null);
}

test "phase 0: our own version constant is set" {
    try testing.expectEqualStrings("0.5.5", version);
}

// ─── v0.4.3 — resolveAskAll precedence tests ──────────────────────

test "resolveAskAll: default off, env unset" {
    const gpa = testing.allocator;
    var m: std.process.Environ.Map = .init(gpa);
    defer m.deinit();
    try testing.expect(!resolveAskAll(&m, false));
}

test "resolveAskAll: env=1 enables" {
    const gpa = testing.allocator;
    var m: std.process.Environ.Map = .init(gpa);
    defer m.deinit();
    try m.put("FRANKY_DO_ASK_ALL", "1");
    try testing.expect(resolveAskAll(&m, false));
}

test "resolveAskAll: env=true enables" {
    const gpa = testing.allocator;
    var m: std.process.Environ.Map = .init(gpa);
    defer m.deinit();
    try m.put("FRANKY_DO_ASK_ALL", "true");
    try testing.expect(resolveAskAll(&m, false));
}

test "resolveAskAll: env=anything-else stays off" {
    const gpa = testing.allocator;
    var m: std.process.Environ.Map = .init(gpa);
    defer m.deinit();
    try m.put("FRANKY_DO_ASK_ALL", "yes");
    try testing.expect(!resolveAskAll(&m, false));
    try m.put("FRANKY_DO_ASK_ALL", "0");
    try testing.expect(!resolveAskAll(&m, false));
}

test "resolveAskAll: --ask-all flag wins over env=0" {
    const gpa = testing.allocator;
    var m: std.process.Environ.Map = .init(gpa);
    defer m.deinit();
    try m.put("FRANKY_DO_ASK_ALL", "0");
    try testing.expect(resolveAskAll(&m, true));
}

// ─── v0.4.7 — resolveHttpTraceDirFromEnv tests ──────────────────────

test "resolveHttpTraceDirFromEnv: default null when flag + env both absent" {
    const gpa = testing.allocator;
    var m: std.process.Environ.Map = .init(gpa);
    defer m.deinit();
    try testing.expect(resolveHttpTraceDirFromEnv(&m, null) == null);
}

test "resolveHttpTraceDirFromEnv: flag wins over env" {
    const gpa = testing.allocator;
    var m: std.process.Environ.Map = .init(gpa);
    defer m.deinit();
    try m.put("FRANKY_DO_HTTP_TRACE_DIR", "/from/env");
    const got = resolveHttpTraceDirFromEnv(&m, "/from/flag") orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/from/flag", got);
}

test "resolveHttpTraceDirFromEnv: env used when flag is null" {
    const gpa = testing.allocator;
    var m: std.process.Environ.Map = .init(gpa);
    defer m.deinit();
    try m.put("FRANKY_DO_HTTP_TRACE_DIR", "/tmp/franky-do-trace");
    const got = resolveHttpTraceDirFromEnv(&m, null) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("/tmp/franky-do-trace", got);
}

test "resolveHttpTraceDirFromEnv: empty flag + empty env → null" {
    const gpa = testing.allocator;
    var m: std.process.Environ.Map = .init(gpa);
    defer m.deinit();
    try m.put("FRANKY_DO_HTTP_TRACE_DIR", "");
    try testing.expect(resolveHttpTraceDirFromEnv(&m, "") == null);
}

// Pull in submodule tests via the public namespace.
test {
    _ = franky_do_slack.web_api;
    _ = franky_do_slack.socket_mode;
    _ = session_map;
    _ = agent_cache;
    _ = agent_hibernate;
    _ = prompts_state;
    _ = slack_prompts;
    _ = stream_subscriber;
    _ = reactions_subscriber;
    _ = bot;
    _ = auth;
}
