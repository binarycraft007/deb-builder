const std = @import("std");
const mem = std.mem;
const Io = std.Io;
const deb = @import("deb");
const log = std.log.scoped(.deb_builder);

pub const ExtraField = struct {
    name: []const u8,
    value: []const u8,
};

pub const FileMapping = struct {
    src: []const u8,
    dest: []const u8 = "",
    mode: ?u32 = null, // e.g. 0o755, 0o644
    executable_patterns: []const []const u8 = &.{},
    exclude_files: []const []const u8 = &.{},
    exclude_extensions: []const []const u8 = &.{},
};

pub const SymlinkMapping = struct {
    link: []const u8,
    target: []const u8,
};

pub const PackageDefinition = struct {
    name: []const u8,
    version: []const u8 = "1.0.0",
    architecture: []const u8 = "amd64",
    architectures: []const []const u8 = &.{},
    maintainer: []const u8 = "Maintainer <maintainer@example.com>",
    description: []const u8 = "Debian Package",
    section: []const u8 = "misc",
    priority: []const u8 = "optional",
    essential: bool = false,
    homepage: ?[]const u8 = null,

    depends: []const []const u8 = &.{},
    build_depends: []const []const u8 = &.{},
    pre_depends: []const []const u8 = &.{},
    recommends: []const []const u8 = &.{},
    suggests: []const []const u8 = &.{},
    enhances: []const []const u8 = &.{},
    conflicts: []const []const u8 = &.{},
    breaks: []const []const u8 = &.{},
    provides: []const []const u8 = &.{},
    replaces: []const []const u8 = &.{},
    extra_fields: []const ExtraField = &.{},

    // Maintainer scripts: inline or loaded from disk
    preinst_script: ?[]const u8 = null,
    preinst_file: ?[]const u8 = null,
    postinst_script: ?[]const u8 = null,
    postinst_file: ?[]const u8 = null,
    prerm_script: ?[]const u8 = null,
    prerm_file: ?[]const u8 = null,
    postrm_script: ?[]const u8 = null,
    postrm_file: ?[]const u8 = null,

    file_mappings: []const FileMapping = &.{},
    symlinks: []const SymlinkMapping = &.{},
    out_dir: []const u8 = "packages",
    out_deb_path: ?[]const u8 = null,

    // Sysroot / build_depends options
    fetch_sysroot: bool = false,
    install_to_sysroot: bool = false,
    sysroot_dir: ?[]const u8 = null,
    suite: ?[]const u8 = null,
    mirror: ?[]const u8 = null,
    sysroot_cache_dir: ?[]const u8 = null,
    no_sysroot_fixup: bool = false,

    pub fn getArchitectures(self: PackageDefinition) []const []const u8 {
        if (self.architectures.len > 0) {
            return self.architectures;
        }
        return &.{self.architecture};
    }
};

pub const Manifest = struct {
    suite: ?[]const u8 = null,
    mirror: ?[]const u8 = null,
    packages: []const PackageDefinition = &.{},

    pub fn findPackage(self: Manifest, name: []const u8) ?PackageDefinition {
        for (self.packages) |pkg| {
            if (std.mem.eql(u8, pkg.name, name)) {
                return pkg;
            }
        }
        return null;
    }
};

pub fn formatDependencyList(allocator: mem.Allocator, list: []const []const u8) !?[]const u8 {
    if (list.len == 0) return null;
    return try mem.join(allocator, ", ", list);
}

pub fn resolvePathVarsWithSysroot(
    allocator: mem.Allocator,
    template: []const u8,
    arch: []const u8,
    sysroot_path: ?[]const u8,
) ![]u8 {
    const triplet = getMultiarchTriplet(arch);
    const deb_arch = toDebianArch(arch);

    var res = try mem.replaceOwned(u8, allocator, template, "{triplet}", triplet);
    errdefer allocator.free(res);

    var res2 = try mem.replaceOwned(u8, allocator, res, "{arch}", deb_arch);
    allocator.free(res);
    res = res2;

    if (sysroot_path) |sys| {
        res2 = try mem.replaceOwned(u8, allocator, res, "{sysroot}", sys);
        allocator.free(res);
        res = res2;
    }

    return res;
}

pub fn resolvePathVars(allocator: mem.Allocator, template: []const u8, arch: []const u8) ![]u8 {
    return resolvePathVarsWithSysroot(allocator, template, arch, null);
}

pub fn toDebianArch(arch: []const u8) []const u8 {
    if (mem.eql(u8, arch, "arm")) return "armhf";
    return deb.sysroot.triplet.normalizeDebianArch(arch);
}

pub fn getMultiarchTriplet(arch: []const u8) []const u8 {
    return deb.sysroot.triplet.archToTriplet(toDebianArch(arch));
}

pub fn getSysrootPath(allocator: mem.Allocator, pkg: PackageDefinition) ![]u8 {
    const deb_arch = toDebianArch(pkg.architecture);
    if (pkg.sysroot_dir) |dir| {
        return resolvePathVars(allocator, dir, pkg.architecture);
    }
    return try std.fmt.allocPrint(allocator, "sysroot/{s}", .{deb_arch});
}

pub fn fetchBuildDepends(io: Io, gpa: mem.Allocator, pkg: PackageDefinition) ![]u8 {
    const sysroot_target = try getSysrootPath(gpa, pkg);
    errdefer gpa.free(sysroot_target);

    if (pkg.build_depends.len == 0) {
        return sysroot_target;
    }

    try std.Io.Dir.cwd().createDirPath(io, sysroot_target);

    const deb_arch = toDebianArch(pkg.architecture);
    try deb.sysroot.buildSysroot(gpa, io, .{
        .suite = pkg.suite orelse "bookworm",
        .target = sysroot_target,
        .mirror = pkg.mirror orelse "http://deb.debian.org/debian",
        .arch = deb_arch,
        .packages = pkg.build_depends,
        .cache_dir = pkg.sysroot_cache_dir,
        .no_fixup = pkg.no_sysroot_fixup,
    });

    return sysroot_target;
}

pub fn isExcluded(path: []const u8, files: []const []const u8, exts: []const []const u8) bool {
    for (files) |f| {
        if (mem.indexOf(u8, path, f) != null) return true;
    }
    for (exts) |ext| {
        if (mem.endsWith(u8, path, ext)) return true;
    }
    return false;
}

pub fn parseOctalMode(mode_str: []const u8) !u32 {
    var str = mode_str;
    if (mem.startsWith(u8, str, "0o") or mem.startsWith(u8, str, "0O")) {
        str = str[2..];
    }
    return try std.fmt.parseInt(u32, str, 8);
}

pub const ScriptKind = enum { preinst, postinst, prerm, postrm };

pub fn attachScript(io: Io, b: *deb.Builder, inline_script: ?[]const u8, file_path: ?[]const u8, kind: ScriptKind) !void {
    var content: ?[]const u8 = inline_script;
    if (file_path) |p| {
        if (Io.Dir.cwd().readFileAlloc(io, p, b.arena.allocator(), .unlimited)) |fc| {
            content = fc;
        } else |_| {}
    }
    if (content) |c| {
        switch (kind) {
            .preinst => try b.setPreinst(c),
            .postinst => try b.setPostinst(c),
            .prerm => try b.setPrerm(c),
            .postrm => try b.setPostrm(c),
        }
    }
}

fn matchWildcard(pattern: []const u8, str: []const u8) bool {
    if (mem.eql(u8, pattern, "*")) return true;
    if (mem.startsWith(u8, pattern, "*") and mem.endsWith(u8, pattern, "*") and pattern.len > 2) {
        return mem.indexOf(u8, str, pattern[1 .. pattern.len - 1]) != null;
    }
    if (mem.startsWith(u8, pattern, "*")) {
        return mem.endsWith(u8, str, pattern[1..]);
    }
    if (mem.endsWith(u8, pattern, "*")) {
        return mem.startsWith(u8, str, pattern[0 .. pattern.len - 1]);
    }
    return mem.eql(u8, pattern, str);
}

pub fn expandPathGlobs(io: Io, allocator: mem.Allocator, pattern: []const u8) ![][]const u8 {
    if (mem.indexOfScalar(u8, pattern, '*') == null) {
        const single = try allocator.alloc([]const u8, 1);
        single[0] = pattern;
        return single;
    }

    var current_candidates: std.ArrayListUnmanaged([]const u8) = .empty;
    try current_candidates.append(allocator, "");

    var it = mem.splitScalar(u8, pattern, '/');
    while (it.next()) |component| {
        if (component.len == 0) continue;

        var next_candidates: std.ArrayListUnmanaged([]const u8) = .empty;
        for (current_candidates.items) |cand| {
            if (mem.indexOfScalar(u8, component, '*') != null) {
                var dir = if (cand.len == 0)
                    Io.Dir.cwd().openDir(io, ".", .{ .iterate = true }) catch continue
                else
                    Io.Dir.cwd().openDir(io, cand, .{ .iterate = true }) catch continue;
                defer dir.close(io);

                var dir_it = dir.iterate();
                while (dir_it.next(io) catch null) |entry| {
                    if (matchWildcard(component, entry.name)) {
                        const next_path = if (cand.len == 0)
                            try allocator.dupe(u8, entry.name)
                        else
                            try std.fs.path.join(allocator, &.{ cand, entry.name });
                        try next_candidates.append(allocator, next_path);
                    }
                }
            } else {
                const next_path = if (cand.len == 0)
                    try allocator.dupe(u8, component)
                else
                    try std.fs.path.join(allocator, &.{ cand, component });
                try next_candidates.append(allocator, next_path);
            }
        }
        current_candidates = next_candidates;
    }

    return current_candidates.toOwnedSlice(allocator);
}

pub fn packageGeneric(io: Io, gpa: mem.Allocator, pkg: PackageDefinition) ![]u8 {
    var b = deb.Builder.init(gpa);
    defer b.deinit();

    const deb_arch = toDebianArch(pkg.architecture);

    // 0. Fetch build dependencies into sysroot if specified
    var sysroot_path: ?[]const u8 = null;
    if (pkg.fetch_sysroot and pkg.build_depends.len > 0) {
        sysroot_path = try fetchBuildDepends(io, gpa, pkg);
    } else if (pkg.sysroot_dir) |sd| {
        sysroot_path = try resolvePathVars(gpa, sd, pkg.architecture);
    }
    defer if (sysroot_path) |sp| gpa.free(sp);

    // 1. Set Control Metadata
    var ctrl = deb.Builder.ControlInfo{
        .package = pkg.name,
        .version = pkg.version,
        .architecture = deb_arch,
        .maintainer = pkg.maintainer,
        .description = pkg.description,
        .section = pkg.section,
        .priority = pkg.priority,
        .essential = pkg.essential,
        .homepage = pkg.homepage,
        .depends = try formatDependencyList(b.arena.allocator(), pkg.depends),
        .build_depends = try formatDependencyList(b.arena.allocator(), pkg.build_depends),
        .pre_depends = try formatDependencyList(b.arena.allocator(), pkg.pre_depends),
        .recommends = try formatDependencyList(b.arena.allocator(), pkg.recommends),
        .suggests = try formatDependencyList(b.arena.allocator(), pkg.suggests),
        .enhances = try formatDependencyList(b.arena.allocator(), pkg.enhances),
        .conflicts = try formatDependencyList(b.arena.allocator(), pkg.conflicts),
        .breaks = try formatDependencyList(b.arena.allocator(), pkg.breaks),
        .provides = try formatDependencyList(b.arena.allocator(), pkg.provides),
        .replaces = try formatDependencyList(b.arena.allocator(), pkg.replaces),
    };
    for (pkg.extra_fields) |field| {
        try ctrl.extra_fields.append(b.arena.allocator(), .{
            .name = field.name,
            .value = field.value,
        });
    }
    b.setControl(ctrl);

    // 2. Attach Maintainer Lifecycle Scripts
    try attachScript(io, &b, pkg.preinst_script, pkg.preinst_file, .preinst);
    try attachScript(io, &b, pkg.postinst_script, pkg.postinst_file, .postinst);
    try attachScript(io, &b, pkg.prerm_script, pkg.prerm_file, .prerm);
    try attachScript(io, &b, pkg.postrm_script, pkg.postrm_file, .postrm);

    const FileItem = struct {
        content: []const u8,
        mode: u32,
    };
    var file_map: std.StringArrayHashMapUnmanaged(FileItem) = .empty;

    // 3. Process File Mappings
    for (pkg.file_mappings) |mapping| {
        const resolved_src_pattern = try resolvePathVarsWithSysroot(b.arena.allocator(), mapping.src, pkg.architecture, sysroot_path);
        const resolved_dest = try resolvePathVarsWithSysroot(b.arena.allocator(), mapping.dest, pkg.architecture, sysroot_path);

        const expanded_srcs = try expandPathGlobs(io, b.arena.allocator(), resolved_src_pattern);

        for (expanded_srcs) |resolved_src| {
            // Check if single file or directory walk
            var src_dir = Io.Dir.cwd().openDir(io, resolved_src, .{ .iterate = true }) catch {
                // If opening as dir fails, treat as a single file
                if (Io.Dir.cwd().readFileAlloc(io, resolved_src, b.arena.allocator(), .unlimited)) |content| {
                    var target_path: []const u8 = resolved_dest;
                    if (target_path.len == 0) {
                        target_path = std.fs.path.basename(resolved_src);
                    } else if (mem.endsWith(u8, target_path, "/")) {
                        target_path = try std.fs.path.join(b.arena.allocator(), &.{ target_path, std.fs.path.basename(resolved_src) });
                    }

                    var mode: u32 = mapping.mode orelse 0o644;
                    if (mapping.mode == null) {
                        for (mapping.executable_patterns) |pat| {
                            if (mem.indexOf(u8, target_path, pat) != null or mem.indexOf(u8, resolved_src, pat) != null) {
                                mode = 0o755;
                                break;
                            }
                        }
                    }

                    try file_map.put(b.arena.allocator(), target_path, .{ .content = content, .mode = mode });
                } else |_| {}
                continue;
            };
            defer src_dir.close(io);

            var walker = try src_dir.walk(b.arena.allocator());
            defer walker.deinit();

            while (try walker.next(io)) |entry| {
                if (entry.kind != .file) continue;

                // Apply Exclusions
                if (isExcluded(entry.path, mapping.exclude_files, mapping.exclude_extensions)) continue;

                const content = try src_dir.readFileAlloc(io, entry.path, b.arena.allocator(), .unlimited);
                const target_path = if (resolved_dest.len == 0)
                    entry.path
                else
                    try std.fs.path.join(b.arena.allocator(), &.{ resolved_dest, entry.path });

                // Determine File Mode
                var mode: u32 = mapping.mode orelse 0o644;
                if (mapping.mode == null) {
                    for (mapping.executable_patterns) |pat| {
                        if (mem.indexOf(u8, target_path, pat) != null or mem.indexOf(u8, entry.path, pat) != null) {
                            mode = 0o755;
                            break;
                        }
                    }
                }

                try file_map.put(b.arena.allocator(), target_path, .{ .content = content, .mode = mode });
            }
        }
    }

    // Register all files into deb builder
    for (file_map.keys(), file_map.values()) |target_path, item| {
        try b.addFile(target_path, item.content, item.mode);
    }

    // 4. Register Symlinks
    var link_map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    for (pkg.symlinks) |sym| {
        const link = try resolvePathVarsWithSysroot(b.arena.allocator(), sym.link, pkg.architecture, sysroot_path);
        const target = try resolvePathVarsWithSysroot(b.arena.allocator(), sym.target, pkg.architecture, sysroot_path);
        try link_map.put(b.arena.allocator(), link, target);
    }
    for (link_map.keys(), link_map.values()) |link, target| {
        try b.addSymlink(link, target);
    }

    // 5. Compute Final Output Destination & Write Package
    const out_path = if (pkg.out_deb_path) |p|
        try gpa.dupe(u8, p)
    else
        try std.fmt.allocPrint(gpa, "{s}/{s}_{s}_{s}.deb", .{
            pkg.out_dir,
            pkg.name,
            pkg.version,
            deb_arch,
        });
    errdefer gpa.free(out_path);

    if (std.fs.path.dirname(out_path)) |parent| {
        if (parent.len > 0) try Io.Dir.cwd().createDirPath(io, parent);
    }

    try b.writeFile(io, gpa, out_path, .{
        .auto_installed_size = true,
        .auto_md5sums = true,
        .validate = true,
    });

    // 6. Install to sysroot if requested
    if (pkg.install_to_sysroot) {
        const dest_sysroot = if (sysroot_path) |sp|
            sp
        else
            try getSysrootPath(gpa, pkg);
        defer if (sysroot_path == null) gpa.free(dest_sysroot);

        log.info("Installing '{s}' into sysroot '{s}'...", .{ pkg.name, dest_sysroot });
        try std.Io.Dir.cwd().createDirPath(io, dest_sysroot);
        try deb.sysroot.unpackDeb(gpa, io, dest_sysroot, out_path, .{ .fixup = true });
        log.info("Installed: {s} -> {s}", .{ pkg.name, dest_sysroot });
    }

    return out_path;
}

pub fn installDebToSysroot(io: Io, gpa: mem.Allocator, target_sysroot: []const u8, deb_path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, target_sysroot);
    try deb.sysroot.unpackDeb(gpa, io, target_sysroot, deb_path, .{ .fixup = true });
}

pub fn installPackageToSysroot(
    io: Io,
    gpa: mem.Allocator,
    pkg: PackageDefinition,
    deb_path: []const u8,
    custom_sysroot: ?[]const u8,
) !void {
    const target_sysroot = if (custom_sysroot) |cs|
        try gpa.dupe(u8, cs)
    else
        try getSysrootPath(gpa, pkg);
    defer gpa.free(target_sysroot);

    try installDebToSysroot(io, gpa, target_sysroot, deb_path);
}

pub fn packageByName(
    io: Io,
    gpa: mem.Allocator,
    manifest: Manifest,
    pkg_name: []const u8,
    target_arch: ?[]const u8,
    target_suite: ?[]const u8,
    target_mirror: ?[]const u8,
    install_to_sysroot: bool,
    custom_sysroot: ?[]const u8,
    custom_out_dir: ?[]const u8,
) ![][]const u8 {
    const pkg = manifest.findPackage(pkg_name) orelse {
        log.err("Package '{s}' not found in manifest", .{pkg_name});
        return error.PackageNotFound;
    };

    const archs = if (target_arch) |ta|
        &[_][]const u8{ta}
    else
        pkg.getArchitectures();

    var built_debs: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (built_debs.items) |d| gpa.free(d);
        built_debs.deinit(gpa);
    }

    for (archs) |arch| {
        var mut_pkg = pkg;
        mut_pkg.architecture = arch;
        if (target_suite orelse pkg.suite orelse manifest.suite) |s| {
            mut_pkg.suite = s;
        }
        if (target_mirror orelse pkg.mirror orelse manifest.mirror) |m| {
            mut_pkg.mirror = m;
        }
        if (install_to_sysroot) {
            mut_pkg.install_to_sysroot = true;
        }
        if (custom_sysroot) |cs| {
            mut_pkg.sysroot_dir = cs;
        }
        if (custom_out_dir) |od| {
            mut_pkg.out_dir = od;
        }

        log.info("Building package '{s}' ({s}, suite: {s})...", .{
            mut_pkg.name,
            mut_pkg.architecture,
            mut_pkg.suite orelse "bookworm",
        });
        const out_path = try packageGeneric(io, gpa, mut_pkg);
        try built_debs.append(gpa, out_path);
        log.info("Done: {s} -> {s}", .{ mut_pkg.name, out_path });
    }

    return built_debs.toOwnedSlice(gpa);
}

pub fn parseManifestSlice(allocator: mem.Allocator, data: []const u8) !Manifest {
    @setEvalBranchQuota(100_000);
    const data_z = try allocator.dupeZ(u8, data);
    defer allocator.free(data_z);
    return try std.zon.parse.fromSliceAlloc(Manifest, allocator, data_z, null, .{
        .ignore_unknown_fields = true,
    });
}

pub fn parseManifestFile(io: Io, allocator: mem.Allocator, manifest_path: []const u8) !Manifest {
    const data = try Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .unlimited);
    defer allocator.free(data);
    return parseManifestSlice(allocator, data);
}

pub fn packageManifestWithOptions(
    io: Io,
    gpa: mem.Allocator,
    manifest: Manifest,
    target_arch: ?[]const u8,
    target_suite: ?[]const u8,
    target_mirror: ?[]const u8,
    install_all_to_sysroot: bool,
    custom_sysroot: ?[]const u8,
    custom_out_dir: ?[]const u8,
) !void {
    for (manifest.packages) |pkg| {
        const archs = if (target_arch) |ta|
            &[_][]const u8{ta}
        else
            pkg.getArchitectures();

        for (archs) |arch| {
            var mut_pkg = pkg;
            mut_pkg.architecture = arch;
            if (target_suite orelse pkg.suite orelse manifest.suite) |s| {
                mut_pkg.suite = s;
            }
            if (target_mirror orelse pkg.mirror orelse manifest.mirror) |m| {
                mut_pkg.mirror = m;
            }
            if (install_all_to_sysroot) {
                mut_pkg.install_to_sysroot = true;
            }
            if (custom_sysroot) |cs| {
                mut_pkg.sysroot_dir = cs;
            }
            if (custom_out_dir) |od| {
                mut_pkg.out_dir = od;
            }
            log.info("Building package '{s}' ({s}, suite: {s})...", .{
                mut_pkg.name,
                mut_pkg.architecture,
                mut_pkg.suite orelse "bookworm",
            });
            const out_path = try packageGeneric(io, gpa, mut_pkg);
            defer gpa.free(out_path);
            log.info("Done: {s} -> {s}", .{ mut_pkg.name, out_path });
        }
    }
}

pub fn packageManifest(io: Io, gpa: mem.Allocator, manifest: Manifest) !void {
    try packageManifestWithOptions(io, gpa, manifest, null, null, null, false, null, null);
}

pub fn packageManifestFile(io: Io, gpa: mem.Allocator, manifest_path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const manifest = try parseManifestFile(io, arena.allocator(), manifest_path);
    try packageManifest(io, gpa, manifest);
}

pub fn fetchManifestBuildDepends(
    io: Io,
    gpa: mem.Allocator,
    manifest: Manifest,
    target_pkg_name: ?[]const u8,
    target_arch: ?[]const u8,
    target_suite: ?[]const u8,
    target_mirror: ?[]const u8,
    custom_sysroot: ?[]const u8,
) !void {
    var matched = false;
    for (manifest.packages) |pkg| {
        if (target_pkg_name) |tp| {
            if (!std.mem.eql(u8, pkg.name, tp)) continue;
        }
        matched = true;
        if (pkg.build_depends.len > 0) {
            const archs = if (target_arch) |ta|
                &[_][]const u8{ta}
            else
                pkg.getArchitectures();

            for (archs) |arch| {
                var arch_pkg = pkg;
                arch_pkg.architecture = arch;
                if (target_suite orelse pkg.suite orelse manifest.suite) |s| {
                    arch_pkg.suite = s;
                }
                if (target_mirror orelse pkg.mirror orelse manifest.mirror) |m| {
                    arch_pkg.mirror = m;
                }
                if (custom_sysroot) |cs| {
                    arch_pkg.sysroot_dir = cs;
                }
                log.info("Fetching build dependencies for '{s}' ({s}, suite: {s})...", .{
                    arch_pkg.name,
                    arch_pkg.architecture,
                    arch_pkg.suite orelse "bookworm",
                });
                const sysroot = try fetchBuildDepends(io, gpa, arch_pkg);
                defer gpa.free(sysroot);
                log.info("Sysroot ready at '{s}'", .{sysroot});
            }
        }
    }
    if (target_pkg_name != null and !matched) {
        log.err("Package '{s}' not found in manifest", .{target_pkg_name.?});
        return error.PackageNotFound;
    }
}

test "resolvePathVars expands {triplet} and {arch}" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const res_amd64 = try resolvePathVars(allocator, "usr/lib/{triplet}/test_{arch}.so", "amd64");
    defer allocator.free(res_amd64);
    try testing.expectEqualStrings("usr/lib/x86_64-linux-gnu/test_amd64.so", res_amd64);

    const res_arm64 = try resolvePathVars(allocator, "usr/lib/{triplet}/test_{arch}.so", "arm64");
    defer allocator.free(res_arm64);
    try testing.expectEqualStrings("usr/lib/aarch64-linux-gnu/test_arm64.so", res_arm64);

    const res_armhf = try resolvePathVars(allocator, "usr/lib/{triplet}/test_{arch}.so", "armhf");
    defer allocator.free(res_armhf);
    try testing.expectEqualStrings("usr/lib/arm-linux-gnueabihf/test_armhf.so", res_armhf);

    const res_riscv = try resolvePathVars(allocator, "usr/lib/{triplet}/test_{arch}.so", "riscv64");
    defer allocator.free(res_riscv);
    try testing.expectEqualStrings("usr/lib/riscv64-linux-gnu/test_riscv64.so", res_riscv);

    const res_i386 = try resolvePathVars(allocator, "usr/lib/{triplet}/test_{arch}.so", "i386");
    defer allocator.free(res_i386);
    try testing.expectEqualStrings("usr/lib/i386-linux-gnu/test_i386.so", res_i386);
}

test "resolvePathVarsWithSysroot expands {sysroot}, {triplet}, and {arch}" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const res = try resolvePathVarsWithSysroot(
        allocator,
        "{sysroot}/usr/lib/{triplet}/libtest_{arch}.so",
        "arm64",
        "/opt/sysroot/arm64",
    );
    defer allocator.free(res);
    try testing.expectEqualStrings("/opt/sysroot/arm64/usr/lib/aarch64-linux-gnu/libtest_arm64.so", res);
}

test "formatDependencyList formatting" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const empty: []const []const u8 = &.{};
    try testing.expectEqual(@as(?[]const u8, null), try formatDependencyList(allocator, empty));

    const single = [_][]const u8{"libc6 (>= 2.34)"};
    const single_formatted = try formatDependencyList(allocator, &single);
    defer allocator.free(single_formatted.?);
    try testing.expectEqualStrings("libc6 (>= 2.34)", single_formatted.?);

    const multiple = [_][]const u8{ "libc6 (>= 2.34)", "libssl3", "zlib1g (>= 1.2.11)" };
    const mult_formatted = try formatDependencyList(allocator, &multiple);
    defer allocator.free(mult_formatted.?);
    try testing.expectEqualStrings("libc6 (>= 2.34), libssl3, zlib1g (>= 1.2.11)", mult_formatted.?);
}

test "toDebianArch and getMultiarchTriplet normalization" {
    const testing = std.testing;

    try testing.expectEqualStrings("amd64", toDebianArch("x86_64"));
    try testing.expectEqualStrings("amd64", toDebianArch("amd64"));
    try testing.expectEqualStrings("arm64", toDebianArch("aarch64"));
    try testing.expectEqualStrings("arm64", toDebianArch("arm64"));
    try testing.expectEqualStrings("armhf", toDebianArch("armhf"));
    try testing.expectEqualStrings("armhf", toDebianArch("arm"));
    try testing.expectEqualStrings("riscv64", toDebianArch("riscv64"));
    try testing.expectEqualStrings("i386", toDebianArch("i386"));
    try testing.expectEqualStrings("i386", toDebianArch("x86"));
    try testing.expectEqualStrings("all", toDebianArch("all"));

    try testing.expectEqualStrings("x86_64-linux-gnu", getMultiarchTriplet("amd64"));
    try testing.expectEqualStrings("aarch64-linux-gnu", getMultiarchTriplet("arm64"));
    try testing.expectEqualStrings("arm-linux-gnueabihf", getMultiarchTriplet("armhf"));
    try testing.expectEqualStrings("riscv64-linux-gnu", getMultiarchTriplet("riscv64"));
    try testing.expectEqualStrings("i386-linux-gnu", getMultiarchTriplet("i386"));
}

test "getSysrootPath resolution" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const default_pkg = PackageDefinition{
        .name = "demo",
        .architecture = "arm64",
    };
    const default_path = try getSysrootPath(allocator, default_pkg);
    defer allocator.free(default_path);
    try testing.expectEqualStrings("sysroot/arm64", default_path);

    const custom_pkg = PackageDefinition{
        .name = "demo",
        .architecture = "arm64",
        .sysroot_dir = "build/sysroots/{triplet}",
    };
    const custom_path = try getSysrootPath(allocator, custom_pkg);
    defer allocator.free(custom_path);
    try testing.expectEqualStrings("build/sysroots/aarch64-linux-gnu", custom_path);
}

test "isExcluded checks filenames and extensions" {
    const testing = std.testing;

    const files = [_][]const u8{ "README.md", ".git", "etc/inittab" };
    const exts = [_][]const u8{ ".am", ".in" };

    try testing.expect(isExcluded("README.md", &files, &exts));
    try testing.expect(isExcluded("sub/README.md", &files, &exts));
    try testing.expect(isExcluded(".git/HEAD", &files, &exts));
    try testing.expect(isExcluded("etc/inittab", &files, &exts));
    try testing.expect(isExcluded("Makefile.am", &files, &exts));
    try testing.expect(isExcluded("config.in", &files, &exts));

    try testing.expect(!isExcluded("dictionary", &files, &exts));
    try testing.expect(!isExcluded("usr/bin/app", &files, &exts));
}

test "parseOctalMode parses octal mode strings" {
    const testing = std.testing;

    try testing.expectEqual(@as(u32, 0o755), try parseOctalMode("0755"));
    try testing.expectEqual(@as(u32, 0o755), try parseOctalMode("755"));
    try testing.expectEqual(@as(u32, 0o755), try parseOctalMode("0o755"));
    try testing.expectEqual(@as(u32, 0o644), try parseOctalMode("0644"));
    try testing.expectEqual(@as(u32, 0o644), try parseOctalMode("644"));
}

test "ZON manifest parsing with slice depends and build_depends" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const zon_data =
        \\.{
        \\    .packages = .{
        \\        .{
        \\            .name = "test-zon-pkg",
        \\            .version = "3.1.0",
        \\            .architecture = "amd64",
        \\            .section = "libs",
        \\            .priority = "optional",
        \\            .maintainer = "ZON Maintainer <zon@example.com>",
        \\            .description =
        \\                \\Multiline ZON Description
        \\                \\ Second line of description
        \\            ,
        \\            .depends = .{
        \\                "libc6 (>= 2.34)",
        \\                "libssl3 (>= 3.0.0)",
        \\            },
        \\            .build_depends = .{
        \\                "libssl-dev",
        \\                "zlib1g-dev",
        \\            },
        \\            .extra_fields = .{
        \\                .{ .name = "Multi-Arch", .value = "same" },
        \\            },
        \\            .preinst_script =
        \\                \\#!/bin/sh
        \\                \\echo "ZON preinst"
        \\                \\exit 0
        \\            ,
        \\            .postinst_script =
        \\                \\#!/bin/sh
        \\                \\echo "ZON postinst"
        \\                \\exit 0
        \\            ,
        \\            .file_mappings = .{
        \\                .{
        \\                    .src = "src/main.zig",
        \\                    .dest = "usr/share/zon/main.zig",
        \\                    .mode = 0o755,
        \\                },
        \\            },
        \\            .symlinks = .{
        \\                .{ .link = "usr/bin/zon-link", .target = "usr/share/zon/main.zig" },
        \\            },
        \\        },
        \\    },
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const manifest = try parseManifestSlice(arena.allocator(), zon_data);

    try testing.expectEqual(@as(usize, 1), manifest.packages.len);
    const pkg = manifest.packages[0];
    try testing.expectEqualStrings("test-zon-pkg", pkg.name);
    try testing.expectEqualStrings("3.1.0", pkg.version);
    try testing.expectEqualStrings("amd64", pkg.architecture);
    try testing.expectEqualStrings("libs", pkg.section);
    try testing.expectEqual(@as(usize, 2), pkg.depends.len);
    try testing.expectEqualStrings("libc6 (>= 2.34)", pkg.depends[0]);
    try testing.expectEqualStrings("libssl3 (>= 3.0.0)", pkg.depends[1]);
    try testing.expectEqual(@as(usize, 2), pkg.build_depends.len);
    try testing.expectEqualStrings("libssl-dev", pkg.build_depends[0]);
    try testing.expectEqualStrings("zlib1g-dev", pkg.build_depends[1]);
    try testing.expectEqual(@as(usize, 1), pkg.extra_fields.len);
    try testing.expectEqualStrings("Multi-Arch", pkg.extra_fields[0].name);
    try testing.expectEqualStrings("same", pkg.extra_fields[0].value);
    try testing.expect(pkg.preinst_script != null);
    try testing.expect(pkg.postinst_script != null);
    try testing.expectEqual(@as(usize, 1), pkg.file_mappings.len);
    try testing.expectEqualStrings("src/main.zig", pkg.file_mappings[0].src);
    try testing.expectEqualStrings("usr/share/zon/main.zig", pkg.file_mappings[0].dest);
    try testing.expectEqual(@as(u32, 0o755), pkg.file_mappings[0].mode.?);
    try testing.expectEqual(@as(usize, 1), pkg.symlinks.len);
    try testing.expectEqualStrings("usr/bin/zon-link", pkg.symlinks[0].link);
    try testing.expectEqualStrings("usr/share/zon/main.zig", pkg.symlinks[0].target);
}

test "packageGeneric builds deb with formatted depends and build_depends" {
    const testing = std.testing;
    const test_io = testing.io;
    const test_gpa = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(test_gpa);
    defer arena.deinit();

    const test_deb_path = "packages/test_sample_1.0.0_amd64.deb";
    defer Io.Dir.cwd().deleteFile(test_io, test_deb_path) catch {};

    const pkg = PackageDefinition{
        .name = "test-sample",
        .version = "1.0.0",
        .architecture = "amd64",
        .maintainer = "Test <test@example.com>",
        .description = "Test package with slice dependencies",
        .depends = &.{ "libc6 (>= 2.34)", "libssl3" },
        .build_depends = &.{ "libssl-dev", "zlib1g-dev" },
        .out_deb_path = test_deb_path,
        .file_mappings = &.{
            .{
                .src = "src/main.zig",
                .dest = "usr/share/sample/main.zig",
                .mode = 0o644,
            },
        },
    };

    const out_deb = try packageGeneric(test_io, test_gpa, pkg);
    defer test_gpa.free(out_deb);

    const stat = try Io.Dir.cwd().statFile(test_io, test_deb_path, .{});
    try testing.expect(stat.size > 0);

    // Inspect the generated deb control
    if (try deb.sysroot.package.readDebControl(arena.allocator(), test_io, test_deb_path)) |ctrl| {
        try testing.expectEqualStrings("test-sample", ctrl.name);
        try testing.expectEqualStrings("1.0.0", ctrl.raw_version);
        try testing.expectEqualStrings("amd64", ctrl.architecture);
        try testing.expectEqual(@as(usize, 2), ctrl.depends.items.len);
        try testing.expectEqualStrings("libc6", ctrl.depends.items[0].alts.items[0].package_name);
        try testing.expectEqualStrings("2.34", ctrl.depends.items[0].alts.items[0].version);
        try testing.expectEqualStrings("libssl3", ctrl.depends.items[1].alts.items[0].package_name);
    } else {
        return error.FailedToReadDebControl;
    }
}

test "Manifest.findPackage and packageByName" {
    const testing = std.testing;
    const test_io = testing.io;
    const test_gpa = testing.allocator;

    const manifest = Manifest{
        .packages = &.{
            .{
                .name = "pkg-alpha",
                .version = "1.0.0",
                .architecture = "amd64",
            },
            .{
                .name = "pkg-beta",
                .version = "2.0.0",
                .architecture = "arm64",
                .out_deb_path = "packages/test_pkg_beta.deb",
                .file_mappings = &.{
                    .{
                        .src = "src/main.zig",
                        .dest = "usr/share/beta/main.zig",
                    },
                },
            },
        },
    };

    try testing.expect(manifest.findPackage("pkg-alpha") != null);
    try testing.expect(manifest.findPackage("pkg-beta") != null);
    try testing.expect(manifest.findPackage("non-existent") == null);

    defer Io.Dir.cwd().deleteFile(test_io, "packages/test_pkg_beta.deb") catch {};
    const out_debs = try packageByName(test_io, test_gpa, manifest, "pkg-beta", null, null, null, false, null, null);
    defer {
        for (out_debs) |d| test_gpa.free(d);
        test_gpa.free(out_debs);
    }

    try testing.expectEqual(@as(usize, 1), out_debs.len);
    try testing.expectEqualStrings("packages/test_pkg_beta.deb", out_debs[0]);
    const stat = try Io.Dir.cwd().statFile(test_io, out_debs[0], .{});
    try testing.expect(stat.size > 0);
}

test "PackageDefinition with multiple architectures builds debs for all architectures" {
    const testing = std.testing;
    const test_io = testing.io;
    const test_gpa = testing.allocator;

    const deb_amd64 = "packages/test-multiarch_1.0.0_amd64.deb";
    const deb_arm64 = "packages/test-multiarch_1.0.0_arm64.deb";
    defer {
        Io.Dir.cwd().deleteFile(test_io, deb_amd64) catch {};
        Io.Dir.cwd().deleteFile(test_io, deb_arm64) catch {};
    }

    const manifest = Manifest{
        .packages = &.{
            .{
                .name = "test-multiarch",
                .version = "1.0.0",
                .architectures = &.{ "amd64", "arm64" },
                .file_mappings = &.{
                    .{
                        .src = "src/main.zig",
                        .dest = "usr/share/multiarch/{arch}/main.zig",
                    },
                },
            },
        },
    };

    // 1. Build all architectures
    const out_all = try packageByName(test_io, test_gpa, manifest, "test-multiarch", null, null, null, false, null, null);
    defer {
        for (out_all) |d| test_gpa.free(d);
        test_gpa.free(out_all);
    }
    try testing.expectEqual(@as(usize, 2), out_all.len);
    try testing.expectEqualStrings(deb_amd64, out_all[0]);
    try testing.expectEqualStrings(deb_arm64, out_all[1]);

    const stat_amd64 = try Io.Dir.cwd().statFile(test_io, deb_amd64, .{});
    try testing.expect(stat_amd64.size > 0);
    const stat_arm64 = try Io.Dir.cwd().statFile(test_io, deb_arm64, .{});
    try testing.expect(stat_arm64.size > 0);

    // 2. Build single architecture with target_arch filter
    const out_arm64_only = try packageByName(test_io, test_gpa, manifest, "test-multiarch", "arm64", null, null, false, null, null);
    defer {
        for (out_arm64_only) |d| test_gpa.free(d);
        test_gpa.free(out_arm64_only);
    }
    try testing.expectEqual(@as(usize, 1), out_arm64_only.len);
    try testing.expectEqualStrings(deb_arm64, out_arm64_only[0]);
}

test "packageGeneric with install_to_sysroot unpacks into target sysroot" {
    const testing = std.testing;
    const test_io = testing.io;
    const test_gpa = testing.allocator;

    const test_sysroot = "test-target-sysroot";
    const test_deb = "packages/test_install_sample_1.0.0_amd64.deb";
    defer {
        Io.Dir.cwd().deleteFile(test_io, test_deb) catch {};
        Io.Dir.cwd().deleteTree(test_io, test_sysroot) catch {};
    }

    const pkg = PackageDefinition{
        .name = "test-install-sample",
        .version = "1.0.0",
        .architecture = "amd64",
        .out_deb_path = test_deb,
        .install_to_sysroot = true,
        .sysroot_dir = test_sysroot,
        .file_mappings = &.{
            .{
                .src = "src/main.zig",
                .dest = "usr/share/install_test/main.zig",
                .mode = 0o644,
            },
        },
    };

    const out_deb = try packageGeneric(test_io, test_gpa, pkg);
    defer test_gpa.free(out_deb);

    // Verify deb exists
    const stat = try Io.Dir.cwd().statFile(test_io, test_deb, .{});
    try testing.expect(stat.size > 0);

    // Verify unpacked payload in test sysroot
    const extracted_stat = try Io.Dir.cwd().statFile(test_io, test_sysroot ++ "/usr/share/install_test/main.zig", .{});
    try testing.expect(extracted_stat.size > 0);
}

test "Manifest and PackageDefinition suite and mirror configuration" {
    const testing = std.testing;

    const manifest = Manifest{
        .suite = "trixie",
        .mirror = "https://custom.debian.org",
        .packages = &.{
            .{
                .name = "pkg-inherit",
            },
            .{
                .name = "pkg-override",
                .suite = "sid",
                .mirror = "https://sid.debian.org",
            },
        },
    };

    const pkg_inherit = manifest.packages[0];
    try testing.expectEqualStrings("trixie", pkg_inherit.suite orelse (manifest.suite orelse "bookworm"));
    try testing.expectEqualStrings("https://custom.debian.org", pkg_inherit.mirror orelse (manifest.mirror orelse "http://deb.debian.org/debian"));

    const pkg_override = manifest.packages[1];
    try testing.expectEqualStrings("sid", pkg_override.suite orelse (manifest.suite orelse "bookworm"));
    try testing.expectEqualStrings("https://sid.debian.org", pkg_override.mirror orelse (manifest.mirror orelse "http://deb.debian.org/debian"));
}
