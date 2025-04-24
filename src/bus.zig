const std = @import("std");
const sd_bus = @cImport(@cInclude("elogind/sd-bus.h"));
const dbus = @cImport(@cInclude("dbus.h"));
const upower = @import("upower.zig");

const NOTIFICATION_MAX_LEN = 128;

// Urgency values to be used as hint in org.freedesktop.Notifications.Notify calls.
// https://people.gnome.org/~mccann/docs/notification-spec/notification-spec-latest.html#hints
const Urgency = enum {
    URGENCY_LOW,
    URGENCY_NORMAL,
    URGENCY_CRITICAL,
};

pub fn init(allocator: std.mem.Allocator) !Bus {
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

    pub fn process(self: *const Bus) i32 {
        return sd_bus.sd_bus_process(self.system_bus, null);
    }

    pub fn wait(self: *const Bus) i32 {
        return sd_bus.sd_bus_wait(self.system_bus, std.math.maxInt(u64));
    }

    pub fn notify(self: *const Bus, summary: [:0]const u8, body: [:0]const u8, category: [:0]const u8, id: ?u32, urgency: Urgency) !void {
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

    pub fn send_remove(self: *const Bus, device: *upower.UPowerDevice) !void {
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
                cstr = try std.fmt.bufPrintZ(&title, "Power status: #{s}", .{model});
            }
        } else {
            cstr = try std.fmt.bufPrintZ(&title, "Power status: #{?s} (#{s})", .{ device.native_path, @tagName(device.type) });
        }

        return self.notify(cstr, msg, category, 0, urgency);
    }

    pub fn send_online_update(self: *const Bus, device: *upower.UPowerDevice) !void {
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
            cstr = try std.fmt.bufPrintZ(&title, "Power status: #{s}", .{device.model.?});
        } else {
            cstr = try std.fmt.bufPrintZ(&title, "Power status: #{s} (#{s})", .{ device.native_path.?, @tagName(device.type) });
        }

        if (device.current.online == 0) {
            msg = try std.fmt.bufPrintZ(&msg_buf, "Power supply online", .{});
            category = try std.fmt.bufPrintZ(&category_buf, "power.online", .{});
        } else {
            msg = try std.fmt.bufPrintZ(&msg_buf, "Power supply offline", .{});
            category = try std.fmt.bufPrintZ(&category_buf, "power.offline", .{});
        }

        return self.notify(cstr, msg, category, device.notifications[@intFromEnum(upower.ChangeSlot.SLOT_ONLINE)], .URGENCY_NORMAL);
    }

    pub fn send_state_update(self: *const Bus, device: *upower.UPowerDevice) !void {
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
                cstr = try std.fmt.bufPrintZ(&title, "Power status: #{s}", .{model});
            }
        } else {
            cstr = try std.fmt.bufPrintZ(&title, "Power status: #{?s} (#{s})", .{ device.native_path, @tagName(device.type) });
        }

        if (device.current.battery_level != .UPOWER_DEVICE_LEVEL_NONE) {
            msg = try std.fmt.bufPrintZ(&msg_buf, "Battery #{s}\nCurrent level: #{d}%\n", .{ device.state_string(), device.battery_level_string() });
        } else {
            msg = try std.fmt.bufPrintZ(&msg_buf, "Battery #{s}\nCurrent level: #{d}%\n", .{ device.state_string(), device.current.percentage });
        }

        return self.notify(cstr, msg, "power.update", device.notifications[@intFromEnum(upower.ChangeSlot.SLOT_STATE)], urgency);
    }

    pub fn send_warning_update(self: *const Bus, device: *upower.UPowerDevice) !void {
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
                cstr = try std.fmt.bufPrintZ(&title, "Power warning: #{s}", .{model});
            }
        } else {
            cstr = try std.fmt.bufPrintZ(&title, "Power warning: #{?s} (#{s})", .{ device.native_path, @tagName(device.type) });
        }

        return self.notify(cstr, msg, category, device.notifications[@intFromEnum(upower.ChangeSlot.SLOT_WARNING)], urgency);
    }
};
