const std = @import("std");
const client = @import("src/slack/api.zig");
const reactions_subscriber = @import("src/subscribers/reactions.zig");

/// Central dispatcher for all agent events.
/// This module ensures that agent status changes are reflected in the Slack UI
/// via the ReactionsSubscriber before any core business logic is applied.
pub const EventDispatcher = struct {
    allocator: std.mem.Allocator,
    api: client.Client,
    /// The subscriber instance, which holds the state (current emoji, target TS).
    reactions: reactions_subscriber.ReactionsSubscriber,

    pub fn init(allocator: std.mem.Allocator, api: client.Client) EventDispatcher {
        return .{
            .allocator = allocator,
            .api = api,
            .reactions = reactions_subscriber.ReactionsSubscriber{
                .allocator = allocator,
                .api = api,
            },
        };
    }

    /// Runs the core dispatch logic. This function MUST be called at the start
    /// of processing any agent event.
    ///
    /// It manages the initial capture of the user's @-mention timestamp and
    /// subsequently hands off status updates to the dedicated ReactionsSubscriber.
    pub fn dispatch(
        self: *EventDispatcher,
        event_type: []const u8,
        event_data: anyconst struct{}, // Contains message data, timestamp, etc.
    ) !void {
        // 1. Handle the initial @-mention timestamp capture.
        if (std.mem.eql(u8, event_type, "app_mention")) {
            // We assume the event_data contains the message `ts` field.
            // NOTE: This relies on passing a specific structure into `dispatch`.
            // For this placeholder, we'll assume we can extract the timestamp T.
            const ts = try? std.mem.getString(
                self.allocator, 
                event_data, 
                "ts"
            );
            self.reactions.user_mention_ts = ?[](const u8){ ts };
            // Initial status set by handler later.
        }

        // 2. Delegate the status handling to the Reaction Subscriber.
        // Since `handleAgentEvent` expects a specific, event-matching structure,
        // we'll pass a placeholder event object that only matches eventType.
        const dummy_event_struct = struct {
            eventType: []const u8,
            metadata: anyconst type{},
        }{
            .eventType = event_type,
        };

        try reactions_subscriber.handleAgentEvent(
            self.allocator,
            &self.reactions,
            &dummy_event_struct,
        );
    }
};
