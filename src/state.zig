const std = @import("std");
const upower = @import("upower.zig");

const StateError =
    std.mem.Allocator.Error;

pub fn init(allocator: std.mem.Allocator) StateError!*State {
    const state = try allocator.create(State);
    state.* = State{
        .allocator = allocator,
        .devices = std.ArrayListUnmanaged(*upower.UPowerDevice){},
        .removed_devices = std.ArrayListUnmanaged(*upower.UPowerDevice){},
    };

    return state;
}

pub const State = struct {
    allocator: std.mem.Allocator,
    devices: std.ArrayListUnmanaged(*upower.UPowerDevice),
    removed_devices: std.ArrayListUnmanaged(*upower.UPowerDevice),

    pub fn deinit(self: *State) void {
        for (self.devices.items) |device| {
            device.deinit();
        }
        self.devices.deinit(self.allocator);
        for (self.removed_devices.items) |device| {
            device.deinit();
        }
        self.removed_devices.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn addDevice(self: *State, p: [*c]const u8) !*upower.UPowerDevice {
        std.debug.print("addDevice with path: {s}\n", .{p});

        const device = try upower.init(self.allocator, p);
        try self.devices.append(self.allocator, device);

        std.debug.print("device added!\n", .{});
        return device;
    }

    pub fn removeDevice(self: *State, idx: usize) !*upower.UPowerDevice {
        return self.devices.orderedRemove(idx);
    }
};
