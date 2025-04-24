const std = @import("std");
const upower = @import("upower.zig");

const sd_bus = @cImport(@cInclude("elogind/sd-bus.h"));
const dbus = @cImport(@cInclude("dbus.h"));

// Urgency values to be used as hint in org.freedesktop.Notifications.Notify calls.
// https://people.gnome.org/~mccann/docs/notification-spec/notification-spec-latest.html#hints
const Urgency = enum {
    URGENCY_LOW,
    URGENCY_NORMAL,
    URGENCY_CRITICAL,
};

pub fn main() !void {
    var gpa = std.heap.page_allocator;
    // var opt: i32 = 0;
    // var device_type: i32 = 0;
    // const ignore_types_mask: c_uint = 0;
    const ignore_initial: bool = false;
    const ignore_non_power_supplies: bool = false;
    var initialized: bool = false;

    var start: std.os.linux.timespec = undefined;

    if (std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &start) != 0) {
        return error.ClockError;
    }

    const user_bus_ptr: *?*sd_bus.sd_bus = try gpa.create(?*sd_bus.sd_bus);
    user_bus_ptr.* = null;

    const r_user = sd_bus.sd_bus_open_user(user_bus_ptr);
    if (r_user < 0) {
        std.debug.print("Failed to open user bus: {}\n", .{r_user});
        return error.BusInitError;
    }

    const user_bus: *sd_bus.sd_bus = user_bus_ptr.*.?;
    defer {
        _ = sd_bus.sd_bus_unref(user_bus);
        gpa.destroy(user_bus_ptr);
    }

    const system_bus_ptr: *?*sd_bus.sd_bus = try gpa.create(?*sd_bus.sd_bus);
    system_bus_ptr.* = null;

    const r_system = sd_bus.sd_bus_open_system(system_bus_ptr);
    if (r_system < 0) {
        std.debug.print("Failed to open system bus: {}\n", .{r_system});
        return error.BusInitError;
    }

    const system_bus: *sd_bus.sd_bus = system_bus_ptr.*.?;
    defer {
        _ = sd_bus.sd_bus_unref(system_bus);
        gpa.destroy(system_bus_ptr);
    }

    const state = try upower.State.init(system_bus, gpa);
    defer {
        state.deinit();
    }

    std.debug.print("entering main loop\n", .{});
    while (true) {
        std.debug.print("entering for devices\n", .{});
        for (state.devices.items) |*device| {
            defer {
                device.last = device.current;
            }
            // if ((ignore_types_mask & (@as(c_uint, 1) << @as(u5, @intFromEnum(device.type))))) {
            // device.last = device.current;
            // continue;
            // }

            if (!initialized and ignore_initial) {
                // device.last = device.current;
                continue;
            }

            if (ignore_non_power_supplies and !device.power_supply) {
                // device.last = device.current;
                continue;
            }

            if (device.has_battery()) {
                send_state_update(user_bus, device) catch |err| {
                    std.debug.print("could not send state update notification {any}\n", .{err});
                    //     fprintf(stderr, "could not send state update notification: #{s}\n", strerror(-ret));
                    //     // goto finish;
                };
                send_warning_update(user_bus, device) catch |err| {
                    std.debug.print("could not send state warning update notification {any}\n", .{err});
                    //     fprintf(stderr, "could not send warning update notification: #{s}\n", strerror(-ret));
                    //     // goto finish;
                };
            } else {
                send_online_update(user_bus, device) catch |err| {
                    std.debug.print("could not send state online update notification {any}\n", .{err});
                    //     fprintf(stderr, "could not send online update notification: #{s}\n", strerror(-ret));
                    //     // goto finish;
                };
            }
            // device.last = device.current;
        }

        std.debug.print("entering for removed_devices\n", .{});
        for (state.removed_devices.items) |*device| {

            // if ((ignore_types_mask & (@as(c_uint, 1) << device.type))) {
            //     continue;
            // }

            if (ignore_non_power_supplies and !device.power_supply) {
                continue;
            }

            send_remove(user_bus, device) catch |err| {
                std.debug.print("could not send device removal notification {any}\n", .{err});
                //     fprintf(stderr, "could not send device removal notification: #{s}\n", strerror(-ret));
                //     // goto finish;
            };
            // upower_device_destroy(device);
            // list_del(state.removed_devices, idx);
        }

        std.debug.print("sd_bus_process\n", .{});
        var ret = sd_bus.sd_bus_process(system_bus, null);
        if (ret < 0) {
            std.debug.print("could not process system bus messages: #{d}\n", .{ret});
            // goto finish;
        } else if (ret > 0) {
            continue;
        }

        std.debug.print("sd_bus_wait\n", .{});
        ret = sd_bus.sd_bus_wait(system_bus, std.math.maxInt(u64));
        if (ret < 0) {
            std.debug.print("could not wait for system bus messages: #{d}\n", .{ret});
            // goto finish;
        }

        std.debug.print("initialized?\n", .{});
        if (!initialized) {
            initialized = millisecondsSince(&start) > 500;
        }

        std.debug.print("loop\n", .{});
    }

    // finish:
    // destroy_upower(system_bus, &state);

}

pub fn millisecondsSince(start: *const std.os.linux.timespec) f64 {
    var current: std.os.linux.timespec = undefined;

    if (std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &current) != 0) {
        return 0;
    }

    const sec_diff = current.sec - start.sec;
    const nsec_diff = current.nsec - start.nsec;

    return @as(f64, @floatFromInt(sec_diff)) * 1000.0 + @as(f64, @floatFromInt(nsec_diff)) / 1_000_000.0;
}

const NOTIFICATION_MAX_LEN = 128;

pub fn notify(bus: *sd_bus.sd_bus, summary: [:0]const u8, body: [:0]const u8, category: [:0]const u8, id: ?u32, urgency: Urgency) !void {
    var msg: ?*sd_bus.sd_bus_message = null;
    var err: sd_bus.sd_bus_error = std.mem.zeroInit(sd_bus.sd_bus_error, .{});
    defer {
        _ = sd_bus.sd_bus_message_unref(msg);
        _ = sd_bus.sd_bus_error_free(&err);
    }

    var ret = sd_bus.sd_bus_call_method(
        bus,
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

pub fn send_remove(bus: *sd_bus.sd_bus, device: *upower.UPowerDevice) !void {
    const urgency: Urgency = .URGENCY_NORMAL;
    var title: [NOTIFICATION_MAX_LEN]u8 = undefined;
    var cstr: [:0]u8 = undefined;
    var msg: [:0]u8 = undefined;
    var msg_buf: [128:0]u8 = undefined;
    var category: [:0]u8 = undefined;
    var category_buf: [64:0]u8 = undefined;

    msg = try std.fmt.bufPrintZ(&msg_buf, "Device disconnected\n", .{});
    category = try std.fmt.bufPrintZ(&category_buf, "device.removed", .{});

    if (std.mem.len(device.model.?) > 0) {
        cstr = try std.fmt.bufPrintZ(&title, "Power status: #{s}", .{device.model.?});
    } else {
        cstr = try std.fmt.bufPrintZ(&title, "Power status: #{s} (#{s})", .{ device.native_path.?, @tagName(device.type) });
    }

    return notify(bus, cstr, msg, category, 0, urgency);
}

pub fn send_online_update(bus: *sd_bus.sd_bus, device: *upower.UPowerDevice) !void {
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

    return notify(bus, cstr, msg, category, device.notifications[@intFromEnum(upower.ChangeSlot.SLOT_ONLINE)], .URGENCY_NORMAL);
}

pub fn send_state_update(bus: *sd_bus.sd_bus, device: *upower.UPowerDevice) !void {
    // if (device.current.state == device.last.state) {
    //   return 0;
    // }

    var urgency: Urgency = .URGENCY_NORMAL;
    var title: [NOTIFICATION_MAX_LEN]u8 = undefined;
    var cstr: [:0]u8 = undefined;
    const msg: [:0]u8 = undefined;
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

    if (std.mem.len(device.model.?) > 0) {
        cstr = try std.fmt.bufPrintZ(&title, "Power status: #{s}", .{device.model.?});
    } else {
        cstr = try std.fmt.bufPrintZ(&title, "Power status: #{s} (#{s})", .{ device.native_path.?, @tagName(device.type) });
    }

    // if (device.current.battery_level != .UPOWER_DEVICE_LEVEL_NONE) {
    //   snprintf(msg, NOTIFICATION_MAX_LEN, "Battery #{s}\nCurrent level: #{s}\n", upower_device_state_string(device), upower_device_battery_level_string(device));
    // } else {
    //   snprintf(msg, NOTIFICATION_MAX_LEN, "Battery #{s}\nCurrent level: %0.0lf%%\n", upower_device_state_string(device), device->current.percentage);
    // }

    return notify(bus, cstr, msg, "power.update", device.notifications[@intFromEnum(upower.ChangeSlot.SLOT_STATE)], urgency);
}

pub fn send_warning_update(bus: *sd_bus.sd_bus, device: *upower.UPowerDevice) !void {
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

    if (std.mem.len(device.model.?) > 0) {
        cstr = try std.fmt.bufPrintZ(&title, "Power warning: #{s}", .{device.model.?});
    } else {
        cstr = try std.fmt.bufPrintZ(&title, "Power warning: #{s} (#{s})", .{ device.native_path.?, @tagName(device.type) });
    }

    return notify(bus, cstr, msg, category, device.notifications[@intFromEnum(upower.ChangeSlot.SLOT_WARNING)], urgency);
}
