const std = @import("std");
const sd_bus = @cImport({
    @cInclude("elogind/sd-bus.h");
});

pub const DeviceState = enum(c_uint) {
    UNKNOWN,
    CHARGING,
    DISCHARGING,
    EMPTY,
    FULLY_CHARGED,
    PENDING_CHARGE,
    PENDING_DISCHARGE,
};

pub const DeviceLevel = enum(c_uint) {
    UNKNOWN,
    NONE,
    DISCHARGING,
    LOW,
    CRITICAL,
    ACTION,
    NORMAL,
    HIGH,
    FULL,
};

pub const DeviceType = enum(c_uint) {
    UNKNOWN,
    LINE_POWER,
    BATTERY,
    UPS,
    MONITOR,
    MOUSE,
    KEYBOARD,
    PDA,
    PHONE,
    MEDIA_PLAYER,
    TABLET,
    COMPUTER,
    GAMING_INPUT,
    PEN,
    TOUCHPAD,
    MODEM,
    NETWORK,
    HEADSET,
    SPEAKERS,
    HEADPHONES,
    VIDEO,
    OTHER_AUDIO,
    REMOTE_CONTROL,
    PRINTER,
    SCANNER,
    CAMERA,
    WEARABLE,
    TOY,
    BLUETOOTH_GENERIC,
};

// org.freedesktop.UPower.Device.State
// https://upower.freedesktop.org/docs/Device.html
pub const UPowerDeviceState = enum(c_uint) {
    UPOWER_DEVICE_STATE_UNKNOWN,
    UPOWER_DEVICE_STATE_CHARGING,
    UPOWER_DEVICE_STATE_DISCHARGING,
    UPOWER_DEVICE_STATE_EMPTY,
    UPOWER_DEVICE_STATE_FULLY_CHARGED,
    UPOWER_DEVICE_STATE_PENDING_CHARGE,
    UPOWER_DEVICE_STATE_PENDING_DISCHARGE,
    UPOWER_DEVICE_STATE_LAST,
};

// org.freedesktop.UPower.Device.WarningLevel
// https://upower.freedesktop.org/docs/Device.html
pub const UPowerDeviceLevel = enum(c_uint) {
    UPOWER_DEVICE_LEVEL_UNKNOWN,
    UPOWER_DEVICE_LEVEL_NONE,
    UPOWER_DEVICE_LEVEL_DISCHARGING,
    UPOWER_DEVICE_LEVEL_LOW,
    UPOWER_DEVICE_LEVEL_CRITICAL,
    UPOWER_DEVICE_LEVEL_ACTION,
    UPOWER_DEVICE_LEVEL_NORMAL,
    UPOWER_DEVICE_LEVEL_HIGH,
    UPOWER_DEVICE_LEVEL_FULL,
    UPOWER_DEVICE_LEVEL_LAST,
};

// org.freedesktop.UPower.Device.Type
// https://upower.freedesktop.org/docs/Device.html
pub const UPowerDeviceType = enum(c_uint) {
    UPOWER_DEVICE_TYPE_UNKNOWN,
    UPOWER_DEVICE_TYPE_LINE_POWER,
    UPOWER_DEVICE_TYPE_BATTERY,
    UPOWER_DEVICE_TYPE_UPS,
    UPOWER_DEVICE_TYPE_MONITOR,
    UPOWER_DEVICE_TYPE_MOUSE,
    UPOWER_DEVICE_TYPE_KEYBOARD,
    UPOWER_DEVICE_TYPE_PDA,
    UPOWER_DEVICE_TYPE_PHONE,
    UPOWER_DEVICE_TYPE_MEDIA_PLAYER,
    UPOWER_DEVICE_TYPE_TABLET,
    UPOWER_DEVICE_TYPE_COMPUTER,
    UPOWER_DEVICE_TYPE_GAMING_INPUT,
    UPOWER_DEVICE_TYPE_PEN,
    UPOWER_DEVICE_TYPE_TOUCHPAD,
    UPOWER_DEVICE_TYPE_MODEM,
    UPOWER_DEVICE_TYPE_NETWORK,
    UPOWER_DEVICE_TYPE_HEADSET,
    UPOWER_DEVICE_TYPE_SPEAKERS,
    UPOWER_DEVICE_TYPE_HEADPHONES,
    UPOWER_DEVICE_TYPE_VIDEO,
    UPOWER_DEVICE_TYPE_OTHER_AUDIO,
    UPOWER_DEVICE_TYPE_REMOTE_CONTROL,
    UPOWER_DEVICE_TYPE_PRINTER,
    UPOWER_DEVICE_TYPE_SCANNER,
    UPOWER_DEVICE_TYPE_CAMERA,
    UPOWER_DEVICE_TYPE_WEARABLE,
    UPOWER_DEVICE_TYPE_TOY,
    UPOWER_DEVICE_TYPE_BLUETOOTH_GENERIC,
    UPOWER_DEVICE_TYPE_LAST,
};

pub const ChangeSlot = enum(usize) {
    SLOT_STATE = 0,
    SLOT_WARNING = 1,
    SLOT_ONLINE = 2,
};

pub const UPowerDeviceProps = struct {
    generation: i32,
    online: i32,
    percentage: f64,
    state: UPowerDeviceState,
    warning_level: UPowerDeviceLevel,
    battery_level: UPowerDeviceLevel,
};

pub const UPowerDevice = struct {
    path: ?[*:0]const u8,
    native_path: ?[*:0]const u8,
    model: ?[*:0]const u8,
    power_supply: i32,
    type: DeviceType,

    current: UPowerDeviceProps,
    last: UPowerDeviceProps,

    notifications: [3]u32,
    slot: *sd_bus.sd_bus_slot,

    pub fn has_battery(self: *const UPowerDevice) bool {
        return @intFromEnum(self.type) != @intFromEnum(UPowerDeviceType.UPOWER_DEVICE_TYPE_LINE_POWER) and
            @intFromEnum(self.type) != @intFromEnum(UPowerDeviceType.UPOWER_DEVICE_TYPE_UNKNOWN);
    }
};

pub fn print_device(dev: *const UPowerDevice) void {
    std.debug.print("Device: {s}\n", .{dev.native_path.?});
    std.debug.print("  Type: {}\n", .{dev.type});
}

fn handle_upower_device_added(
    m: ?*sd_bus.sd_bus_message,
    userdata: ?*anyopaque,
    ret_error: [*c]sd_bus.sd_bus_error,
) callconv(.C) c_int {
    std.debug.print("Received signal #{any} #{any} #{any}\n", .{ m, userdata, ret_error });
    return 0;
}

fn handle_upower_device_removed(
    m: ?*sd_bus.sd_bus_message,
    userdata: ?*anyopaque,
    ret_error: [*c]sd_bus.sd_bus_error,
) callconv(.C) c_int {
    std.debug.print("Received signal #{any} #{any} #{any}\n", .{ m, userdata, ret_error });
    return 0;
}

const StateError =
    std.mem.Allocator.Error ||
    error{MessageReadError} ||
    error{EnumerateDevicesFailed} ||
    error{EnterContainerFailed} ||
    error{MatchFailed};

pub const State = struct {
    allocator: std.mem.Allocator,
    bus: *sd_bus.sd_bus,
    devices: std.ArrayListUnmanaged(UPowerDevice),
    removed_devices: std.ArrayListUnmanaged(UPowerDevice),

    pub fn deinit(self: *State) void {
        self.allocator.destroy(self);
    }

    pub fn init(bus: *sd_bus.sd_bus, allocator: std.mem.Allocator) StateError!*State {
        const state = try allocator.create(State);
        state.* = State{
            .allocator = allocator,
            .bus = bus,
            .devices = std.ArrayListUnmanaged(UPowerDevice){},
            .removed_devices = std.ArrayListUnmanaged(UPowerDevice){},
        };

        if (sd_bus.sd_bus_add_match(
            bus,
            null,
            "type='signal',path='/org/freedesktop/UPower',interface='org.freedesktop.UPower',member='DeviceAdded'",
            handle_upower_device_added,
            state,
        ) < 0) {
            std.debug.print("Failed to add match\n", .{});
            return error.MatchFailed;
        }

        if (sd_bus.sd_bus_add_match(
            bus,
            null,
            "type='signal',path='/org/freedesktop/UPower',interface='org.freedesktop.UPower',member='DeviceRemoved'",
            handle_upower_device_removed,
            state,
        ) < 0) {
            std.debug.print("Failed to add match\n", .{});
            return error.MatchFailed;
        }

        var msg: ?*sd_bus.sd_bus_message = null;
        var err: sd_bus.sd_bus_error = std.mem.zeroInit(sd_bus.sd_bus_error, .{});
        defer {
            _ = sd_bus.sd_bus_message_unref(msg);
            _ = sd_bus.sd_bus_error_free(&err);
        }

        if (sd_bus.sd_bus_call_method(
            bus,
            "org.freedesktop.UPower",
            "/org/freedesktop/UPower",
            "org.freedesktop.UPower",
            "EnumerateDevices",
            &err,
            &msg,
            "",
        ) < 0) {
            std.debug.print("{any}: {any}\n", .{ err, msg });
            return error.EnumerateDevicesFailed;
        }

        if (sd_bus.sd_bus_message_enter_container(msg, 'a', "o") < 0) {
            std.debug.print("{any}: {any}\n", .{ err, msg });
            return error.EnterContainerFailed;
        }

        std.debug.print("sd_bus_call_method: {any} | {any}\n", .{ err, msg });

        while (true) {
            var path: [*c]const u8 = null;
            const ret = sd_bus.sd_bus_message_read(msg, "o", &path);
            if (ret < 0) {
                std.debug.print("{d}: {any}: {any}\n", .{ ret, path, msg });
                return error.MessageReadError;
            } else if (ret == 0) {
                std.debug.print("sd_bus_message_read returned 0\n", .{});
                break;
            }

            // const path_ptr = sd_bus.sd_bus_message_get_path(msg);
            // const member_ptr = sd_bus.sd_bus_message_get_member(msg);
            //
            // if (path_ptr != null and member_ptr != null) {
            //     std.debug.print("Message from path: {s}, member: {s}\n", .{ path_ptr, member_ptr });
            // } else {
            //     std.debug.print("Message path or member is null: path={any}, member={any}\n", .{ path_ptr, member_ptr });
            // }
            //
            // const sig = sd_bus.sd_bus_message_get_signature(msg, 1);
            // std.debug.print("Signature: {s}\n", .{sig});

            std.debug.print("sd_bus_message_read read, checking path ...\n", .{});
            if (path) |p| {
                std.debug.print("Path: {s}\n", .{p});

                const device = blk: {
                    const props = UPowerDeviceProps{
                        .generation = 1,
                        .online = 1,
                        .percentage = 100.0,
                        .state = .UPOWER_DEVICE_STATE_FULLY_CHARGED,
                        .warning_level = .UPOWER_DEVICE_LEVEL_NONE,
                        .battery_level = .UPOWER_DEVICE_LEVEL_FULL,
                    };

                    break :blk UPowerDevice{
                        // TODO: free
                        .path = try std.fmt.allocPrintZ(state.*.allocator, "#{s}", .{p}),
                        .native_path = null,
                        .model = null,
                        .power_supply = 1,
                        .type = DeviceType.BATTERY,

                        .current = props,
                        .last = props,

                        .notifications = [_]u32{ 0, 0, 0 },
                        .slot = undefined,
                    };
                };

                try state.*.devices.append(state.*.allocator, device);

                // C:
                // ret = upower_device_register_notification(bus, device);
                // if (ret < 0) {
                //     goto error;
                // }
                // ret = upower_device_update_state(bus, device);
                // if (ret < 0) {
                //     goto error;
                // }

            } else {
                std.debug.print("path empty\n", .{});
            }
        }

        _ = sd_bus.sd_bus_message_exit_container(msg);

        return state;
    }
};
