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

    pub fn addDevice(self: *State, p: [*c]const u8) !upower.UPowerDevice {
        std.debug.print("addDevice with path: {s}", .{p});
        const device = blk: {
            const props = upower.UPowerDeviceProps{
                .generation = 1,
                .online = 1,
                .percentage = 100.0,
                .state = .UPOWER_DEVICE_STATE_FULLY_CHARGED,
                .warning_level = .UPOWER_DEVICE_LEVEL_NONE,
                .battery_level = .UPOWER_DEVICE_LEVEL_NONE,
            };

            break :blk upower.UPowerDevice{
                .allocator = self.allocator,
                // TODO: free
                .path = try std.fmt.allocPrintZ(self.allocator, "{s}", .{p}),
                .native_path = null,
                .model = null,
                .power_supply = 1,
                .type = upower.DeviceType.BATTERY,

                .current = props,
                .last = props,

                .notifications = [_]u32{ 0, 0, 0 },
                .slot = undefined,
            };
        };

        try self.devices.append(self.allocator, device);

        return device;
    }
};
