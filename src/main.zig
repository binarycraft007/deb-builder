const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const log = std.log.scoped(.deb_builder);
const builder = @import("builder.zig");

const usage =
    \\Usage: deb-builder [command] [package] [options]
    \\
    \\A declarative Debian package (.deb) builder and sysroot manager for Zig.
    \\
    \\Commands:
    \\  build [package]          Build deb package(s) (default)
    \\  install [package]        Build and install package(s) into sysroot
    \\  fetch [package]          Fetch sysroot build_depends without building
    \\
    \\Options:
    \\  -h, --help               Show this help message and exit
    \\  -a, --arch <arch>        Target architecture (e.g. amd64, arm64, riscv64)
    \\  -p, --package <name>     Target package name (or pass as positional arg)
    \\  -m, --manifest <file>    Manifest file path (default: packages.zon)
    \\  -o, --output-dir <dir>   Output directory for .deb files (default: packages)
    \\  -s, --sysroot <dir>      Override destination sysroot directory
    \\  -i, --install            Install built package(s) into sysroot
    \\  --suite <suite>          Debian/Ubuntu suite (e.g. bookworm, trixie, noble)
    \\  --mirror <url>           Debian/Ubuntu mirror URL
    \\
    \\Examples:
    \\  deb-builder                          # Build all packages in packages.zon
    \\  deb-builder math-app                 # Build single package
    \\  deb-builder math-app -a arm64        # Build math-app for arm64
    \\  deb-builder install libmath-helper   # Build and install to sysroot
    \\  deb-builder fetch math-app           # Fetch build_depends for math-app
    \\  deb-builder list                     # List packages in manifest
    \\  deb-builder -m custom.zon            # Use custom manifest
    \\
;

const Action = enum {
    build,
    install,
    fetch,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try init.minimal.args.toSlice(arena);

    var action: Action = .build;
    var manifest_path: []const u8 = "packages.zon";
    var opt_manifest: ?[]const u8 = null;
    var opt_package: ?[]const u8 = null;
    var opt_arch: ?[]const u8 = null;
    var opt_suite: ?[]const u8 = null;
    var opt_mirror: ?[]const u8 = null;
    var opt_sysroot: ?[]const u8 = null;
    var opt_output_dir: ?[]const u8 = null;
    var install_flag = false;
    var positional_count: usize = 0;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (mem.eql(u8, "-h", arg) or mem.eql(u8, "--help", arg)) {
            try Io.File.stdout().writeStreamingAll(io, usage);
            return std.process.cleanExit(io);
        } else if (mem.eql(u8, "-i", arg) or mem.eql(u8, "--install", arg) or mem.eql(u8, "--install-to-sysroot", arg)) {
            install_flag = true;
        } else if (mem.eql(u8, "--fetch-sysroot", arg)) {
            action = .fetch;
        } else if (mem.eql(u8, "-a", arg) or mem.eql(u8, "--arch", arg) or mem.eql(u8, "--target", arg) or mem.eql(u8, "--architecture", arg)) {
            if (opt_arch != null) fatal("duplicated {s} argument", .{arg});
            opt_arch = getArgValue(args, &i, arg);
        } else if (mem.startsWith(u8, arg, "--arch=")) {
            if (opt_arch != null) fatal("duplicated --arch argument", .{});
            opt_arch = arg["--arch=".len..];
        } else if (mem.startsWith(u8, arg, "--target=")) {
            if (opt_arch != null) fatal("duplicated --target argument", .{});
            opt_arch = arg["--target=".len..];
        } else if (mem.startsWith(u8, arg, "--architecture=")) {
            if (opt_arch != null) fatal("duplicated --architecture argument", .{});
            opt_arch = arg["--architecture=".len..];
        } else if (mem.eql(u8, "-p", arg) or mem.eql(u8, "--package", arg)) {
            if (opt_package != null) fatal("duplicated {s} argument", .{arg});
            opt_package = getArgValue(args, &i, arg);
        } else if (mem.startsWith(u8, arg, "--package=")) {
            if (opt_package != null) fatal("duplicated --package argument", .{});
            opt_package = arg["--package=".len..];
        } else if (mem.eql(u8, "-m", arg) or mem.eql(u8, "--manifest", arg)) {
            if (opt_manifest != null) fatal("duplicated {s} argument", .{arg});
            opt_manifest = getArgValue(args, &i, arg);
        } else if (mem.startsWith(u8, arg, "--manifest=")) {
            if (opt_manifest != null) fatal("duplicated --manifest argument", .{});
            opt_manifest = arg["--manifest=".len..];
        } else if (mem.eql(u8, "-o", arg) or mem.eql(u8, "--output-dir", arg) or mem.eql(u8, "--out", arg)) {
            if (opt_output_dir != null) fatal("duplicated {s} argument", .{arg});
            opt_output_dir = getArgValue(args, &i, arg);
        } else if (mem.startsWith(u8, arg, "--output-dir=")) {
            if (opt_output_dir != null) fatal("duplicated --output-dir argument", .{});
            opt_output_dir = arg["--output-dir=".len..];
        } else if (mem.startsWith(u8, arg, "--out=")) {
            if (opt_output_dir != null) fatal("duplicated --out argument", .{});
            opt_output_dir = arg["--out=".len..];
        } else if (mem.eql(u8, "-s", arg) or mem.eql(u8, "--sysroot", arg)) {
            if (opt_sysroot != null) fatal("duplicated {s} argument", .{arg});
            opt_sysroot = getArgValue(args, &i, arg);
        } else if (mem.startsWith(u8, arg, "--sysroot=")) {
            if (opt_sysroot != null) fatal("duplicated --sysroot argument", .{});
            opt_sysroot = arg["--sysroot=".len..];
        } else if (mem.eql(u8, "--suite", arg)) {
            if (opt_suite != null) fatal("duplicated {s} argument", .{arg});
            opt_suite = getArgValue(args, &i, arg);
        } else if (mem.startsWith(u8, arg, "--suite=")) {
            if (opt_suite != null) fatal("duplicated --suite argument", .{});
            opt_suite = arg["--suite=".len..];
        } else if (mem.eql(u8, "--mirror", arg)) {
            if (opt_mirror != null) fatal("duplicated {s} argument", .{arg});
            opt_mirror = getArgValue(args, &i, arg);
        } else if (mem.startsWith(u8, arg, "--mirror=")) {
            if (opt_mirror != null) fatal("duplicated --mirror argument", .{});
            opt_mirror = arg["--mirror=".len..];
        } else if (!mem.startsWith(u8, arg, "-")) {
            if (positional_count == 0) {
                if (mem.eql(u8, "fetch", arg) or mem.eql(u8, "fetch-sysroot", arg) or mem.eql(u8, "sysroot", arg)) {
                    action = .fetch;
                } else if (mem.eql(u8, "install", arg)) {
                    action = .install;
                } else if (mem.eql(u8, "build", arg)) {
                    action = .build;
                } else if (mem.endsWith(u8, arg, ".zon")) {
                    manifest_path = arg;
                } else {
                    if (opt_package != null) fatal("unexpected argument: '{s}'", .{arg});
                    opt_package = arg;
                }
            } else if (positional_count == 1) {
                if (mem.endsWith(u8, arg, ".zon")) {
                    manifest_path = arg;
                } else if (opt_package == null) {
                    opt_package = arg;
                } else {
                    manifest_path = arg;
                }
            } else if (positional_count == 2) {
                if (mem.endsWith(u8, arg, ".zon")) {
                    manifest_path = arg;
                } else {
                    fatal("unexpected positional argument: '{s}'", .{arg});
                }
            } else {
                fatal("too many positional arguments: '{s}'", .{arg});
            }
            positional_count += 1;
        } else {
            fatal("unrecognized arg: '{s}'", .{arg});
        }
    }

    if (opt_manifest) |m| {
        manifest_path = m;
    }

    const install_to_sysroot = install_flag or (action == .install);

    const manifest = builder.parseManifestFile(io, arena, manifest_path) catch |err| {
        fatal("unable to parse manifest '{s}': {s}", .{ manifest_path, @errorName(err) });
    };

    if (action == .fetch) {
        builder.fetchManifestBuildDepends(io, gpa, manifest, opt_package, opt_arch, opt_suite, opt_mirror, opt_sysroot) catch |err| {
            fatal("failed to fetch sysroot build dependencies: {s}", .{@errorName(err)});
        };
    } else if (opt_package) |pkg_name| {
        const out_debs = builder.packageByName(io, gpa, manifest, pkg_name, opt_arch, opt_suite, opt_mirror, install_to_sysroot, opt_sysroot, opt_output_dir) catch |err| {
            fatal("failed to package '{s}': {s}", .{ pkg_name, @errorName(err) });
        };
        defer {
            for (out_debs) |d| gpa.free(d);
            gpa.free(out_debs);
        }
    } else {
        builder.packageManifestWithOptions(io, gpa, manifest, opt_arch, opt_suite, opt_mirror, install_to_sysroot, opt_sysroot, opt_output_dir) catch |err| {
            fatal("packaging failed: {s}", .{@errorName(err)});
        };
    }

    return std.process.cleanExit(io);
}

fn getArgValue(args: []const []const u8, i: *usize, option: []const u8) []const u8 {
    i.* += 1;
    if (i.* >= args.len) fatal("expected arg after '{s}'", .{option});
    return args[i.*];
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    std.process.exit(1);
}

test {
    _ = builder;
}
