const std = @import("std");
const build_options = @import("build_options");

const sd_bus = switch (build_options.dbuslib) {
    0 => @cImport(@cInclude("basu/sd-bus.h")),
    1 => @cImport(@cInclude("elogind/sd-bus.h")),
    2 => @cImport(@cInclude("systemd/sd-bus.h")),
    else => @compileError("Unsupported sdbus provider"),
};
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
    error{PropertyUpdateError} ||
    error{SystemBusInitError} ||
    error{UserBusInitError} ||
    error{MessageReadError} ||
    error{DeviceEnumError} ||
    error{ConteinerEnterError} ||
    error{MatchAddError};

pub const DTO = struct {
    bus: *Bus,
    state: *state.State,
    device: ?*upower.UPowerDevice,
};

fn handleDeviceAdded(
    msg: ?*sd_bus.sd_bus_message,
    userdata: ?*anyopaque,
    ret_error: [*c]sd_bus.sd_bus_error,
) callconv(.c) c_int {
    std.debug.print("handleDeviceAdded {any} {any} {any}\n", .{ msg, userdata, ret_error });
    if (userdata) |ud| {
        var dto: *DTO = @ptrCast(@alignCast(ud));

        var path: [*c]const u8 = null;
        const ret = sd_bus.sd_bus_message_read(msg, "o", &path);
        if (ret < 0) {
            std.debug.print("{d}: {any}: {any}\n", .{ ret, path, msg });
            return -1;
        }

        if (path) |p| {
            for (dto.state.devices.items) |device| {
                if (device.path) |dp| {
                    if (std.mem.eql(u8, std.mem.span(p), std.mem.span(dp))) {
                        // upower_device_update_state
                        dto.bus.updateDeviceState(device) catch |err| {
                            std.debug.print("updateDeviceState error: {any}\n", .{err});
                            return -1;
                        };
                        return 0;
                    }
                } else {
                    continue;
                }
            }
            for (dto.state.removed_devices.items, 0..) |device, idx| {
                if (device.path) |dp| {
                    if (std.mem.eql(u8, std.mem.span(p), std.mem.span(dp))) {
                        const removed_device = dto.state.removed_devices.orderedRemove(idx);
                        dto.state.devices.append(dto.state.allocator, removed_device) catch |err| {
                            std.debug.print("could not un-remove device: {any}\n", .{err});
                            return -1;
                        };
                        // upower_device_update_state
                        dto.bus.updateDeviceState(removed_device) catch |err| {
                            std.debug.print("updateDeviceState error: {any}\n", .{err});
                            return -1;
                        };
                        return 0;
                    }
                } else {
                    continue;
                }
            }

            const device = dto.state.addDevice(p) catch |err| {
                std.debug.print("could not addDevice: {any}\n", .{err});
                return -1;
            };
            dto.bus.registerDevicePropertiesChanged(device) catch |err| {
                std.debug.print("could not registerDevicePropertiesChanged: {any}\n", .{err});
                return -1;
            };
            dto.bus.updateDeviceState(device) catch |err| {
                std.debug.print("updateDeviceState error: {any}\n", .{err});
                return -1;
            };
        } else {
            return -1;
        }
    } else {
        return -1;
    }
    return 0;
}

fn handleDeviceRemoved(
    msg: ?*sd_bus.sd_bus_message,
    userdata: ?*anyopaque,
    ret_error: [*c]sd_bus.sd_bus_error,
) callconv(.c) c_int {
    std.debug.print("handleDeviceRemoved {any} {any} {any}\n", .{ msg, userdata, ret_error });
    if (userdata) |ud| {
        const dto: *DTO = @ptrCast(@alignCast(ud));

        var path: [*c]const u8 = null;
        const ret = sd_bus.sd_bus_message_read(msg, "o", &path);
        if (ret < 0) {
            std.debug.print("{d}: {any}: {any}\n", .{ ret, path, msg });
            return -1;
        }

        if (path) |p| {
            for (dto.state.devices.items, 0..) |device, idx| {
                if (device.path) |dp| {
                    if (std.mem.eql(u8, std.mem.span(p), std.mem.span(dp))) {
                        const removed_device = dto.state.devices.orderedRemove(idx);
                        dto.state.removed_devices.append(dto.state.allocator, removed_device) catch |err| {
                            std.debug.print("could not remove device: {any}\n", .{err});
                            return -1;
                        };
                        return 0;
                    }
                } else {
                    continue;
                }
            }
        } else {
            return -1;
        }
    } else {
        return -1;
    }

    return 0;
}

fn handleDevicePropertiesChanged(
    msg: ?*sd_bus.sd_bus_message,
    userdata: ?*anyopaque,
    ret_error: [*c]sd_bus.sd_bus_error,
) callconv(.c) c_int {
    std.debug.print("handleDevicePropertiesChanged {any} {any} {any}\n", .{ msg, userdata, ret_error });
    if (userdata) |ud| {
        const dto: *DTO = @ptrCast(@alignCast(ud));
        const device = dto.device.?;

        std.debug.print("0 {?s}\n", .{device.path});

        std.debug.print("1 Skipping message\n", .{});
        if (sd_bus.sd_bus_message_skip(msg, "s") < 0) {
            std.debug.print("{any}\n", .{msg});
            return -1;
        }
        std.debug.print("2 Entering container\n", .{});
        if (sd_bus.sd_bus_message_enter_container(msg, 'a', "{sv}") < 0) {
            std.debug.print("{any}\n", .{msg});
            return -1;
        }

        while (true) {
            std.debug.print("3 Entering another container\n", .{});
            const ret = sd_bus.sd_bus_message_enter_container(msg, 'e', "sv");
            if (ret < 0) {
                std.debug.print("{any}\n", .{msg});
                return -1;
            } else if (ret == 0) {
                break;
            }

            var name: [*c]const u8 = null;
            std.debug.print("4 Reading message\n", .{});
            if (sd_bus.sd_bus_message_read(msg, "s", &name) < 0) {
                std.debug.print("{d}: {any}\n", .{ ret, msg });
                return -1;
            }

            if (name) |n| {
                std.debug.print("5 Checking message\n", .{});
                if (std.mem.eql(u8, std.mem.span(n), "State")) {
                    std.debug.print("Reading state message\n", .{});
                    if (sd_bus.sd_bus_message_read(msg, "v", "u", &device.current.state) < 0) {
                        std.debug.print("{d}: {any}\n", .{ ret, msg });
                        return -1;
                    }
                } else if (std.mem.eql(u8, std.mem.span(n), "WarningLevel")) {
                    std.debug.print("Reading warning level message\n", .{});
                    if (sd_bus.sd_bus_message_read(msg, "v", "u", &device.current.warning_level) < 0) {
                        std.debug.print("{d}: {any}\n", .{ ret, msg });
                        return -1;
                    }
                } else if (std.mem.eql(u8, std.mem.span(n), "BatteryLevel")) {
                    std.debug.print("Reading battery level message\n", .{});
                    if (sd_bus.sd_bus_message_read(msg, "v", "u", &device.current.battery_level) < 0) {
                        std.debug.print("{d}: {any}\n", .{ ret, msg });
                        return -1;
                    }
                } else if (std.mem.eql(u8, std.mem.span(n), "Online")) {
                    std.debug.print("Reading online message\n", .{});
                    if (sd_bus.sd_bus_message_read(msg, "v", "b", &device.current.online) < 0) {
                        std.debug.print("{d}: {any}\n", .{ ret, msg });
                        return -1;
                    }
                } else if (std.mem.eql(u8, std.mem.span(n), "Percentage")) {
                    std.debug.print("Reading percentage message\n", .{});
                    if (sd_bus.sd_bus_message_read(msg, "v", "d", &device.current.percentage) < 0) {
                        std.debug.print("{d}: {any}\n", .{ ret, msg });
                        return -1;
                    }
                } else {
                    std.debug.print("Skipping message\n", .{});
                    if (sd_bus.sd_bus_message_skip(msg, "v") < 0) {
                        std.debug.print("{any}\n", .{msg});
                        return -1;
                    }
                }
            } else {
                return -1;
            }

            std.debug.print("6 Exiting container\n", .{});
            if (sd_bus.sd_bus_message_exit_container(msg) < 0) {
                std.debug.print("{any}\n", .{msg});
                return -1;
            }
        }

        std.debug.print("7 Exiting container\n", .{});
        if (sd_bus.sd_bus_message_exit_container(msg) < 0) {
            std.debug.print("{any}\n", .{msg});
            return -1;
        }
        std.debug.print("8 Entering container\n", .{});
        if (sd_bus.sd_bus_message_enter_container(msg, 'a', "s") < 0) {
            std.debug.print("{any}\n", .{msg});
            return -1;
        }

        while (true) {
            std.debug.print("Skipping message\n", .{});
            const ret = sd_bus.sd_bus_message_skip(msg, "s");
            if (ret < 0) {
                std.debug.print("{any}\n", .{msg});
                return -1;
            } else if (ret == 0) {
                break;
            }
        }

        std.debug.print("9 Exiting container\n", .{});
        if (sd_bus.sd_bus_message_exit_container(msg) < 0) {
            std.debug.print("{any}\n", .{msg});
            return -1;
        }
    } else {
        // TODO: Errrrr....
        return -1;
    }

    return 0;
}

pub fn init(allocator: std.mem.Allocator) BusError!Bus {
    var bus = Bus{
        .allocator = allocator,
        .user_bus = undefined,
        .user_bus_ptr = undefined,
        .system_bus = undefined,
        .system_bus_ptr = undefined,
        .state = undefined,
        .dtos = std.ArrayListUnmanaged(*DTO){},
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
    state: *state.State,
    dtos: std.ArrayListUnmanaged(*DTO),

    pub fn deinit(self: *Bus) void {
        for (self.dtos.items) |dto| {
            self.allocator.destroy(dto);
        }
        self.dtos.deinit(self.allocator);

        self.state.deinit();

        _ = sd_bus.sd_bus_unref(self.system_bus);
        self.allocator.destroy(self.system_bus_ptr);
        _ = sd_bus.sd_bus_unref(self.user_bus);
        self.allocator.destroy(self.user_bus_ptr);
    }

    pub fn start(self: *Bus) BusError!*state.State {
        var msg: ?*sd_bus.sd_bus_message = null;
        var err: sd_bus.sd_bus_error = std.mem.zeroInit(sd_bus.sd_bus_error, .{});
        defer {
            _ = sd_bus.sd_bus_message_unref(msg);
            _ = sd_bus.sd_bus_error_free(&err);
        }

        self.state = try state.init(self.allocator);

        const dto = try self.allocator.create(DTO);
        dto.* = DTO{
            .bus = self,
            .state = self.state,
            .device = undefined,
        };
        try self.dtos.append(self.allocator, dto);

        if (sd_bus.sd_bus_add_match(
            self.system_bus,
            null,
            "type='signal',path='/org/freedesktop/UPower',interface='org.freedesktop.UPower',member='DeviceAdded'",
            handleDeviceAdded,
            dto,
        ) < 0) {
            std.debug.print("Failed to add match\n", .{});
            return error.MatchAddError;
        }

        if (sd_bus.sd_bus_add_match(
            self.system_bus,
            null,
            "type='signal',path='/org/freedesktop/UPower',interface='org.freedesktop.UPower',member='DeviceRemoved'",
            handleDeviceRemoved,
            dto,
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
                const device = try self.state.addDevice(p);

                // C:
                // ret = upower_device_register_notification(bus, device);
                // if (ret < 0) {
                //     goto error;
                // }
                self.registerDevicePropertiesChanged(device) catch |er| {
                    std.debug.print("ERROR registerDevicePropertiesChanged: {any}", .{er});
                    return er;
                };

                // C:
                // ret = upower_device_update_state(bus, device);
                // if (ret < 0) {
                //     goto error;
                // }
                try self.updateDeviceState(device);
            } else {
                std.debug.print("path empty\n", .{});
            }
        }

        _ = sd_bus.sd_bus_message_exit_container(msg);

        return self.state;
    }

    pub fn process(self: *const Bus) i32 {
        return sd_bus.sd_bus_process(self.system_bus, null);
    }

    pub fn wait(self: *const Bus) i32 {
        return sd_bus.sd_bus_wait(self.system_bus, std.math.maxInt(u64));
    }

    pub fn registerDevicePropertiesChanged(self: *Bus, device: *upower.UPowerDevice) !void {
        std.debug.print("registerDevicePropertiesChanged: {?s}\n", .{device.path});

        if (device.match_properties_changed) |match| {
            std.debug.print("Adding match for {s}\n", .{match});

            const dto = try self.allocator.create(DTO);
            dto.* = DTO{
                .bus = self,
                .state = self.state,
                .device = device,
            };
            try self.dtos.append(self.allocator, dto);

            const ret = sd_bus.sd_bus_add_match(
                self.system_bus,
                &device.slot,
                match,
                handleDevicePropertiesChanged,
                dto,
            );
            if (ret < 0) {
                std.debug.print("Failed to add match {d}\n", .{ret});
                return error.MatchAddError;
            }
        } else {
            std.debug.print("Failed to add match (empty)\n", .{});
            return error.MatchAddError;
        }
    }

    // upower_device_update_state
    pub fn updateDeviceState(self: *const Bus, device: *upower.UPowerDevice) !void {
        var err: sd_bus.sd_bus_error = std.mem.zeroInit(sd_bus.sd_bus_error, .{});
        defer {
            _ = sd_bus.sd_bus_error_free(&err);
        }

        std.debug.print("updateDeviceState: {?s}\n", .{device.path});

        std.debug.print("-------------------------------------------------\n", .{});
        std.debug.print("old device state:\n", .{});
        std.debug.print("native_path: {?s}\n", .{device.native_path});
        std.debug.print("model: {?s}\n", .{device.model});
        std.debug.print("power_supply: {}\n", .{device.power_supply});
        std.debug.print("type: {}\n", .{device.type});
        std.debug.print("current.online: {}\n", .{device.current.online});
        std.debug.print("current.state: {}\n", .{device.current.state});
        std.debug.print("current.warning_level: {}\n", .{device.current.warning_level});
        std.debug.print("current.battery_level: {}\n", .{device.current.battery_level});
        std.debug.print("current.percentage: {d}\n", .{device.current.percentage});
        var tmp: [*c]u8 = null;

        if (sd_bus.sd_bus_get_property_string(
            self.system_bus,
            "org.freedesktop.UPower",
            device.path,
            "org.freedesktop.UPower.Device",
            "NativePath",
            &err,
            &tmp,
        ) < 0) {
            std.debug.print("Failed to update property\n", .{});
            return error.PropertyUpdateError;
        }
        if (device.native_path) |prop| {
            device.allocator.free(prop[0..(std.mem.len(prop) + 1)]);
        }
        device.native_path = try std.fmt.allocPrintSentinel(device.allocator, "{s}", .{tmp}, 0);

        if (sd_bus.sd_bus_get_property_string(
            self.system_bus,
            "org.freedesktop.UPower",
            device.path,
            "org.freedesktop.UPower.Device",
            "Model",
            &err,
            &tmp,
        ) < 0) {
            std.debug.print("Failed to update property\n", .{});
            return error.PropertyUpdateError;
        }
        if (device.model) |prop| {
            device.allocator.free(prop[0..(std.mem.len(prop) + 1)]);
        }
        device.model = try std.fmt.allocPrintSentinel(device.allocator, "{s}", .{tmp}, 0);

        if (sd_bus.sd_bus_get_property_trivial(
            self.system_bus,
            "org.freedesktop.UPower",
            device.path,
            "org.freedesktop.UPower.Device",
            "PowerSupply",
            &err,
            'b',
            &device.power_supply,
        ) < 0) {
            std.debug.print("Failed to update property\n", .{});
            return error.PropertyUpdateError;
        }

        if (sd_bus.sd_bus_get_property_trivial(
            self.system_bus,
            "org.freedesktop.UPower",
            device.path,
            "org.freedesktop.UPower.Device",
            "Type",
            &err,
            'u',
            &device.type,
        ) < 0) {
            std.debug.print("Failed to update property\n", .{});
            return error.PropertyUpdateError;
        }

        if (sd_bus.sd_bus_get_property_trivial(
            self.system_bus,
            "org.freedesktop.UPower",
            device.path,
            "org.freedesktop.UPower.Device",
            "Online",
            &err,
            'b',
            &device.current.online,
        ) < 0) {
            std.debug.print("Failed to update property\n", .{});
            return error.PropertyUpdateError;
        }

        if (sd_bus.sd_bus_get_property_trivial(
            self.system_bus,
            "org.freedesktop.UPower",
            device.path,
            "org.freedesktop.UPower.Device",
            "State",
            &err,
            'u',
            &device.current.state,
        ) < 0) {
            std.debug.print("Failed to update property\n", .{});
            return error.PropertyUpdateError;
        }

        if (sd_bus.sd_bus_get_property_trivial(
            self.system_bus,
            "org.freedesktop.UPower",
            device.path,
            "org.freedesktop.UPower.Device",
            "WarningLevel",
            &err,
            'u',
            &device.current.warning_level,
        ) < 0) {
            std.debug.print("Failed to update property\n", .{});
            return error.PropertyUpdateError;
        }

        if (sd_bus.sd_bus_get_property_trivial(
            self.system_bus,
            "org.freedesktop.UPower",
            device.path,
            "org.freedesktop.UPower.Device",
            "BatteryLevel",
            &err,
            'u',
            &device.current.battery_level,
        ) < 0) {
            std.debug.print("Failed to update property\n", .{});
            return error.PropertyUpdateError;
        }

        if (sd_bus.sd_bus_get_property_trivial(
            self.system_bus,
            "org.freedesktop.UPower",
            device.path,
            "org.freedesktop.UPower.Device",
            "Percentage",
            &err,
            'd',
            &device.current.percentage,
        ) < 0) {
            std.debug.print("Failed to update property\n", .{});
            return error.PropertyUpdateError;
        }
        std.debug.print("---\n", .{});
        std.debug.print("new device state:\n", .{});
        std.debug.print("native_path: {?s}\n", .{device.native_path});
        std.debug.print("model: {?s}\n", .{device.model});
        std.debug.print("power_supply: {}\n", .{device.power_supply});
        std.debug.print("type: {}\n", .{device.type});
        std.debug.print("current.online: {}\n", .{device.current.online});
        std.debug.print("current.state: {}\n", .{device.current.state});
        std.debug.print("current.warning_level: {}\n", .{device.current.warning_level});
        std.debug.print("current.battery_level: {}\n", .{device.current.battery_level});
        std.debug.print("current.percentage: {d}\n", .{device.current.percentage});
        std.debug.print("-------------------------------------------------\n", .{});
    }

    pub fn sendNotification(self: *const Bus, summary: [:0]const u8, body: [:0]const u8, category: [:0]const u8, id: ?u32, urgency: Urgency) !void {
        var msg: ?*sd_bus.sd_bus_message = null;
        var err: sd_bus.sd_bus_error = std.mem.zeroInit(sd_bus.sd_bus_error, .{});
        defer {
            _ = sd_bus.sd_bus_message_unref(msg);
            _ = sd_bus.sd_bus_error_free(&err);
        }

        std.debug.print("Sending notification: {s}\n{s}\nCategory: {s}\n---\n", .{
            summary,
            body,
            category,
        });

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
        std.debug.print("sendOnlineUpdateNotification: {?s}\n", .{device.path});
        std.debug.print("current.state: {d}\n", .{@intFromEnum(device.current.state)});
        std.debug.print("last.state: {d}\n", .{@intFromEnum(device.last.state)});

        if (device.current.online == device.last.online) {
            return;
        }

        var title: [NOTIFICATION_MAX_LEN]u8 = undefined;
        var cstr: [:0]u8 = undefined;
        var cstr_set: bool = false;
        var msg: [:0]u8 = undefined;
        var msg_buf: [128:0]u8 = undefined;
        var category: [:0]u8 = undefined;
        var category_buf: [64:0]u8 = undefined;

        if (device.model) |model| {
            if (std.mem.len(model) > 0) {
                cstr = try std.fmt.bufPrintZ(&title, "Power status: {s}", .{model});
                cstr_set = true;
            }
        }
        if (!cstr_set) {
            if (device.native_path) |native_path| {
                cstr = try std.fmt.bufPrintZ(&title, "Power status: {s} ({s})", .{ native_path, @tagName(device.type) });
            } else {
                if (device.path) |path| {
                    cstr = try std.fmt.bufPrintZ(&title, "Power status: {s} ({s})", .{ path, @tagName(device.type) });
                } else {
                    cstr = try std.fmt.bufPrintZ(&title, "Power status: UNKNOWN ({s})", .{@tagName(device.type)});
                }
            }
        }

        if (device.current.online != 0) {
            msg = try std.fmt.bufPrintZ(&msg_buf, "Power supply online", .{});
            category = try std.fmt.bufPrintZ(&category_buf, "power.online", .{});
        } else {
            msg = try std.fmt.bufPrintZ(&msg_buf, "Power supply offline", .{});
            category = try std.fmt.bufPrintZ(&category_buf, "power.offline", .{});
        }

        return self.sendNotification(cstr, msg, category, device.notifications[@intFromEnum(upower.ChangeSlot.SLOT_ONLINE)], .URGENCY_NORMAL);
    }

    pub fn sendStateUpdateNotification(self: *const Bus, device: *upower.UPowerDevice) !void {
        std.debug.print("sendStateUpdateNotification: {?s}\n", .{device.path});
        std.debug.print("current.state: {d}\n", .{@intFromEnum(device.current.state)});
        std.debug.print("last.state: {d}\n", .{@intFromEnum(device.last.state)});

        if (device.current.state == device.last.state) {
            return;
        }

        // Fix for https://lists.sr.ht/~kennylevinsen/poweralertd-devel/%3C66a8abdc-54cc-4f19-af5d-648f773a7fa2@xn--gckvb8fzb.com%3E
        if (device.current.state == .UPOWER_DEVICE_STATE_CHARGING and
            device.last.state == .UPOWER_DEVICE_STATE_FULLY_CHARGED and
            device.current.percentage == 100)
        {
            return;
        }
        if (device.current.state == .UPOWER_DEVICE_STATE_FULLY_CHARGED and
            device.current.percentage == 100 and
            device.last.state == .UPOWER_DEVICE_STATE_CHARGING and
            device.last.percentage == 100)
        {
            return;
        }

        var urgency: Urgency = .URGENCY_NORMAL;
        var title: [NOTIFICATION_MAX_LEN]u8 = undefined;
        var cstr: [:0]u8 = undefined;
        var msg: [:0]u8 = undefined;
        var msg_buf: [128:0]u8 = undefined;
        // var category: []u8 = "";

        std.debug.print("sendStateUpdateNotification->check current.state: {s}\n", .{@tagName(device.current.state)});
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

        std.debug.print("sendStateUpdateNotification->check model\n", .{});
        if (device.model) |model| {
            if (std.mem.len(model) > 0) {
                cstr = try std.fmt.bufPrintZ(&title, "Power status: {s}", .{model});
            }
        } else {
            cstr = try std.fmt.bufPrintZ(&title, "Power status: {?s} ({s})", .{ device.native_path, @tagName(device.type) });
        }

        if (device.current.battery_level != .UPOWER_DEVICE_LEVEL_NONE) {
            msg = try std.fmt.bufPrintZ(&msg_buf, "Battery {s}\nCurrent level: {s}%\n", .{ device.stateStr(), device.batteryLevelStr() });
        } else {
            msg = try std.fmt.bufPrintZ(&msg_buf, "Battery {s}\nCurrent level: {d}%\n", .{ device.stateStr(), device.current.percentage });
        }

        return self.sendNotification(cstr, msg, "power.update", device.notifications[@intFromEnum(upower.ChangeSlot.SLOT_STATE)], urgency);
    }

    pub fn sendWarningUpdateNotification(self: *const Bus, device: *upower.UPowerDevice) !void {
        if (device.current.warning_level == device.last.warning_level) {
            return;
        }

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
