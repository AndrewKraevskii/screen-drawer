const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn History(comptime Event: type) type {
    return struct {
        events: std.ArrayListUnmanaged(Event) = .{},
        undone: usize = 0,

        pub fn undo(history: *@This()) ?Event {
            std.debug.assert(history.undone <= history.events.items.len);
            if (history.undone == history.events.items.len) {
                return null;
            }
            history.undone += 1;

            return history.events.items[history.events.items.len - history.undone];
        }

        pub fn redo(history: *@This()) ?Event {
            if (history.undone == 0) return null;
            const event_to_redo = history.events.items[history.events.items.len - history.undone];
            history.undone -= 1;
            return event_to_redo;
        }

        pub fn addHistoryEntry(
            history: *@This(),
            gpa: Allocator,
            entry: Event,
        ) !void {
            if (history.undone != 0) {
                history.events.shrinkRetainingCapacity(history.events.items.len - history.undone);
                history.undone = 0;
            }

            try history.events.append(
                gpa,
                entry,
            );
        }

        pub fn deinit(history: *@This(), gpa: Allocator) void {
            history.events.deinit(gpa);
        }
    };
}
