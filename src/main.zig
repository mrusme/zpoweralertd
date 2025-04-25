const std = @import("std");
const bus = @import("bus.zig");
const state = @import("state.zig");
const upower = @import("upower.zig");

const Args = struct {
    ignore_types_mask: u32 = 0,
    ignore_initial: bool = false,
    ignore_non_power_supplies: bool = false,
    initialized: bool = false,
    verbose: bool = false,
};

const ArgParseError = error{ MissingArgs, InvalidArgs, ProgramEnd };

fn display_usage(program_name: []const u8) void {
    const fmt =
        \\usage: {s} [options]
        \\
        \\Options:
        \\  -h                show this help message
        \\  -i <device_type>  ignore this device type, can be use several times
        \\  -s                ignore the events at startup
        \\  -S                only use the events coming from power supplies
        \\  -v                show the version number
        \\  -V                verbose output
        \\
        \\
    ;
    std.debug.print(fmt, .{program_name});
}

fn parseArgs(argv: [][:0]u8) ArgParseError!Args {
    const program_name = std.fs.path.basename(argv[0]);
    var args = Args{};

    var optind: usize = 1;
    while (optind < argv.len and argv[optind][0] == '-') {
        if (std.mem.eql(u8, argv[optind], "-V")) {
            args.verbose = true;
        } else if (std.mem.eql(u8, argv[optind], "-s")) {
            args.ignore_initial = true;
        } else if (std.mem.eql(u8, argv[optind], "-S")) {
            args.ignore_non_power_supplies = true;
        } else if (std.mem.eql(u8, argv[optind], "-v")) {
            std.debug.print("zpoweralertd version {s}\n", .{"0.0.0"});
            return error.ProgramEnd;
        } else if (std.mem.eql(u8, argv[optind], "-i")) {
            if (optind + 1 >= argv.len) {
                display_usage(program_name);
                return error.MissingArgs;
            }
            optind += 1;
            const device_type = std.meta.stringToEnum(upower.UPowerDeviceType, argv[optind]);
            if (device_type) |dt| {
                if (@intFromEnum(dt) > -1) {
                    args.ignore_types_mask |= @as(u32, 1) << @intCast(@intFromEnum(dt));
                }
            }
        } else {
            display_usage(program_name);
            std.debug.print("Unknown option: {s}\n", .{argv[optind]});
            return error.InvalidArgs;
        }
        optind += 1;
    }

    return args;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    //
    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // defer {
    //     std.debug.print("EXIT\n", .{});
    //     const deinit_status = gpa.deinit();
    //     if (deinit_status == .leak) {
    //         @panic("LEAK");
    //     }
    // }
    // const allocator = gpa.allocator();
    //
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);
    const args = parseArgs(argv) catch |err| {
        switch (err) {
            error.ProgramEnd => {
                std.process.exit(0);
            },
            else => {
                std.process.exit(1);
            },
        }
    };

    var initialized: bool = false;

    var start: std.os.linux.timespec = undefined;

    if (std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &start) != 0) {
        return error.ClockError;
    }

    const the_bus = try bus.init(allocator);
    defer the_bus.deinit();

    const the_state = try the_bus.start();

    std.debug.print("entering main loop\n", .{});

    // For debug (see bottom):
    var active = true;
    active = true;

    while (active) {
        std.debug.print("entering for(devices)\n", .{});
        for (the_state.devices.items) |device| {
            defer {
                std.debug.print("device.last = device.current\n", .{});
                device.last = device.current;
            }
            std.debug.print("\n\n1 typemask: {d}\n\n", .{(args.ignore_types_mask & (@as(u32, 1) << @intCast(@intFromEnum(device.type))))});
            if ((args.ignore_types_mask & (@as(u32, 1) << @intCast(@intFromEnum(device.type))) != 0)) {
                // device.last = device.current;
                std.debug.print("Ignore mask hit, continuing\n", .{});
                continue;
            }

            if (!initialized and args.ignore_initial) {
                // device.last = device.current;
                std.debug.print("Not initialized and ignore_initial is on, continuing\n", .{});
                continue;
            }

            if (args.ignore_non_power_supplies and device.power_supply != 0) {
                // device.last = device.current;
                std.debug.print("ignore_non_power_supplies on and device.power_supply is {d}, continuing\n", .{device.power_supply});
                continue;
            }

            std.debug.print("Processing device: {?s}\n", .{
                device.path,
            });

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
        for (the_state.removed_devices.items, 0..) |device, idx| {
            std.debug.print("\n\n2 typemask: {d}\n\n", .{(args.ignore_types_mask & (@as(u32, 1) << @intCast(@intFromEnum(device.type))))});
            if ((args.ignore_types_mask & (@as(u32, 1) << @intCast(@intFromEnum(device.type)))) != 0) {
                continue;
            }

            if (args.ignore_non_power_supplies and device.power_supply != 0) {
                continue;
            }

            the_bus.sendRemoveNotification(device) catch |err| {
                std.debug.print("could not send device removal notification {any}\n", .{err});
                //     fprintf(stderr, "could not send device removal notification: #{s}\n", strerror(-ret));
                //     // goto finish;
            };
            device.deinit();
            // upower_device_destroy(device);
            _ = try the_state.removeDevice(idx);
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

        std.debug.print("initialized? {}\n", .{initialized});
        if (!initialized) {
            initialized = millisecondsSince(&start) > 500;
        }

        std.debug.print("loop\n", .{});
        // For debug:
        // active = false;
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
