const std = @import("std");
const upower = @import("upower.zig");

const c = @cImport({
    @cInclude("stdlib.h");
});

pub const MAX_RULES = 32;

pub const WhenStatus = enum {
    charged,
    discharged,

    pub fn fromString(s: []const u8) ?WhenStatus {
        if (std.mem.eql(u8, s, "charged") or
            std.mem.eql(u8, s, "charge") or
            std.mem.eql(u8, s, "charging"))
        {
            return .charged;
        }
        if (std.mem.eql(u8, s, "discharged") or
            std.mem.eql(u8, s, "discharge") or
            std.mem.eql(u8, s, "discharging"))
        {
            return .discharged;
        }
        return null;
    }

    pub fn matches(self: WhenStatus, device_state: upower.UPowerDeviceState) bool {
        return switch (self) {
            .charged => device_state == .UPOWER_DEVICE_STATE_CHARGING or
                device_state == .UPOWER_DEVICE_STATE_FULLY_CHARGED,
            .discharged => device_state == .UPOWER_DEVICE_STATE_DISCHARGING or
                device_state == .UPOWER_DEVICE_STATE_EMPTY,
        };
    }
};

pub const WhenRule = struct {
    status: WhenStatus,
    percentage: u8,
    command: [:0]const u8,
    triggered: bool = false,

    pub fn check(self: *const WhenRule, device_state: upower.UPowerDeviceState, percentage: f64) bool {
        const status_matches = self.status.matches(device_state);
        const pct_matches = switch (self.status) {
            .charged => percentage >= @as(f64, @floatFromInt(self.percentage)),
            .discharged => percentage <= @as(f64, @floatFromInt(self.percentage)),
        };
        return status_matches and pct_matches;
    }

    pub fn execute(self: *const WhenRule) void {
        std.debug.print("executing when rule command: {s}\n", .{self.command});
        _ = c.system(self.command.ptr);
    }
};
