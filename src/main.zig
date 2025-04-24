const std = @import("std");
const bus = @import("bus.zig");
const state = @import("state.zig");
const upower = @import("upower.zig");

pub fn main() !void {
    const gpa = std.heap.page_allocator;
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

    const the_bus = try bus.init(gpa);
    defer the_bus.deinit();

    const the_state = try the_bus.start();
    defer the_state.deinit();

    std.debug.print("entering main loop\n", .{});
    while (true) {
        std.debug.print("entering for devices\n", .{});
        for (the_state.devices.items) |*device| {
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

            if (device.hasBattery()) {
                the_bus.sendStateUpdateNotification(device) catch |err| {
                    std.debug.print("could not send state update notification {any}\n", .{err});
                    //     fprintf(stderr, "could not send state update notification: #{s}\n", strerror(-ret));
                    //     // goto finish;
                };
                the_bus.sendWarningUpdateNotification(device) catch |err| {
                    std.debug.print("could not send state warning update notification {any}\n", .{err});
                    //     fprintf(stderr, "could not send warning update notification: #{s}\n", strerror(-ret));
                    //     // goto finish;
                };
            } else {
                the_bus.sendOnlineUpdateNotification(device) catch |err| {
                    std.debug.print("could not send state online update notification {any}\n", .{err});
                    //     fprintf(stderr, "could not send online update notification: #{s}\n", strerror(-ret));
                    //     // goto finish;
                };
            }
            // device.last = device.current;
        }

        std.debug.print("entering for removed_devices\n", .{});
        for (the_state.removed_devices.items) |*device| {

            // if ((ignore_types_mask & (@as(c_uint, 1) << device.type))) {
            //     continue;
            // }

            if (ignore_non_power_supplies and !device.power_supply) {
                continue;
            }

            the_bus.sendRemoveNotification(device) catch |err| {
                std.debug.print("could not send device removal notification {any}\n", .{err});
                //     fprintf(stderr, "could not send device removal notification: #{s}\n", strerror(-ret));
                //     // goto finish;
            };
            // upower_device_destroy(device);
            // list_del(state.removed_devices, idx);
        }

        std.debug.print("sd_bus_process\n", .{});
        var ret = the_bus.process();
        if (ret < 0) {
            std.debug.print("could not process system bus messages: {d}\n", .{ret});
            // goto finish;
        } else if (ret > 0) {
            continue;
        }

        std.debug.print("sd_bus_wait\n", .{});
        ret = the_bus.wait();
        if (ret < 0) {
            std.debug.print("could not wait for system bus messages: {d}\n", .{ret});
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
