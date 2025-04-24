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

    pub fn state_string(self: *const UPowerDevice) [:0]const u8 {
        if (@intFromEnum(self.current.state) >= @intFromEnum(UPowerDeviceState.UPOWER_DEVICE_STATE_UNKNOWN) and
            @intFromEnum(self.current.state) < @intFromEnum(UPowerDeviceState.UPOWER_DEVICE_STATE_LAST))
        {
            return @tagName(self.current.state);
        }
        return "unknown";
    }

    pub fn warning_level_string(self: *const UPowerDevice) [:0]const u8 {
        if (@intFromEnum(self.current.warning_level) >= @intFromEnum(UPowerDeviceLevel.UPOWER_DEVICE_LEVEL_UNKNOWN) and
            @intFromEnum(self.current.warning_level) < @intFromEnum(UPowerDeviceLevel.UPOWER_DEVICE_LEVEL_LAST))
        {
            return @tagName(self.current.warning_level);
        }
        return "unknown";
    }

    pub fn battery_level_string(self: *const UPowerDevice) [:0]const u8 {
        if (@intFromEnum(self.current.battery_level) >= @intFromEnum(UPowerDeviceLevel.UPOWER_DEVICE_LEVEL_UNKNOWN) and
            @intFromEnum(self.current.battery_level) < @intFromEnum(UPowerDeviceLevel.UPOWER_DEVICE_LEVEL_LAST))
        {
            return @tagName(self.current.battery_level);
        }
        return "unknown";
    }

    pub fn type_string(self: *const UPowerDevice) [:0]const u8 {
        if (@intFromEnum(self.type) >= @intFromEnum(UPowerDeviceType.UPOWER_DEVICE_TYPE_UNKNOWN) and
            @intFromEnum(self.type) < @intFromEnum(UPowerDeviceType.UPOWER_DEVICE_TYPE_LAST))
        {
            return @tagName(self.type);
        }
        return "unknown";
    }

    pub fn type_int(_: *const UPowerDevice, device: *[]u8) i64 {
        for (UPowerDeviceType, 0..) |dtype, idx| {
            if (std.mem.eql(@tagName(dtype), device)) {
                return idx;
            }
        }
        return -1;
    }
};

pub fn print_device(dev: *const UPowerDevice) void {
    std.debug.print("Device: {s}\n", .{dev.native_path.?});
    std.debug.print("  Type: {}\n", .{dev.type});
}
