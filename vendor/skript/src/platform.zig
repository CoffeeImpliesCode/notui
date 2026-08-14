const std = @import("std");
pub fn ffiSupported(target: std.Target) bool {
    return libcSupported(target) and switch (target.cpu.arch) {
        .arc,
        .csky,
        .loongarch64,
        .m68k,
        .riscv32,
        .s390x,
        .sparc,
        .sparc64,
        .x86,
        .x86_64,
        .xtensa,
        .riscv64,
        .powerpc,
        .powerpcle,
        .powerpc64,
        .powerpc64le,
        .arm,
        .armeb,
        .mips,
        .mipsel,
        .mips64,
        .mips64el,
        .aarch64,
        .aarch64_be,
        => true,
        .wasm32,
        .wasm64,
        => false,
        else => false,
    };
}

pub fn dynLibSupported(target: std.Target) bool {
    if (target.cpu.arch == .riscv64 and target.os.tag != .linux) return false;
    if ((target.cpu.arch == .mips or target.cpu.arch == .mipsel) and target.os.tag == .openbsd) return false;
    return switch (target.os.tag) {
        .linux,
        .driverkit,
        .ios,
        .maccatalyst,
        .macos,
        .tvos,
        .visionos,
        .watchos,
        .freebsd,
        .netbsd,
        .openbsd,
        .dragonfly,
        .illumos,
        .windows,
        => true,
        else => false,
    };
}

/// Whether Zig can provide a working libc for the target.
/// Gates any feature that links a C library.
pub fn libcSupported(target: std.Target) bool {
    // Zig does not ship bionic libc. Android cross-compilation has no libc.
    if (target.abi.isAndroid()) return false;
    // Targets without a traditional libc
    return switch (target.os.tag) {
        .freestanding,
        .uefi,
        .other,
        .wasi,
        .emscripten,
        => false,
        // powerpc-* freebsd: 'string.h' not found in Zig sysroot (32-bit only)
        // riscv64 *BSD: missing libc functions (__clear_cache)
        .freebsd => !(target.cpu.arch == .powerpc or target.cpu.arch == .powerpcle or target.cpu.arch == .riscv64),
        // powerpc*-openbsd: Zig cannot provide libc
        // mips*-openbsd: broken
        // riscv64-openbsd: missing __clear_cache
        .openbsd => switch (target.cpu.arch) {
            .powerpc,
            .powerpcle,
            .powerpc64,
            .powerpc64le,
            .mips,
            .mipsel,
            .mips64,
            .mips64el,
            .riscv64,
            => false,
            else => true,
        },
        // mips/mips64 netbsd: sgidefs.h missing from Zig sysroot
        // riscv64-netbsd: missing __clear_cache
        .netbsd => !(target.cpu.arch == .mips or target.cpu.arch == .mipsel or
            target.cpu.arch == .mips64 or target.cpu.arch == .mips64el or
            target.cpu.arch == .riscv64),
        // riscv64-dragonfly: missing __clear_cache
        .dragonfly => target.cpu.arch != .riscv64,
        // arm/aarch64-windows: panics in build.zig (MSVC asm only)
        .windows => !(target.cpu.arch == .arm or target.cpu.arch == .armeb or
            target.cpu.arch == .aarch64 or target.cpu.arch == .aarch64_be),
        .linux,
        .macos,
        .ios,
        .maccatalyst,
        .tvos,
        .visionos,
        .watchos,
        .driverkit,
        .illumos,
        .haiku,
        => true,
        else => true,
    };
}
