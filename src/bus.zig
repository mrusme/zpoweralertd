const std = @import("std");
const sd_bus = @cImport(@cInclude("elogind/sd-bus.h"));
const dbus = @cImport(@cInclude("dbus.h"));
const upower = @import("upower.zig");
const state = @import("state.zig");

const NOTIFICATION_MAX_LEN = 128;

// Urgency values to be used as hint in org.freedesktop.Notifications.Notify calls.
// https://people.gnome.org/~mccann/docs/notification-spec/notification-spec-latest.html#hints
const Urgency = enum {
    URGENCY_LOW,
    URGENCY_NORMAL,
    URGENCY_CRITICAL,
};

const BusError =
    std.mem.Allocator.Error ||
    error{NoSpaceLeft} ||
    error{SystemBusInitError} ||
    error{UserBusInitError} ||
    error{MessageReadError} ||
    error{DeviceEnumError} ||
    error{ConteinerEnterError} ||
    error{MatchAddError};

pub fn init(allocator: std.mem.Allocator) BusError!Bus {
    var bus = Bus{
        .allocator = allocator,
        .user_bus = undefined,
        .user_bus_ptr = undefined,
        .system_bus = undefined,
        .system_bus_ptr = undefined,
    };

    bus.user_bus_ptr = try bus.allocator.create(?*sd_bus.sd_bus);
    bus.user_bus_ptr.* = null;

    const r_user = sd_bus.sd_bus_open_user(bus.user_bus_ptr);
    if (r_user < 0) {
        std.debug.print("Failed to open user bus: {}\n", .{r_user});
        return error.UserBusInitError;
    }
    bus.user_bus = bus.user_bus_ptr.*.?;

    bus.system_bus_ptr = try bus.allocator.create(?*sd_bus.sd_bus);
    bus.system_bus_ptr.* = null;

    const r_system = sd_bus.sd_bus_open_system(bus.system_bus_ptr);
    if (r_system < 0) {
        std.debug.print("Failed to open system bus: {}\n", .{r_system});
        return error.SystemBusInitError;
    }
    bus.system_bus = bus.system_bus_ptr.*.?;

    return bus;
}

fn handleDeviceAdded(
    m: ?*sd_bus.sd_bus_message,
    userdata: ?*anyopaque,
    ret_error: [*c]sd_bus.sd_bus_error,
) callconv(.C) c_int {
    std.debug.print("Received signal {any} {any} {any}\n", .{ m, userdata, ret_error });
    return 0;
}

fn handleDeviceRemoved(
    m: ?*sd_bus.sd_bus_message,
    userdata: ?*anyopaque,
    ret_error: [*c]sd_bus.sd_bus_error,
) callconv(.C) c_int {
    std.debug.print("Received signal {any} {any} {any}\n", .{ m, userdata, ret_error });
    return 0;
}

fn handleDevicePropertiesChanged(
    m: ?*sd_bus.sd_bus_message,
    userdata: ?*anyopaque,
    ret_error: [*c]sd_bus.sd_bus_error,
) callconv(.C) c_int {
    std.debug.print("Received signal {any} {any} {any}\n", .{ m, userdata, ret_error });
    return 0;
}

pub const Bus = struct {
    allocator: std.mem.Allocator,
    user_bus: *sd_bus.struct_sd_bus,
    user_bus_ptr: *?*sd_bus.sd_bus,
    system_bus: *sd_bus.struct_sd_bus,
    system_bus_ptr: *?*sd_bus.sd_bus,

    pub fn deinit(self: *const Bus) void {
        _ = sd_bus.sd_bus_unref(self.system_bus);
        self.allocator.destroy(self.system_bus_ptr);
        _ = sd_bus.sd_bus_unref(self.user_bus);
        self.allocator.destroy(self.user_bus_ptr);
    }

    pub fn start(self: *const Bus) BusError!*state.State {
        var msg: ?*sd_bus.sd_bus_message = null;
        var err: sd_bus.sd_bus_error = std.mem.zeroInit(sd_bus.sd_bus_error, .{});
        defer {
            _ = sd_bus.sd_bus_message_unref(msg);
            _ = sd_bus.sd_bus_error_free(&err);
        }

        const the_state = try state.init(self.allocator);

        if (sd_bus.sd_bus_add_match(
            self.system_bus,
            null,
            "type='signal',path='/org/freedesktop/UPower',interface='org.freedesktop.UPower',member='DeviceAdded'",
            handleDeviceAdded,
            the_state,
        ) < 0) {
            std.debug.print("Failed to add match\n", .{});
            return error.MatchAddError;
        }

        if (sd_bus.sd_bus_add_match(
            self.system_bus,
            null,
            "type='signal',path='/org/freedesktop/UPower',interface='org.freedesktop.UPower',member='DeviceRemoved'",
            handleDeviceRemoved,
            the_state,
        ) < 0) {
            std.debug.print("Failed to add match\n", .{});
            return error.MatchAddError;
        }

        if (sd_bus.sd_bus_call_method(
            self.system_bus,
            "org.freedesktop.UPower",
            "/org/freedesktop/UPower",
            "org.freedesktop.UPower",
            "EnumerateDevices",
            &err,
            &msg,
            "",
        ) < 0) {
            std.debug.print("{any}: {any}\n", .{ err, msg });
            return error.DeviceEnumError;
        }

        if (sd_bus.sd_bus_message_enter_container(msg, 'a', "o") < 0) {
            std.debug.print("{any}: {any}\n", .{ err, msg });
            return error.ConteinerEnterError;
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

                var device = blk: {
                    const props = upower.UPowerDeviceProps{
                        .generation = 1,
                        .online = 1,
                        .percentage = 100.0,
                        .state = .UPOWER_DEVICE_STATE_FULLY_CHARGED,
                        .warning_level = .UPOWER_DEVICE_LEVEL_NONE,
                        .battery_level = .UPOWER_DEVICE_LEVEL_NONE,
                    };

                    break :blk upower.UPowerDevice{
                        .allocator = the_state.*.allocator,
                        // TODO: free
                        .path = try std.fmt.allocPrintZ(the_state.*.allocator, "{s}", .{p}),
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

                try the_state.*.devices.append(the_state.*.allocator, device);

                // C:
                // ret = upower_device_register_notification(bus, device);
                // if (ret < 0) {
                //     goto error;
                // }
                try self.registerDevicePropertiesChanged(&device);

                // C:
                // ret = upower_device_update_state(bus, device);
                // if (ret < 0) {
                //     goto error;
                // }

            } else {
                std.debug.print("path empty\n", .{});
            }
        }

        _ = sd_bus.sd_bus_message_exit_container(msg);

        return the_state;
    }

    pub fn process(self: *const Bus) i32 {
        return sd_bus.sd_bus_process(self.system_bus, null);
    }

    pub fn wait(self: *const Bus) i32 {
        return sd_bus.sd_bus_wait(self.system_bus, std.math.maxInt(u64));
    }

    pub fn registerDevicePropertiesChanged(self: *const Bus, device: *upower.UPowerDevice) !void {
        var match: [:0]u8 = undefined;
        var match_buf: [512:0]u8 = undefined;

        if (device.path) |p| {
            match = try std.fmt.bufPrintZ(&match_buf, "type='signal',path='{s}',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'", .{p});
        } else {
            std.debug.print("Failed to add match (path empty)\n", .{});
            return error.MatchAddError;
        }

        std.debug.print("Adding match for {s}\n", .{match});

        const ret = sd_bus.sd_bus_add_match(
            self.system_bus,
            &device.slot,
            match,
            handleDevicePropertiesChanged,
            device,
        );
        if (ret < 0) {
            std.debug.print("Failed to add match {d}\n", .{ret});
            return error.MatchAddError;
        }
    }

    pub fn updateDeviceState(self: *const Bus, device: *upower.UPowerDevice) !void {
        var err: sd_bus.sd_bus_error = std.mem.zeroInit(sd_bus.sd_bus_error, .{});
        defer {
            _ = sd_bus.sd_bus_error_free(&err);
        }

        var ret = 0;
        var tmp: [:0]const u8 = undefined;

        ret = sd_bus.sd_bus_get_property_string(
            self.system_bus,
            "org.freedesktop.UPower",
            device.path,
            "org.freedesktop.UPower.Device",
            "NativePath",
            &err,
            &tmp,
        );
        if (ret < 0) {
            std.debug.print("Failed to update property\n", .{});
            return error.PropertyUpdateError;
        }
        if (device.native_path) |_| {
            device.allocator.free(device.native_path);
        }
        device.native_path = try std.fmt.allocPrintZ(device.allocator, "{s}", .{tmp});
    }

    pub fn sendNotification(self: *const Bus, summary: [:0]const u8, body: [:0]const u8, category: [:0]const u8, id: ?u32, urgency: Urgency) !void {
        var msg: ?*sd_bus.sd_bus_message = null;
        var err: sd_bus.sd_bus_error = std.mem.zeroInit(sd_bus.sd_bus_error, .{});
        defer {
            _ = sd_bus.sd_bus_message_unref(msg);
            _ = sd_bus.sd_bus_error_free(&err);
        }

        var ret = sd_bus.sd_bus_call_method(
            self.user_bus,
            "org.freedesktop.Notifications",
            "/org/freedesktop/Notifications",
            "org.freedesktop.Notifications",
            "Notify",
            &err,
            &msg,
            "susssasa{sv}i",
            "zpoweralertd",
            (if (id != null) id.? else 0),
            "",
            @as([*:0]const u8, summary),
            @as([*:0]const u8, body),
            @as(c_int, 0),
            @as(c_int, 2),
            "urgency",
            "y",
            @as(c_uint, @intFromEnum(urgency)),
            @as([*:0]const u8, "category"),
            "s",
            @as([*:0]const u8, category),
            @as(c_int, -1),
        );

        if (ret < 0) {
            return error.BusCallMethodError;
        }

        if (id != null) {
            ret = sd_bus.sd_bus_message_read(msg, "u", id.?);
            if (ret < 0) {
                return error.BusMessageReadError;
            }
        }

        return;
    }

    pub fn sendRemoveNotification(self: *const Bus, device: *upower.UPowerDevice) !void {
        const urgency: Urgency = .URGENCY_NORMAL;
        var title: [NOTIFICATION_MAX_LEN]u8 = undefined;
        var cstr: [:0]u8 = undefined;
        var msg: [:0]u8 = undefined;
        var msg_buf: [128:0]u8 = undefined;
        var category: [:0]u8 = undefined;
        var category_buf: [64:0]u8 = undefined;

        msg = try std.fmt.bufPrintZ(&msg_buf, "Device disconnected\n", .{});
        category = try std.fmt.bufPrintZ(&category_buf, "device.removed", .{});

        if (device.model) |model| {
            if (std.mem.len(model) > 0) {
                cstr = try std.fmt.bufPrintZ(&title, "Power status: {s}", .{model});
            }
        } else {
            cstr = try std.fmt.bufPrintZ(&title, "Power status: {?s} ({s})", .{ device.native_path, @tagName(device.type) });
        }

        return self.sendNotification(cstr, msg, category, 0, urgency);
    }

    pub fn sendOnlineUpdateNotification(self: *const Bus, device: *upower.UPowerDevice) !void {
        // if (device.current.online == device.last.online) {
        //   return 0;
        // }

        var title: [NOTIFICATION_MAX_LEN]u8 = undefined;
        var cstr: [:0]u8 = undefined;
        var msg: [:0]u8 = undefined;
        var msg_buf: [128:0]u8 = undefined;
        var category: [:0]u8 = undefined;
        var category_buf: [64:0]u8 = undefined;

        if (std.mem.len(device.model.?) > 0) {
            cstr = try std.fmt.bufPrintZ(&title, "Power status: {s}", .{device.model.?});
        } else {
            cstr = try std.fmt.bufPrintZ(&title, "Power status: {s} ({s})", .{ device.native_path.?, @tagName(device.type) });
        }

        if (device.current.online == 0) {
            msg = try std.fmt.bufPrintZ(&msg_buf, "Power supply online", .{});
            category = try std.fmt.bufPrintZ(&category_buf, "power.online", .{});
        } else {
            msg = try std.fmt.bufPrintZ(&msg_buf, "Power supply offline", .{});
            category = try std.fmt.bufPrintZ(&category_buf, "power.offline", .{});
        }

        return self.sendNotification(cstr, msg, category, device.notifications[@intFromEnum(upower.ChangeSlot.SLOT_ONLINE)], .URGENCY_NORMAL);
    }

    pub fn sendStateUpdateNotification(self: *const Bus, device: *upower.UPowerDevice) !void {
        // if (device.current.state == device.last.state) {
        //   return 0;
        // }

        var urgency: Urgency = .URGENCY_NORMAL;
        var title: [NOTIFICATION_MAX_LEN]u8 = undefined;
        var cstr: [:0]u8 = undefined;
        var msg: [:0]u8 = undefined;
        var msg_buf: [128:0]u8 = undefined;
        // var category: []u8 = "";

        switch (device.current.state) {
            .UPOWER_DEVICE_STATE_UNKNOWN => {

                // Silence transitions to/from unknown
                device.current.state = device.last.state;
                return;
            },
            .UPOWER_DEVICE_STATE_EMPTY => {
                urgency = .URGENCY_CRITICAL;
            },
            else => {
                urgency = .URGENCY_NORMAL;
            },
        }

        if (device.model) |model| {
            if (std.mem.len(model) > 0) {
                cstr = try std.fmt.bufPrintZ(&title, "Power status: {s}", .{model});
            }
        } else {
            cstr = try std.fmt.bufPrintZ(&title, "Power status: {?s} ({s})", .{ device.native_path, @tagName(device.type) });
        }

        if (device.current.battery_level != .UPOWER_DEVICE_LEVEL_NONE) {
            msg = try std.fmt.bufPrintZ(&msg_buf, "Battery {s}\nCurrent level: {d}%\n", .{ device.stateStr(), device.batteryLevelStr() });
        } else {
            msg = try std.fmt.bufPrintZ(&msg_buf, "Battery {s}\nCurrent level: {d}%\n", .{ device.stateStr(), device.current.percentage });
        }

        return self.sendNotification(cstr, msg, "power.update", device.notifications[@intFromEnum(upower.ChangeSlot.SLOT_STATE)], urgency);
    }

    pub fn sendWarningUpdateNotification(self: *const Bus, device: *upower.UPowerDevice) !void {
        // if (device.current.warning_level == device.last.warning_level) {
        //   return 0;
        // }

        if (device.current.warning_level == .UPOWER_DEVICE_LEVEL_NONE and device.last.warning_level == .UPOWER_DEVICE_LEVEL_UNKNOWN) {
            return;
        }

        var urgency: Urgency = .URGENCY_CRITICAL;
        var title: [NOTIFICATION_MAX_LEN]u8 = undefined;
        var cstr: [:0]u8 = undefined;
        var msg: [:0]u8 = undefined;
        var msg_buf: [128:0]u8 = undefined;
        var category: [:0]u8 = undefined;
        var category_buf: [64:0]u8 = undefined;

        switch (device.current.warning_level) {
            .UPOWER_DEVICE_LEVEL_NONE => {
                msg = try std.fmt.bufPrintZ(&msg_buf, "Warning cleared\n", .{});
                urgency = .URGENCY_NORMAL;
                category = try std.fmt.bufPrintZ(&category_buf, "power.cleared", .{});
            },
            .UPOWER_DEVICE_LEVEL_DISCHARGING => {
                msg = try std.fmt.bufPrintZ(&msg_buf, "Warning: system discharging\n", .{});
                category = try std.fmt.bufPrintZ(&category_buf, "power.discharging", .{});
            },
            .UPOWER_DEVICE_LEVEL_LOW => {
                msg = try std.fmt.bufPrintZ(&msg_buf, "Warning: power level low\n", .{});
                category = try std.fmt.bufPrintZ(&category_buf, "power.low", .{});
            },
            .UPOWER_DEVICE_LEVEL_CRITICAL => {
                msg = try std.fmt.bufPrintZ(&msg_buf, "Warning: power level critical\n", .{});
                urgency = .URGENCY_CRITICAL;
                category = try std.fmt.bufPrintZ(&category_buf, "power.critical", .{});
            },
            .UPOWER_DEVICE_LEVEL_ACTION => {
                msg = try std.fmt.bufPrintZ(&msg_buf, "Warning: power level at action threshold\n", .{});
                category = try std.fmt.bufPrintZ(&category_buf, "power.action", .{});
            },
            else => {
                msg = try std.fmt.bufPrintZ(&msg_buf, "Warning: unknown warning level\n", .{});
                category = try std.fmt.bufPrintZ(&category_buf, "power.unknown", .{});
            },
        }

        if (device.model) |model| {
            if (std.mem.len(model) > 0) {
                cstr = try std.fmt.bufPrintZ(&title, "Power warning: {s}", .{model});
            }
        } else {
            cstr = try std.fmt.bufPrintZ(&title, "Power warning: {?s} ({s})", .{ device.native_path, @tagName(device.type) });
        }

        return self.sendNotification(cstr, msg, category, device.notifications[@intFromEnum(upower.ChangeSlot.SLOT_WARNING)], urgency);
    }
};
