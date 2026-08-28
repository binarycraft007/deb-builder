# deb-builder

A declarative Debian package (`.deb`) builder and sysroot manager for Zig projects.

`deb-builder` lets you define your packages in a simple `packages.zon` manifest, automatically downloads Debian/Ubuntu dependencies into a sysroot for cross-compilation, and packages everything into standard `.deb` binaries without needing `dpkg`, `fakeroot`, or Debian packaging scripts.

---

## Features

- **Pure ZON Manifests** – Configure packages, metadata, dependencies, file mappings, permissions, and scripts in standard Zig syntax.
- **Multi-Architecture Support** – Target multiple architectures (`amd64`, `arm64`, etc.) from a single manifest using `{arch}` and `{triplet}` placeholders.
- **Automatic Sysroot Builder** – Fetches and unpacks `build_depends` (e.g. `zlib1g-dev`, `libc6-dev`) directly from Debian/Ubuntu mirrors with automatic symlink and linker script fixups.
- **Cross-Package Pipelines** – Build a library package, unpack it into the build sysroot with `--install`, and link downstream applications against it.
- **Zero External Dependencies** – Generates valid `ar`, `control.tar.gz`, and `data.tar.gz` archives natively in Zig.

---

## Quickstart

### 1. Define your packages (`packages.zon`)

```zig
.{
    .suite = "bookworm", // Debian suite: bookworm, trixie, sid, or noble (Ubuntu)
    .mirror = "http://deb.debian.org/debian",
    .packages = .{
        .{
            .name = "libmath-helper",
            .version = "1.0.0",
            .architectures = .{ "amd64", "arm64" },
            .maintainer = "Your Name <you@example.com>",
            .description = "Sample shared library",
            .section = "libs",
            .priority = "optional",
            .build_depends = .{
                "zlib1g-dev",
            },
            .fetch_sysroot = true,
            .sysroot_dir = "sysroot/{arch}",
            .depends = .{
                "libc6 (>= 2.34)",
                "zlib1g (>= 1:1.2.13)",
            },
            .file_mappings = .{
                .{
                    .src = "build-out/{arch}/lib/libmathhelper.so",
                    .dest = "usr/lib/{triplet}/libmathhelper.so.1.0.0",
                    .mode = 0o644,
                },
                .{
                    .src = "include/math_helper.h",
                    .dest = "usr/include/math_helper.h",
                    .mode = 0o644,
                },
            },
            .symlinks = .{
                .{
                    .link = "usr/lib/{triplet}/libmathhelper.so.1",
                    .target = "libmathhelper.so.1.0.0",
                },
                .{
                    .link = "usr/lib/{triplet}/libmathhelper.so",
                    .target = "libmathhelper.so.1",
                },
            },
        },
        .{
            .name = "math-app",
            .version = "1.0.0",
            .architectures = .{ "amd64", "arm64" },
            .description = "CLI tool using libmath-helper",
            .section = "utils",
            .depends = .{
                "libmath-helper (>= 1.0.0)",
                "libc6 (>= 2.34)",
            },
            .file_mappings = .{
                .{
                    .src = "build-out/{arch}/bin/math-app",
                    .dest = "usr/bin/math-app",
                    .mode = 0o755,
                },
            },
        },
    },
}
```

---

## Usage

```bash
# Build all packages in packages.zon
deb-builder

# Build a single package (positional or -p)
deb-builder math-app
deb-builder math-app -a arm64

# Build and install directly to sysroot for downstream linking
deb-builder install libmath-helper -a arm64

# Fetch sysroot build dependencies without building packages
deb-builder fetch
deb-builder fetch math-app -a arm64

# Use a custom manifest file
deb-builder -m my_packages.zon
deb-builder math-app my_packages.zon

# Output packages to a custom directory
deb-builder -o dist/

# Override the Debian/Ubuntu suite or mirror
deb-builder --suite trixie
deb-builder --suite noble --mirror http://archive.ubuntu.com/ubuntu
```

---

## CLI Reference

```
Usage: deb-builder [command] [package] [options]

Commands:
  build [package]          Build deb package(s) (default)
  install [package]        Build and install package(s) into sysroot
  fetch [package]          Fetch sysroot build_depends without building

Options:
  -h, --help               Show this help message and exit
  -a, --arch <arch>        Target architecture (e.g. amd64, arm64, riscv64)
  -p, --package <name>     Target package name (or pass as positional arg)
  -m, --manifest <file>    Manifest file path (default: packages.zon)
  -o, --output-dir <dir>   Output directory for .deb files (default: packages)
  -s, --sysroot <dir>      Override destination sysroot directory
  -i, --install            Install built package(s) into sysroot
  --suite <suite>          Debian/Ubuntu suite (e.g. bookworm, trixie, noble)
  --mirror <url>           Debian/Ubuntu mirror URL
```

---

## Path Variables

When defining `file_mappings`, `symlinks`, or `sysroot_dir`, you can use dynamic placeholders:

- `{arch}` – Target Debian architecture (`amd64`, `arm64`, `armhf`, etc.)
- `{triplet}` – Multiarch triplet (`x86_64-linux-gnu`, `aarch64-linux-gnu`, etc.)
- `{sysroot}` – Destination sysroot path for the package
