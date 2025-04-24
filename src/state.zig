const std = @import("std");
const upower = @import("upower.zig");

const StateError =
    std.mem.Allocator.Error;

pub fn init(allocator: std.mem.Allocator) StateError!*State {
    const state = try allocator.create(State);
    state.* = State{
        .allocator = allocator,
        .devices = std.ArrayListUnmanaged(upower.UPowerDevice){},
        .removed_devices = std.ArrayListUnmanaged(upower.UPowerDevice){},
    };

    return state;
}

pub const State = struct {
    allocator: std.mem.Allocator,
    devices: std.ArrayListUnmanaged(upower.UPowerDevice),
    removed_devices: std.ArrayListUnmanaged(upower.UPowerDevice),

    pub fn deinit(self: *State) void {
        self.allocator.destroy(self);
    }
};
