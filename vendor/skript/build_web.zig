//! Emscripten web build helpers — vendored from
//! third_party/zemscripten/build.zig (zig-gamedev/zemscripten @ main, with
//! skript's "emcc from PATH" patch). Kept OUTSIDE the zemscripten dependency
//! so skript's build.zig never comptime-imports a possibly-absent lazy dep:
//! consumers (which don't ship third_party/zemscripten) can build natively
//! without ever touching the Emscripten toolchain. Only the functions
//! skript's web step uses are copied; see the upstream file for the rest.
//!
//! These helpers are still gated behind build.zig's `web_supported` check
//! (the vendored path must be present for `zig build web` to configure), so
//! the emcc binary itself is only resolved when the web step actually runs.

const std = @import("std");
const builtin = @import("builtin");

const std_build = std.Build;
const Io = std.Io;
const Dir = std.Io.Dir;

const stopsig_needle = "    pub fn STOPSIG(s: u32) u32 {";
const stopsig_replacement = "    pub fn STOPSIG(s: u32) SIG {";
const completion_marker_name = ".skript-complete";
const completion_marker_contents = "skript-emscripten-zig-lib-complete-v1\n";
const max_patch_bytes = 1 << 24;
const max_source_link_bytes = std.fs.max_path_bytes;
const content_digest_len = std_build.Cache.hex_digest_len;

const HashedPath = struct {
    label: []const u8,
    path: std_build.Cache.Path,
};

const HashEntry = struct {
    name: []u8,
    kind: std.Io.File.Kind,
};

const Publication = enum {
    published,
    existing,
};

/// Prepare a private, compiler-keyed stdlib copy for the Emscripten target.
/// The copy is created only when the web compile asks for this step. Each
/// process publishes its complete temporary tree with a non-replacing rename,
/// so a concurrent native build never sees a partially copied stdlib.
const EmscriptenZigLib = struct {
    step: std_build.Step,
    generated_directory: std_build.GeneratedFile,
    source: std_build.Cache.Directory,

    pub fn create(b: *std_build) *EmscriptenZigLib {
        const prepare = b.allocator.create(EmscriptenZigLib) catch @panic("OOM");
        prepare.* = .{
            .step = std_build.Step.init(.{
                .id = .custom,
                .name = "Prepare Emscripten Zig lib",
                .owner = b,
                .makeFn = make,
            }),
            .generated_directory = undefined,
            .source = b.graph.zig_lib_directory,
        };
        prepare.generated_directory = .{ .step = &prepare.step };
        return prepare;
    }

    fn make(step: *std_build.Step, _: std_build.Step.MakeOptions) !void {
        const prepare: *EmscriptenZigLib = @fieldParentPtr("step", step);
        const b = step.owner;
        const io = b.graph.io;
        const output_sub_path = try outputSubPath(b, prepare);
        prepare.generated_directory.path = try b.cache_root.join(
            b.allocator,
            &.{output_sub_path},
        );

        if (try cacheEntryComplete(io, b.cache_root.handle, output_sub_path)) {
            step.result_cached = true;
            return;
        }

        try b.cache_root.handle.createDirPath(io, "tmp");
        const temporary_sub_path = try createTemporaryDirectory(io, b);
        var temporary_dir = try b.cache_root.handle.openDir(io, temporary_sub_path, .{
            .iterate = true,
            .access_sub_paths = true,
            .follow_symlinks = false,
        });
        var temporary_dir_closed = false;
        var temporary_tree_removed = false;
        defer {
            if (!temporary_dir_closed) temporary_dir.close(io);
            if (!temporary_tree_removed) {
                b.cache_root.handle.deleteTree(io, temporary_sub_path) catch |err| {
                    std.log.warn("Cannot remove temporary web stdlib '{s}': {s}", .{
                        temporary_sub_path,
                        @errorName(err),
                    });
                };
            }
        }

        var source_dir = try prepare.source.handle.openDir(io, ".", .{
            .iterate = true,
            .access_sub_paths = true,
            .follow_symlinks = false,
        });
        defer source_dir.close(io);
        try copyTree(io, source_dir, temporary_dir);
        try patchFile(
            b.allocator,
            io,
            temporary_dir,
            "std/os/emscripten.zig",
            stopsig_needle,
            stopsig_replacement,
        );
        try writeCompletionMarker(io, temporary_dir);

        try b.cache_root.handle.createDirPath(io, "o");
        temporary_dir.close(io);
        temporary_dir_closed = true;
        const publication = try publishCompleteDirectory(
            b.allocator,
            io,
            b.cache_root.handle,
            temporary_sub_path,
            output_sub_path,
        );
        temporary_tree_removed = true;
        step.result_cached = publication == .existing;
    }

    fn outputSubPath(b: *std_build, prepare: *const EmscriptenZigLib) ![]const u8 {
        var hash: std_build.Cache.HashHelper = .{};
        hash.addBytes("skript-emscripten-zig-lib-v3");
        hash.addBytes(builtin.zig_version_string);
        hash.addBytes(b.graph.zig_exe);
        if (prepare.source.path) |source_path| hash.addBytes(source_path);
        hash.addBytes(stopsig_needle);
        hash.addBytes(stopsig_replacement);

        var source_dir = try prepare.source.handle.openDir(b.graph.io, ".", .{
            .iterate = true,
            .access_sub_paths = true,
            .follow_symlinks = false,
        });
        defer source_dir.close(b.graph.io);
        try hashTreeContents(b.allocator, b.graph.io, source_dir, &hash);

        const digest = hash.final();
        return b.fmt("o{c}skript-emscripten-zig-lib-{s}", .{ Dir.path.sep, &digest });
    }
};

/// Return the lazy stdlib directory consumed by the web compile step.
pub fn prepareEmscriptenZigLib(b: *std_build) std_build.LazyPath {
    const prepare = EmscriptenZigLib.create(b);
    return .{ .generated = .{ .file = &prepare.generated_directory } };
}

fn createTemporaryDirectory(io: Io, b: *std_build) ![]const u8 {
    var attempt: usize = 0;
    while (attempt < 16) : (attempt += 1) {
        var random_value: u64 = undefined;
        io.random(std.mem.asBytes(&random_value));
        const candidate = b.fmt(
            "tmp{c}skript-emscripten-zig-lib-{x}",
            .{ Dir.path.sep, random_value },
        );
        b.cache_root.handle.createDir(io, candidate, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return candidate;
    }
    return error.UnableToCreateTemporaryDirectory;
}

fn copyTree(io: Io, source_dir: Dir, destination_dir: Dir) !void {
    var iterator = source_dir.iterate();
    while (try iterator.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                try destination_dir.createDir(io, entry.name, .default_dir);
                var source_subdir = try source_dir.openDir(io, entry.name, .{
                    .iterate = true,
                    .access_sub_paths = true,
                    .follow_symlinks = false,
                });
                defer source_subdir.close(io);
                var destination_subdir = try destination_dir.openDir(io, entry.name, .{
                    .iterate = true,
                    .access_sub_paths = true,
                    .follow_symlinks = false,
                });
                defer destination_subdir.close(io);
                try copyTree(io, source_subdir, destination_subdir);
            },
            .file => try source_dir.copyFile(
                entry.name,
                destination_dir,
                entry.name,
                io,
                .{ .permissions = .default_file },
            ),
            .sym_link => {
                var target_buffer: [max_source_link_bytes]u8 = undefined;
                const target_len = try source_dir.readLink(io, entry.name, &target_buffer);
                try destination_dir.symLink(
                    io,
                    target_buffer[0..target_len],
                    entry.name,
                    .{},
                );
            },
            else => return error.UnsupportedSourceEntry,
        }
    }
}

fn hashTreeContents(
    allocator: std.mem.Allocator,
    io: Io,
    dir: Dir,
    hash: *std_build.Cache.HashHelper,
) !void {
    var entries: std.ArrayList(HashEntry) = .empty;
    defer {
        for (entries.items) |entry| allocator.free(entry.name);
        entries.deinit(allocator);
    }

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        try entries.append(allocator, .{
            .name = name,
            .kind = entry.kind,
        });
    }
    std.mem.sort(HashEntry, entries.items, {}, struct {
        fn lessThan(_: void, lhs: HashEntry, rhs: HashEntry) bool {
            return std.mem.order(u8, lhs.name, rhs.name) == .lt;
        }
    }.lessThan);

    hash.add(@as(u64, @intCast(entries.items.len)));
    for (entries.items) |entry| {
        hash.addBytes(entry.name);
        hash.addBytes(@tagName(entry.kind));
        switch (entry.kind) {
            .directory => {
                var child = try dir.openDir(io, entry.name, .{
                    .iterate = true,
                    .access_sub_paths = true,
                    .follow_symlinks = false,
                });
                defer child.close(io);
                try hashTreeContents(allocator, io, child, hash);
            },
            .file => {
                const file = try dir.openFile(io, entry.name, .{});
                defer file.close(io);
                try hashFileContents(io, file, hash);
            },
            .sym_link => try hashSymlinkTarget(io, dir, entry.name, hash),
            else => {},
        }
    }
}

fn hashFileContents(io: Io, file: std.Io.File, hash: *std_build.Cache.HashHelper) !void {
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const amount = file.readStreaming(io, &.{buffer[0..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (amount == 0) break;
        hash.hasher.update(buffer[0..amount]);
    }
}

fn hashSymlinkTarget(
    io: Io,
    dir: Dir,
    name: []const u8,
    hash: *std_build.Cache.HashHelper,
) !void {
    var target_buffer: [max_source_link_bytes]u8 = undefined;
    const target_len = try dir.readLink(io, name, &target_buffer);
    hash.addBytes(target_buffer[0..target_len]);

    const target_stat = dir.statFile(io, name, .{ .follow_symlinks = true }) catch |err| switch (err) {
        error.FileNotFound, error.SymLinkLoop => return error.UnsupportedSymlinkTarget,
        else => return err,
    };
    if (target_stat.kind != .file) return error.UnsupportedSymlinkTarget;

    const target_file = try dir.openFile(io, name, .{});
    defer target_file.close(io);
    try hashFileContents(io, target_file, hash);
}

fn emscriptenCacheDigest(
    allocator: std.mem.Allocator,
    io: Io,
    root: Dir,
    label: []const u8,
) ![content_digest_len]u8 {
    var hash: std_build.Cache.HashHelper = .{};
    hash.addBytes("skript-content-tree-v1");
    hash.addBytes(label);
    try hashTreeContents(allocator, io, root, &hash);
    return hash.final();
}

fn cacheEntryComplete(io: Io, root: Dir, sub_path: []const u8) !bool {
    return cacheEntryCompleteWithMarker(
        io,
        root,
        sub_path,
        completion_marker_name,
        completion_marker_contents,
    );
}

fn cacheEntryCompleteWithMarker(
    io: Io,
    root: Dir,
    sub_path: []const u8,
    marker_name: []const u8,
    marker_contents: []const u8,
) !bool {
    var dir = root.openDir(io, sub_path, .{
        .access_sub_paths = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return err,
    };
    defer dir.close(io);

    var marker_buffer: [128]u8 = undefined;
    const marker = dir.readFile(io, marker_name, &marker_buffer) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return std.mem.eql(u8, marker, marker_contents);
}

fn writeCompletionMarker(io: Io, dir: Dir) !void {
    try writeCompletionMarkerWithMarker(
        io,
        dir,
        completion_marker_name,
        completion_marker_contents,
    );
}

fn writeCompletionMarkerWithMarker(
    io: Io,
    dir: Dir,
    marker_name: []const u8,
    marker_contents: []const u8,
) !void {
    try dir.writeFile(io, .{
        .sub_path = marker_name,
        .data = marker_contents,
        .flags = .{ .exclusive = true },
    });
}

fn acquirePublicationLock(
    allocator: std.mem.Allocator,
    io: Io,
    root: Dir,
    destination_sub_path: []const u8,
) !std.Io.File {
    const lock_sub_path = try std.fmt.allocPrint(
        allocator,
        "{s}.lock",
        .{destination_sub_path},
    );
    defer allocator.free(lock_sub_path);

    const lock_file = root.createFile(io, lock_sub_path, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => try root.openFile(io, lock_sub_path, .{
            .mode = .read_write,
            .allow_directory = false,
        }),
        else => return err,
    };
    errdefer lock_file.close(io);
    try lock_file.lock(io, .exclusive);
    return lock_file;
}

fn publishCompleteDirectory(
    allocator: std.mem.Allocator,
    io: Io,
    root: Dir,
    source_sub_path: []const u8,
    destination_sub_path: []const u8,
) !Publication {
    return publishCompleteDirectoryWithMarker(
        allocator,
        io,
        root,
        source_sub_path,
        destination_sub_path,
        completion_marker_name,
        completion_marker_contents,
    );
}

fn publishCompleteDirectoryWithMarker(
    allocator: std.mem.Allocator,
    io: Io,
    root: Dir,
    source_sub_path: []const u8,
    destination_sub_path: []const u8,
    marker_name: []const u8,
    marker_contents: []const u8,
) !Publication {
    var lock_file = try acquirePublicationLock(
        allocator,
        io,
        root,
        destination_sub_path,
    );
    defer lock_file.close(io);

    if (try cacheEntryCompleteWithMarker(
        io,
        root,
        destination_sub_path,
        marker_name,
        marker_contents,
    )) {
        try root.deleteTree(io, source_sub_path);
        return .existing;
    }

    try root.deleteTree(io, destination_sub_path);
    root.renamePreserve(
        source_sub_path,
        root,
        destination_sub_path,
        io,
    ) catch |err| switch (err) {
        error.PathAlreadyExists => {
            if (try cacheEntryCompleteWithMarker(
                io,
                root,
                destination_sub_path,
                marker_name,
                marker_contents,
            )) {
                try root.deleteTree(io, source_sub_path);
                return .existing;
            }
            return error.IncompleteCacheEntry;
        },
        else => return err,
    };
    return .published;
}

fn patchFile(
    allocator: std.mem.Allocator,
    io: Io,
    dir: Dir,
    relative_path: []const u8,
    needle: []const u8,
    replacement: []const u8,
) !void {
    if (needle.len == 0 or replacement.len == 0) return error.InvalidPatchTarget;

    const content = try dir.readFileAlloc(io, relative_path, allocator, .limited(max_patch_bytes));
    defer allocator.free(content);

    const original_count = countOccurrences(content, needle);
    const replacement_count = countOccurrences(content, replacement);
    if (original_count == 1 and replacement_count == 0) {
        const patched = try std.mem.replaceOwned(u8, allocator, content, needle, replacement);
        defer allocator.free(patched);

        var atomic = try dir.createFileAtomic(io, relative_path, .{ .replace = true });
        defer atomic.deinit(io);
        try atomic.file.writeStreamingAll(io, patched);
        try atomic.replace(io);
        return;
    }
    if (original_count == 0 and replacement_count == 1) return;
    if (original_count == 0 and replacement_count == 0) return error.PatchTargetMissing;
    return error.PatchTargetAmbiguous;
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (std.mem.findPos(u8, haystack, offset, needle)) |index| {
        count += 1;
        offset = index + needle.len;
    }
    return count;
}

/// Locate an executable on PATH. Returns null when absent — the caller then
/// reports the missing toolchain.
fn which(b: *std.Build, name: []const u8) ?[]const u8 {
    const path = b.graph.environ_map.get("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const probe = std.fs.path.join(b.allocator, &.{ dir, name }) catch continue;
        std.Io.Dir.cwd().access(b.graph.io, probe, .{}) catch continue;
        return probe;
    }
    return null;
}

/// Path to the emcc driver. Skript's devenv provides the Emscripten
/// toolchain (nixpkgs `emscripten`), so no emsdk checkout is involved.
pub fn emccPath(b: *std.Build) []const u8 {
    return which(b, "emcc") orelse {
        @panic("emcc not found on PATH — add the `emscripten` package to the devenv");
    };
}

pub const EmccFlags = std.StringHashMap(void);

pub const EmccDefaultFlagsOverrides = struct {
    optimize: std.builtin.OptimizeMode,
    fsanitize: bool,
};

pub fn emccDefaultFlags(allocator: std.mem.Allocator, options: EmccDefaultFlagsOverrides) EmccFlags {
    var args = EmccFlags.init(allocator);
    switch (options.optimize) {
        .Debug => {
            args.put("-O0", {}) catch unreachable;
            args.put("-gsource-map", {}) catch unreachable;
            if (options.fsanitize)
                args.put("-fsanitize=undefined", {}) catch unreachable;
        },
        .ReleaseSafe => {
            args.put("-O3", {}) catch unreachable;
            if (options.fsanitize) {
                args.put("-fsanitize=undefined", {}) catch unreachable;
                args.put("-fsanitize-minimal-runtime", {}) catch unreachable;
            }
        },
        .ReleaseFast => {
            args.put("-O3", {}) catch unreachable;
        },
        .ReleaseSmall => {
            args.put("-Oz", {}) catch unreachable;
        },
    }
    return args;
}

pub const EmccSettings = std.StringHashMap([]const u8);

pub const EmsdkAllocator = enum {
    none,
    dlmalloc,
    emmalloc,
    @"emmalloc-debug",
    @"emmalloc-memvalidate",
    @"emmalloc-verbose",
    mimalloc,
};

pub const EmccDefaultSettingsOverrides = struct {
    optimize: std.builtin.OptimizeMode,
    emsdk_allocator: EmsdkAllocator = .emmalloc,
};

pub fn emccDefaultSettings(allocator: std.mem.Allocator, options: EmccDefaultSettingsOverrides) EmccSettings {
    var settings = EmccSettings.init(allocator);
    switch (options.optimize) {
        .Debug, .ReleaseSafe => {
            settings.put("SAFE_HEAP", "1") catch unreachable;
            settings.put("STACK_OVERFLOW_CHECK", "1") catch unreachable;
            settings.put("ASSERTIONS", "1") catch unreachable;
        },
        else => {},
    }
    settings.put("MALLOC", @tagName(options.emsdk_allocator)) catch unreachable;
    return settings;
}

pub const ResourceFile = struct {
    src_path: std.Build.LazyPath,
    virtual_path: ?[]const u8 = null,

    pub fn get(self: ResourceFile, b: *std.Build) []const u8 {
        return if (self.virtual_path) |virtual_path|
            b.fmt(
                "{s}@{s}",
                .{ self.src_path.getPath(b), virtual_path },
            )
        else
            self.src_path.getPath(b);
    }
};

pub const StepOptions = struct {
    optimize: std.builtin.OptimizeMode,
    flags: EmccFlags,
    settings: EmccSettings,
    use_preload_plugins: bool = false,
    embed_paths: ?[]const ResourceFile = null,
    preload_paths: ?[]const ResourceFile = null,
    shell_file_path: ?std.Build.LazyPath = null,
    js_library_path: ?std.Build.LazyPath = null,
    wasm_file_name: ?[]const u8 = null,
    out_file_name: []const u8,
    install_dir: std.Build.InstallDir,
};

pub const EmccOutput = struct {
    install_step: *std.Build.Step,
    output_dir: std.Build.LazyPath,
    javascript: std.Build.LazyPath,
    wasm: ?std.Build.LazyPath,
};

const web_completion_marker_name = ".skript-web-complete";
const web_completion_marker_contents = "skript-web-index-complete-v1\n";

pub fn emccStep(
    b: *std.Build,
    src_paths: []const std.Build.LazyPath,
    compile_steps: []const *std.Build.Step.Compile,
    options: StepOptions,
) EmccOutput {
    var emcc = b.addSystemCommand(&.{"emcc"});

    var iter_flags = options.flags.iterator();
    while (iter_flags.next()) |kvp| {
        emcc.addArg(kvp.key_ptr.*);
    }

    var iter_settings = options.settings.iterator();
    while (iter_settings.next()) |kvp| {
        emcc.addArg(std.fmt.allocPrint(
            b.allocator,
            "-s{s}={s}",
            .{ kvp.key_ptr.*, kvp.value_ptr.* },
        ) catch unreachable);
    }

    for (src_paths) |src_path| {
        emcc.addFileArg(src_path);
    }

    for (compile_steps) |compile_step| {
        emcc.addArtifactArg(compile_step);
        for (compile_step.root_module.getGraph().modules) |module| {
            for (module.link_objects.items) |link_object| {
                switch (link_object) {
                    .other_step => |linked_compile_step| {
                        switch (linked_compile_step.kind) {
                            .lib => {
                                emcc.addArtifactArg(linked_compile_step);
                            },
                            else => {},
                        }
                    },
                    else => {},
                }
            }
        }
    }

    emcc.addArg("-o");
    const out_file = emcc.addOutputFileArg(options.out_file_name);

    if (options.use_preload_plugins) {
        emcc.addArg("--use-preload-plugins");
    }

    if (options.embed_paths) |embed_paths| {
        for (embed_paths) |path| {
            emcc.addArg("--embed-file");
            emcc.addFileArg(path.src_path);
        }
    }

    if (options.preload_paths) |preload_paths| {
        for (preload_paths) |path| {
            emcc.addArg("--preload-file");
            emcc.addFileArg(path.src_path);
        }
    }

    if (options.shell_file_path) |shell_file_path| {
        emcc.addArg("--shell-file");
        emcc.addFileArg(shell_file_path);
    }

    if (options.js_library_path) |js_library_path| {
        emcc.addArg("--js-library");
        emcc.addFileArg(js_library_path);
    }

    const output_dir = out_file.dirname();
    const install_step = b.addInstallDirectory(.{
        .source_dir = output_dir,
        .install_dir = options.install_dir,
        .install_subdir = "",
    });
    install_step.step.dependOn(&emcc.step);

    return .{
        .install_step = &install_step.step,
        .output_dir = output_dir,
        .javascript = out_file,
        .wasm = if (options.wasm_file_name) |name| output_dir.path(b, name) else null,
    };
}

fn hashCachePath(
    io: Io,
    path: std_build.Cache.Path,
    hash: *std_build.Cache.HashHelper,
) !void {
    const file = try path.root_dir.handle.openFile(io, path.subPathOrDot(), .{});
    defer file.close(io);
    try hashFileContents(io, file, hash);
}

fn readCachePathAlloc(
    allocator: std.mem.Allocator,
    io: Io,
    path: std_build.Cache.Path,
) ![]u8 {
    return path.root_dir.handle.readFileAlloc(
        io,
        path.subPathOrDot(),
        allocator,
        .limited(max_patch_bytes),
    );
}

fn webAssetRevisionPaths(io: Io, files: []const HashedPath) ![content_digest_len]u8 {
    var hash: std_build.Cache.HashHelper = .{};
    hash.addBytes("skript-web-assets-v1");
    for (files) |file| {
        hash.addBytes(file.label);
        try hashCachePath(io, file.path, &hash);
    }
    return hash.final();
}

const index_revision_declaration =
    "var ASSET_REVISION = \"__SKRIPT_ASSET_REVISION__\";";

fn revisionedIndexContents(
    allocator: std.mem.Allocator,
    template: []const u8,
    revision: []const u8,
) ![]u8 {
    const count = countOccurrences(template, index_revision_declaration);
    if (count == 0) return error.PatchTargetMissing;
    if (count != 1) return error.PatchTargetAmbiguous;

    const declaration = try std.fmt.allocPrint(
        allocator,
        "var ASSET_REVISION = \"{s}\";",
        .{revision},
    );
    defer allocator.free(declaration);
    return std.mem.replaceOwned(
        u8,
        allocator,
        template,
        index_revision_declaration,
        declaration,
    );
}

const WebAssetIndexStep = struct {
    step: std.Build.Step,
    generated_file: std.Build.GeneratedFile,
    javascript: std.Build.LazyPath,
    wasm: std.Build.LazyPath,
    worker: std.Build.LazyPath,
    index: std.Build.LazyPath,

    fn create(
        b: *std.Build,
        javascript: std.Build.LazyPath,
        wasm: std.Build.LazyPath,
        worker: std.Build.LazyPath,
        index: std.Build.LazyPath,
    ) *WebAssetIndexStep {
        const asset_step = b.allocator.create(WebAssetIndexStep) catch @panic("OOM");
        asset_step.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "Generate revisioned web index",
                .owner = b,
                .makeFn = make,
            }),
            .generated_file = undefined,
            .javascript = javascript.dupe(b),
            .wasm = wasm.dupe(b),
            .worker = worker.dupe(b),
            .index = index.dupe(b),
        };
        asset_step.generated_file = .{ .step = &asset_step.step };
        asset_step.javascript.addStepDependencies(&asset_step.step);
        asset_step.wasm.addStepDependencies(&asset_step.step);
        asset_step.worker.addStepDependencies(&asset_step.step);
        asset_step.index.addStepDependencies(&asset_step.step);
        asset_step.step.addWatchInput(asset_step.worker) catch @panic("OOM");
        asset_step.step.addWatchInput(asset_step.index) catch @panic("OOM");
        return asset_step;
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
        const asset_step: *WebAssetIndexStep = @fieldParentPtr("step", step);
        const b = step.owner;
        const io = b.graph.io;
        const javascript = try asset_step.javascript.getPath4(b, step);
        const wasm = try asset_step.wasm.getPath4(b, step);
        const worker = try asset_step.worker.getPath4(b, step);
        const index = try asset_step.index.getPath4(b, step);
        const revision = try webAssetRevisionPaths(io, &.{
            .{ .label = "javascript", .path = javascript },
            .{ .label = "wasm", .path = wasm },
            .{ .label = "worker", .path = worker },
            .{ .label = "index", .path = index },
        });
        const output_sub_path = b.fmt(
            "o{c}skript-web-index-{s}",
            .{ Dir.path.sep, &revision },
        );
        asset_step.generated_file.path = try b.cache_root.join(
            b.allocator,
            &.{ output_sub_path, "index.html" },
        );
        if (try cacheEntryCompleteWithMarker(
            io,
            b.cache_root.handle,
            output_sub_path,
            web_completion_marker_name,
            web_completion_marker_contents,
        )) {
            step.result_cached = true;
            return;
        }

        const template = try readCachePathAlloc(b.allocator, io, index);
        defer b.allocator.free(template);
        const generated = try revisionedIndexContents(
            b.allocator,
            template,
            &revision,
        );
        defer b.allocator.free(generated);

        try b.cache_root.handle.createDirPath(io, "tmp");
        const temporary_sub_path = try createTemporaryDirectory(io, b);
        var temporary_dir = try b.cache_root.handle.openDir(io, temporary_sub_path, .{
            .iterate = true,
            .access_sub_paths = true,
            .follow_symlinks = false,
        });
        var temporary_dir_closed = false;
        var temporary_tree_removed = false;
        defer {
            if (!temporary_dir_closed) temporary_dir.close(io);
            if (!temporary_tree_removed) {
                b.cache_root.handle.deleteTree(io, temporary_sub_path) catch |err| {
                    std.log.warn("Cannot remove temporary web index '{s}': {s}", .{
                        temporary_sub_path,
                        @errorName(err),
                    });
                };
            }
        }

        try temporary_dir.writeFile(io, .{
            .sub_path = "index.html",
            .data = generated,
            .flags = .{ .exclusive = true },
        });
        try writeCompletionMarkerWithMarker(
            io,
            temporary_dir,
            web_completion_marker_name,
            web_completion_marker_contents,
        );
        try b.cache_root.handle.createDirPath(io, "o");
        temporary_dir.close(io);
        temporary_dir_closed = true;
        const publication = try publishCompleteDirectoryWithMarker(
            b.allocator,
            io,
            b.cache_root.handle,
            temporary_sub_path,
            output_sub_path,
            web_completion_marker_name,
            web_completion_marker_contents,
        );
        temporary_tree_removed = true;
        step.result_cached = publication == .existing;
    }
};

pub fn webAssetIndex(
    b: *std.Build,
    javascript: std.Build.LazyPath,
    wasm: std.Build.LazyPath,
    worker: std.Build.LazyPath,
    index: std.Build.LazyPath,
) std.Build.LazyPath {
    const asset_step = WebAssetIndexStep.create(b, javascript, wasm, worker, index);
    return .{ .generated = .{ .file = &asset_step.generated_file } };
}
const testing = std.testing;

test "Emscripten cache digest tracks same-path source changes" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true, .follow_symlinks = false });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "std/os");
    try tmp.dir.writeFile(io, .{
        .sub_path = "std/os/emscripten.zig",
        .data = "first",
    });

    const first = try emscriptenCacheDigest(testing.allocator, io, tmp.dir, "zig");
    const identical = try emscriptenCacheDigest(testing.allocator, io, tmp.dir, "zig");
    try testing.expectEqualSlices(u8, &first, &identical);

    try tmp.dir.writeFile(io, .{
        .sub_path = "std/os/emscripten.zig",
        .data = "second",
    });
    const changed = try emscriptenCacheDigest(testing.allocator, io, tmp.dir, "zig");
    try testing.expect(!std.mem.eql(u8, &first, &changed));
}

test "tree digest includes symlink target file contents" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var external = testing.tmpDir(.{});
    defer external.cleanup();

    try external.dir.writeFile(io, .{ .sub_path = "target", .data = "first" });
    const target = try external.dir.realPathFileAlloc(io, "target", testing.allocator);
    defer testing.allocator.free(target);
    tmp.dir.symLink(io, target, "link", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    const first = try emscriptenCacheDigest(testing.allocator, io, tmp.dir, "zig");

    try external.dir.writeFile(io, .{ .sub_path = "target", .data = "second" });
    const changed = try emscriptenCacheDigest(testing.allocator, io, tmp.dir, "zig");
    try testing.expect(!std.mem.eql(u8, &first, &changed));
}

test "web asset revision covers every input and is stable" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const names = [_][]const u8{
        "skript.js",
        "skript.wasm",
        "worker.js",
        "index.html",
    };
    const contents = [_][]const u8{
        "javascript",
        "wasm",
        "worker",
        "index",
    };
    for (names, contents) |name, content| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = content });
    }

    const root_dir: std_build.Cache.Directory = .{
        .path = null,
        .handle = tmp.dir,
    };
    const inputs = [_]HashedPath{
        .{ .label = "javascript", .path = .{ .root_dir = root_dir, .sub_path = names[0] } },
        .{ .label = "wasm", .path = .{ .root_dir = root_dir, .sub_path = names[1] } },
        .{ .label = "worker", .path = .{ .root_dir = root_dir, .sub_path = names[2] } },
        .{ .label = "index", .path = .{ .root_dir = root_dir, .sub_path = names[3] } },
    };
    const first = try webAssetRevisionPaths(io, &inputs);
    const identical = try webAssetRevisionPaths(io, &inputs);
    try testing.expectEqualSlices(u8, &first, &identical);

    for (names, contents) |name, content| {
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "changed" });
        const changed = try webAssetRevisionPaths(io, &inputs);
        try testing.expect(!std.mem.eql(u8, &first, &changed));
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = content });
    }
}

test "cache completion requires the exact marker" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "entry", .default_dir);
    try testing.expect(!try cacheEntryComplete(io, tmp.dir, "entry"));

    try tmp.dir.writeFile(io, .{
        .sub_path = "entry/" ++ completion_marker_name,
        .data = "invalid",
    });
    try testing.expect(!try cacheEntryComplete(io, tmp.dir, "entry"));

    try tmp.dir.writeFile(io, .{
        .sub_path = "entry/" ++ completion_marker_name,
        .data = completion_marker_contents,
    });
    try testing.expect(try cacheEntryComplete(io, tmp.dir, "entry"));
}

test "complete directory publication never replaces a winner" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "first", .default_dir);
    {
        var first = try tmp.dir.openDir(io, "first", .{});
        defer first.close(io);
        try first.writeFile(io, .{ .sub_path = "payload", .data = "winner" });
        try writeCompletionMarker(io, first);
    }
    try testing.expectEqual(
        Publication.published,
        try publishCompleteDirectory(testing.allocator, io, tmp.dir, "first", "cache"),
    );

    try tmp.dir.createDir(io, "second", .default_dir);
    {
        var second = try tmp.dir.openDir(io, "second", .{});
        defer second.close(io);
        try second.writeFile(io, .{ .sub_path = "payload", .data = "loser" });
        try writeCompletionMarker(io, second);
    }
    try testing.expectEqual(
        Publication.existing,
        try publishCompleteDirectory(testing.allocator, io, tmp.dir, "second", "cache"),
    );

    var buffer: [16]u8 = undefined;
    const payload = try tmp.dir.readFile(io, "cache/payload", &buffer);
    try testing.expectEqualStrings("winner", payload);
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(io, "second", .{ .follow_symlinks = false }),
    );
}

test "patchFile accepts one original or one compatible replacement" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = "before OLD after" });
    try patchFile(testing.allocator, io, tmp.dir, "source", "OLD", "NEW");
    try patchFile(testing.allocator, io, tmp.dir, "source", "OLD", "NEW");

    var buffer: [64]u8 = undefined;
    const patched = try tmp.dir.readFile(io, "source", &buffer);
    try testing.expectEqualStrings("before NEW after", patched);

    try tmp.dir.writeFile(io, .{ .sub_path = "missing", .data = "unrelated" });
    try testing.expectError(
        error.PatchTargetMissing,
        patchFile(testing.allocator, io, tmp.dir, "missing", "OLD", "NEW"),
    );

    try tmp.dir.writeFile(io, .{ .sub_path = "duplicate-old", .data = "OLD OLD" });
    try testing.expectError(
        error.PatchTargetAmbiguous,
        patchFile(testing.allocator, io, tmp.dir, "duplicate-old", "OLD", "NEW"),
    );

    try tmp.dir.writeFile(io, .{ .sub_path = "duplicate-new", .data = "NEW NEW" });
    try testing.expectError(
        error.PatchTargetAmbiguous,
        patchFile(testing.allocator, io, tmp.dir, "duplicate-new", "OLD", "NEW"),
    );

    try tmp.dir.writeFile(io, .{ .sub_path = "mixed", .data = "OLD NEW" });
    try testing.expectError(
        error.PatchTargetAmbiguous,
        patchFile(testing.allocator, io, tmp.dir, "mixed", "OLD", "NEW"),
    );
}

test "revisioned index replaces exactly one declaration" {
    const template =
        \\before
        \\var ASSET_REVISION = "__SKRIPT_ASSET_REVISION__";
        \\after
    ;
    const revised = try revisionedIndexContents(testing.allocator, template, "abc123");
    defer testing.allocator.free(revised);
    try testing.expectEqualStrings(
        "before\nvar ASSET_REVISION = \"abc123\";\nafter",
        revised,
    );

    try testing.expectError(
        error.PatchTargetMissing,
        revisionedIndexContents(testing.allocator, "var other = 1;", "abc123"),
    );
    try testing.expectError(
        error.PatchTargetAmbiguous,
        revisionedIndexContents(
            testing.allocator,
            index_revision_declaration ++ "\n" ++ index_revision_declaration,
            "abc123",
        ),
    );
}
