const std = @import("std");
const builtin = @import("builtin");
const keygen = @import("keygen.zig");

const is_windows = builtin.os.tag == .windows;
const is_macos = builtin.os.tag == .macos;
const APP_VERSION = "4.3.0";

const WinApi = if (is_windows) struct {
    pub extern "kernel32" fn WideCharToMultiByte(
        code_page: c_uint,
        flags: c_uint,
        wide: [*]const u16,
        wide_len: c_int,
        mb: ?[*]u8,
        mb_len: c_int,
        default_char: ?[*]const u8,
        used_default: ?*c_int,
    ) callconv(.winapi) c_int;
    pub extern "kernel32" fn SetConsoleOutputCP(code_page: c_uint) callconv(.winapi) c_int;
} else struct {};

const Encoding = enum { ascii, ansi, utf8 };

const Options = struct {
    username: []const u8 = "",
    license: []const u8 = "",
    encoding: Encoding = .utf8,
    output_file: []const u8 = "rarreg.key",
    output_set: bool = false,
    text_only: bool = false,
    activate: bool = false,
    show_version: bool = false,
    show_help: bool = false,
    check_update: bool = false,
};

fn parseArguments(gpa: std.mem.Allocator, args: []const [:0]const u8, opts: *Options) !bool {
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(gpa);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version") or std.ascii.eqlIgnoreCase(arg, "ver")) {
            opts.show_version = true;
            return true;
        }
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help") or std.ascii.eqlIgnoreCase(arg, "help")) {
            opts.show_help = true;
            return true;
        }
        if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--text")) {
            opts.text_only = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--activate")) {
            opts.activate = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--update")) {
            opts.check_update = true;
            return true;
        }
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--encoding")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: Missing value for {s}\n", .{arg});
                return false;
            }
            const val: []const u8 = args[i];
            if (std.ascii.eqlIgnoreCase(val, "ascii")) {
                opts.encoding = .ascii;
            } else if (std.ascii.eqlIgnoreCase(val, "ansi")) {
                opts.encoding = .ansi;
            } else if (std.ascii.eqlIgnoreCase(val, "utf8") or std.ascii.eqlIgnoreCase(val, "utf-8")) {
                opts.encoding = .utf8;
            } else {
                std.debug.print("Error: Unknown encoding '{s}'. Use: ascii, ansi, utf8\n", .{val});
                return false;
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: Missing value for {s}\n", .{arg});
                return false;
            }
            opts.output_file = args[i];
            opts.output_set = true;
            continue;
        }
        if (arg.len != 0 and arg[0] == '-') {
            std.debug.print("Error: Unknown option '{s}'\n", .{arg});
            return false;
        }
        try positional.append(gpa, arg);
    }

    if (positional.items.len == 2) {
        opts.username = positional.items[0];
        opts.license = positional.items[1];
        return true;
    }
    if (positional.items.len == 0) {
        opts.show_help = true;
        return true;
    }
    std.debug.print("Error: Expected 2 arguments (Username, LicenseName), got {d}\n", .{positional.items.len});
    return false;
}

fn writeStdout(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

fn showHelp(gpa: std.mem.Allocator, io: std.Io) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.print(gpa,
        \\WinRAR Keygen v{s}
        \\
        \\Usage:
        \\  winrar-keygen <Username> <LicenseName> [options]
        \\  winrar-keygen -v | --version
        \\  winrar-keygen -h | --help
        \\
        \\Options:
        \\  -e, --encoding <enc>   utf8 (default), ascii, ansi
        \\  -o, --output <file>    Output file (default: rarreg.key)
        \\
    , .{APP_VERSION});
    if (is_windows) {
        try out.appendSlice(gpa, "  -a, --activate         Write to %APPDATA%\\WinRAR\\rarreg.key\n");
    } else if (is_macos) {
        try out.appendSlice(gpa, "  -a, --activate         Write to ~/Library/Application Support/com.rarlab.WinRAR/rarreg.key\n");
    } else {
        try out.appendSlice(gpa, "  -a, --activate         Write to ~/.rarkey\n");
    }
    try out.print(gpa,
        \\  -t, --text             Print to console only, don't write file
        \\  -u, --update           Check for updates on GitHub
        \\  -v, --version          Show version
        \\  -h, --help             Show this help
        \\
        \\Examples:
        \\  winrar-keygen "Github" "Single PC usage license"
        \\  winrar-keygen "Github" "Single PC usage license" -e ascii
        \\  winrar-keygen "Github" "Single PC usage license" -a
        \\  winrar-keygen "Github" "Single PC usage license" -t
        \\
    , .{});
    try writeStdout(io, out.items);
}

fn hasNonAscii(s: []const u8) bool {
    for (s) |c| if (c > 127) return true;
    return false;
}

fn startsWithUtf8Prefix(s: []const u8) bool {
    return s.len >= 5 and std.mem.eql(u8, s[0..5], "utf8:");
}

fn toAnsi(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    if (comptime is_windows) {
        const wide = try std.unicode.utf8ToUtf16LeAlloc(gpa, s);
        defer gpa.free(wide);
        const n = WinApi.WideCharToMultiByte(0, 0, wide.ptr, @intCast(wide.len), null, 0, null, null);
        if (n <= 0) return gpa.dupe(u8, s);
        const buf = try gpa.alloc(u8, @intCast(n));
        var used: c_int = 0;
        _ = WinApi.WideCharToMultiByte(0, 0, wide.ptr, @intCast(wide.len), buf.ptr, n, null, &used);
        if (used != 0) {
            gpa.free(buf);
            return error.UnrepresentableInAnsi;
        }
        return buf;
    } else {
        return gpa.dupe(u8, s);
    }
}

fn buildRegFileContent(gpa: std.mem.Allocator, info: *const keygen.RegisterInfo) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "RAR registration data\r\n");
    try out.appendSlice(gpa, info.user_name);
    try out.appendSlice(gpa, "\r\n");
    try out.appendSlice(gpa, info.license_type);
    try out.appendSlice(gpa, "\r\n");
    try out.print(gpa, "UID={s}\r\n", .{info.uid});
    var i: usize = 0;
    while (i < info.hex_data.len) : (i += 54) {
        try out.appendSlice(gpa, info.hex_data[i .. i + 54]);
        try out.appendSlice(gpa, "\r\n");
    }
    return out.toOwnedSlice(gpa);
}

fn printRegisterInfo(gpa: std.mem.Allocator, out: *std.ArrayList(u8), info: *const keygen.RegisterInfo, user: []const u8, license: []const u8) !void {
    try out.print(gpa, "RAR registration data\n{s}\n{s}\nUID={s}\n", .{ user, license, info.uid });
    var i: usize = 0;
    while (i < info.hex_data.len) : (i += 54) {
        try out.appendSlice(gpa, info.hex_data[i .. i + 54]);
        try out.append(gpa, '\n');
    }
}

const Version = struct {
    major: u32 = 0,
    minor: u32 = 0,
    patch: u32 = 0,
    valid: bool = false,
};

fn parseVersion(s: []const u8) Version {
    var v = Version{};
    const body = if (s.len != 0 and (s[0] == 'v' or s[0] == 'V')) s[1..] else s;
    var it = std.mem.splitScalar(u8, body, '.');
    const major = it.next() orelse return v;
    const minor = it.next() orelse return v;
    const patch = it.next() orelse "0";
    v.major = std.fmt.parseInt(u32, major, 10) catch return v;
    v.minor = std.fmt.parseInt(u32, minor, 10) catch return v;
    v.patch = std.fmt.parseInt(u32, patch, 10) catch 0;
    v.valid = true;
    return v;
}

fn isNewer(remote: Version, local: Version) bool {
    if (remote.major != local.major) return remote.major > local.major;
    if (remote.minor != local.minor) return remote.minor > local.minor;
    return remote.patch > local.patch;
}

fn extractTagFromJson(body: []const u8) ?[]const u8 {
    const key = "\"tag_name\"";
    const pos = std.mem.indexOf(u8, body, key) orelse return null;
    const start = std.mem.indexOfScalarPos(u8, body, pos + key.len, '"') orelse return null;
    const end = std.mem.indexOfScalarPos(u8, body, start + 1, '"') orelse return null;
    return body[start + 1 .. end];
}

fn checkForUpdate(gpa: std.mem.Allocator, io: std.Io, current: []const u8) void {
    std.debug.print("Checking for updates...\n", .{});

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    _ = client.fetch(.{
        .location = .{ .url = "https://api.github.com/repos/bitcookies/winrar-keygen/releases/latest" },
        .response_writer = &aw.writer,
        .headers = .{ .user_agent = .{ .override = "winrar-keygen-updater" } },
    }) catch {
        std.debug.print("Error: Failed to fetch update info. Check your network connection.\n", .{});
        return;
    };

    const body = aw.written();
    const remote_tag = extractTagFromJson(body) orelse {
        std.debug.print("Error: Could not find version info in GitHub response.\n", .{});
        return;
    };

    const local = parseVersion(current);
    const remote = parseVersion(remote_tag);
    if (!local.valid) {
        std.debug.print("Error: Could not parse current version '{s}'.\n", .{current});
        return;
    }
    if (!remote.valid) {
        std.debug.print("Error: Could not parse remote version '{s}'.\n", .{remote_tag});
        return;
    }

    if (isNewer(remote, local)) {
        std.debug.print("\n  New version available: {s} (current: v{s})\n", .{ remote_tag, current });
        std.debug.print("  Download: https://github.com/bitcookies/winrar-keygen/releases/latest\n\n", .{});
    } else {
        std.debug.print("Already up to date. (v{s})\n", .{current});
    }
}

fn tooLong(s: []const u8) bool {
    const n = std.unicode.utf8CountCodepoints(s) catch return s.len > 200;
    return n > 200;
}

pub fn main(init: std.process.Init) !u8 {
    if (comptime is_windows) _ = WinApi.SetConsoleOutputCP(65001);

    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var opts = Options{};
    if (!try parseArguments(gpa, args, &opts)) return 255;

    if (opts.show_version) {
        var buf: [64]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "winrar-keygen v{s}\n", .{APP_VERSION});
        try writeStdout(io, s);
        return 0;
    }
    if (opts.show_help) {
        try showHelp(gpa, io);
        return 0;
    }
    if (opts.check_update) {
        checkForUpdate(gpa, io, APP_VERSION);
        return 0;
    }

    if (opts.activate and opts.output_set) {
        std.debug.print("Error: --activate and -o cannot be used together.\n", .{});
        return 255;
    }
    if (opts.activate and opts.text_only) {
        std.debug.print("Error: --activate and -t cannot be used together.\n", .{});
        return 255;
    }

    if (opts.activate) {
        const home_dir = if (is_windows)
            init.environ_map.get("APPDATA")
        else
            init.environ_map.get("HOME");
        if (home_dir == null) {
            std.debug.print("Error: Failed to resolve home directory.\n", .{});
            return 255;
        }
        if (is_windows) {
            const dir = try std.fs.path.join(arena, &.{ home_dir.?, "WinRAR" });
            std.Io.Dir.cwd().createDirPath(io, dir) catch {};
            opts.output_file = try std.fs.path.join(arena, &.{ dir, "rarreg.key" });
        } else if (is_macos) {
            const dir = try std.fs.path.join(arena, &.{ home_dir.?, "Library", "Application Support", "com.rarlab.WinRAR" });
            std.Io.Dir.cwd().createDirPath(io, dir) catch {};
            opts.output_file = try std.fs.path.join(arena, &.{ dir, "rarreg.key" });
        } else {
            opts.output_file = try std.fs.path.join(arena, &.{ home_dir.?, ".rarkey" });
        }
    }

    if (opts.username.len == 0 or opts.license.len == 0) {
        std.debug.print("Error: Username and License Name must not be empty.\n", .{});
        return 255;
    }
    if (tooLong(opts.username) or tooLong(opts.license)) {
        std.debug.print("Error: Username and License Name must not exceed 200 characters.\n", .{});
        return 255;
    }

    var display_user: []const u8 = opts.username;
    var display_license: []const u8 = opts.license;
    var user: []const u8 = undefined;
    var license: []const u8 = undefined;

    switch (opts.encoding) {
        .utf8 => {
            if (hasNonAscii(display_user) and !startsWithUtf8Prefix(display_user)) {
                display_user = try std.fmt.allocPrint(arena, "utf8:{s}", .{display_user});
            }
            if (hasNonAscii(display_license) and !startsWithUtf8Prefix(display_license)) {
                display_license = try std.fmt.allocPrint(arena, "utf8:{s}", .{display_license});
            }
            user = display_user;
            license = display_license;
        },
        .ansi => {
            if (comptime !is_windows) {
                std.debug.print("Warning: ANSI encoding is not supported on this platform. Using UTF-8.\n", .{});
                user = display_user;
                license = display_license;
            } else {
                user = toAnsi(arena, display_user) catch {
                    std.debug.print("Error: Input contains characters not representable in the current ANSI code page. Use '-e utf8'.\n", .{});
                    return 255;
                };
                license = toAnsi(arena, display_license) catch {
                    std.debug.print("Error: Input contains characters not representable in the current ANSI code page. Use '-e utf8'.\n", .{});
                    return 255;
                };
            }
        },
        .ascii => {
            user = display_user;
            license = display_license;
            if (hasNonAscii(user)) {
                std.debug.print("Error: Username contains non-ASCII characters. Use '-e ansi' or '-e utf8'.\n", .{});
                return 255;
            }
            if (hasNonAscii(license)) {
                std.debug.print("Error: License name contains non-ASCII characters. Use '-e ansi' or '-e utf8'.\n", .{});
                return 255;
            }
        },
    }

    var kg = keygen.Keygen.init(gpa) catch {
        std.debug.print("Error: Failed to initialize keygen.\n", .{});
        return 255;
    };
    defer kg.deinit();

    var rng_source: std.Random.IoSource = .{ .io = io };
    const rng = rng_source.interface();

    const info = kg.generateRegisterInfo(rng, arena, user, license) catch {
        std.debug.print("Error: Failed to generate register data.\n", .{});
        return 255;
    };

    if (opts.text_only) {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try printRegisterInfo(gpa, &out, &info, display_user, display_license);
        try writeStdout(io, out.items);
    } else {
        const content = try buildRegFileContent(arena, &info);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = opts.output_file, .data = content }) catch {
            std.debug.print("Error: Failed to write file: {s}\n", .{opts.output_file});
            return 255;
        };

        const enc_name = if (opts.encoding == .ascii) "ASCII" else if (opts.encoding == .ansi and is_windows) "ANSI" else "UTF-8";
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try out.append(gpa, '\n');
        try printRegisterInfo(gpa, &out, &info, display_user, display_license);
        try out.print(gpa, "\nDone! {s} has been generated. ({s})\n", .{ opts.output_file, enc_name });
        try writeStdout(io, out.items);
    }

    return 0;
}
