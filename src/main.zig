const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.array_list.Managed; // managed: init(alloc), append(item), deinit()
const Thread = std.Thread;
const Mutex = Thread.Mutex;

// ── ANSI colors ───────────────────────────────────────────────────────────────

const ansi = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const blue = "\x1b[34m";
    const cyan = "\x1b[36m";
    const bold_red = "\x1b[1;31m";
    const bold_yellow = "\x1b[1;33m";
    const bold_cyan = "\x1b[1;36m";
    const bold_green = "\x1b[1;32m";
    const bold_white = "\x1b[1;37m";
};

// ── DirKind ───────────────────────────────────────────────────────────────────

const DirKind = enum {
    python_venv,
    node_modules,
    next_cache,
    nuxt_cache,
    rust_target,
    custom,

    fn label(self: DirKind) []const u8 {
        return switch (self) {
            .python_venv => "Python venv",
            .node_modules => "Node modules",
            .next_cache => "Next.js cache",
            .nuxt_cache => "Nuxt cache",
            .rust_target => "Rust target",
            .custom => "Custom",
        };
    }

    fn colorCode(self: DirKind) []const u8 {
        return switch (self) {
            .python_venv => ansi.yellow,
            .node_modules => ansi.green,
            .next_cache, .nuxt_cache => ansi.cyan,
            .rust_target => ansi.red,
            .custom => ansi.blue,
        };
    }
};

// ── Entry ─────────────────────────────────────────────────────────────────────

const Entry = struct {
    path: []u8,
    kind: DirKind,
    custom_label: []const u8,
    size_bytes: u64,
    mtime_ns: i128,

    fn kindLabel(self: *const Entry) []const u8 {
        return if (self.kind == .custom) self.custom_label else self.kind.label();
    }

    fn ageDays(self: *const Entry) u64 {
        const now_ns = std.time.nanoTimestamp();
        if (now_ns <= self.mtime_ns) return 0;
        const diff: u128 = @intCast(now_ns - self.mtime_ns);
        return @intCast(diff / std.time.ns_per_day);
    }

    fn sizeStr(self: *const Entry, buf: *[32]u8) []const u8 {
        return fmtSize(self.size_bytes, buf);
    }
};

// ── Helpers ───────────────────────────────────────────────────────────────────

fn fmtSize(bytes: u64, buf: *[32]u8) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var val: f64 = @floatFromInt(bytes);
    var i: usize = 0;
    while (val >= 1024.0 and i < units.len - 1) {
        val /= 1024.0;
        i += 1;
    }
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ val, units[i] }) catch "?";
}

fn parseSize(s: []const u8) ?u64 {
    const SE = struct { suffix: []const u8, mult: u64 };
    const table = [_]SE{
        .{ .suffix = "TiB", .mult = 1 << 40 }, .{ .suffix = "GiB", .mult = 1 << 30 },
        .{ .suffix = "MiB", .mult = 1 << 20 }, .{ .suffix = "KiB", .mult = 1 << 10 },
        .{ .suffix = "TB", .mult = 1_000_000_000_000 }, .{ .suffix = "GB", .mult = 1_000_000_000 },
        .{ .suffix = "MB", .mult = 1_000_000 },         .{ .suffix = "KB", .mult = 1_000 },
        .{ .suffix = "B", .mult = 1 },
    };
    for (table) |su| {
        if (s.len > su.suffix.len) {
            const tail = s[s.len - su.suffix.len ..];
            if (std.ascii.eqlIgnoreCase(tail, su.suffix)) {
                const num_s = mem.trim(u8, s[0 .. s.len - su.suffix.len], " \t");
                const num = std.fmt.parseFloat(f64, num_s) catch continue;
                return @intFromFloat(num * @as(f64, @floatFromInt(su.mult)));
            }
        }
    }
    return std.fmt.parseInt(u64, mem.trim(u8, s, " \t"), 10) catch null;
}

// Iterative dir size (avoids stack overflow on deep trees)
fn calcDirSize(alloc: Allocator, path: []const u8) u64 {
    var total: u64 = 0;
    var stack = ArrayList([]u8).init(alloc);
    defer {
        for (stack.items) |p| alloc.free(p);
        stack.deinit();
    }

    const root = alloc.dupe(u8, path) catch return 0;
    stack.append(root) catch { alloc.free(root); return 0; };

    while (stack.items.len > 0) {
        const cur = stack.pop().?;
        defer alloc.free(cur);
        var dir = fs.openDirAbsolute(cur, .{ .iterate = true }) catch continue;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |de| {
            switch (de.kind) {
                .file, .sym_link => {
                    var f = dir.openFile(de.name, .{}) catch continue;
                    defer f.close();
                    const st = f.stat() catch continue;
                    total += st.size;
                },
                .directory => {
                    const child = fs.path.join(alloc, &.{ cur, de.name }) catch continue;
                    stack.append(child) catch { alloc.free(child); };
                },
                else => {},
            }
        }
    }
    return total;
}

fn getDirMtime(path: []const u8) i128 {
    var dir = fs.openDirAbsolute(path, .{}) catch return 0;
    defer dir.close();
    const st = dir.stat() catch return 0;
    return st.mtime;
}

// ── Config ────────────────────────────────────────────────────────────────────

const FilterType = enum { all, python, node, rust };

const Config = struct {
    root: []const u8 = ".",
    depth: ?usize = null,
    sort_size: bool = false,
    sort_age: bool = false,
    filter: FilterType = .all,
    min_size: u64 = 0,
    older_than: ?u64 = null,
    delete: bool = false,
    interactive: bool = false,
    dry_run: bool = false,
    json_out: bool = false,
    export_path: ?[]const u8 = null,
    extra_targets: ArrayList([]const u8),
    no_color: bool = false,
    no_size: bool = false,
    num_threads: usize = 4,
    show_help: bool = false,
};

const help_text =
    \\mouser v1.0.0  —  find and nuke dependency/build directories
    \\
    \\USAGE:
    \\  mouser [OPTIONS] [PATH]
    \\
    \\ARGS:
    \\  PATH                  Root directory to scan (default: current dir)
    \\
    \\SCAN OPTIONS:
    \\  -d, --depth N         Max scan depth
    \\  -f, --filter TYPE     all | python | node | rust  (default: all)
    \\      --target A,B,...  Extra directory names to scan for
    \\      --min-size SIZE   Min size to include (e.g. 50MB, 1.5GiB)
    \\      --older-than N   Only dirs not touched in N days
    \\      --no-size         Skip size calculation (much faster)
    \\
    \\OUTPUT OPTIONS:
    \\  -s, --sort-size       Sort by size (largest first)
    \\      --sort-age        Sort by last modified (oldest first)
    \\      --json            Output as JSON
    \\      --export FILE     Export to .json or .csv file
    \\      --no-color        Disable ANSI colors
    \\
    \\DELETE OPTIONS:
    \\      --delete          Delete all found dirs (confirms first)
    \\  -i, --interactive     Numbered list — pick which to delete
    \\      --dry-run         Show what would be deleted, don't act
    \\
    \\MISC:
    \\  -t, --threads N       Threads for size calc (default: 4)
    \\  -h, --help            This help
    \\
    \\DETECTED BY DEFAULT:
    \\  Python   .venv  venv  my_venv  .virtualenv
    \\  Node     node_modules  .next  .nuxt
    \\  Rust     target/  (only when Cargo.toml exists in parent)
    \\
    \\EXAMPLES:
    \\  mouser ~                         scan home directory
    \\  mouser ~ -s --min-size 100MB     large dirs, sorted by size
    \\  mouser ~ --filter node --delete  delete all node_modules
    \\  mouser . -i                      interactive deletion picker
    \\  mouser ~ --older-than 60 --json  stale dirs as JSON
;

fn parseArgs(alloc: Allocator) !Config {
    var config = Config{ .extra_targets = ArrayList([]const u8).init(alloc) };
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next(); // skip argv[0]

    var got_path = false;
    while (args.next()) |arg| {
        if (!got_path and arg.len > 0 and arg[0] != '-') {
            config.root = arg;
            got_path = true;
            continue;
        }
        if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
            config.show_help = true;
        } else if (mem.eql(u8, arg, "-s") or mem.eql(u8, arg, "--sort-size")) {
            config.sort_size = true;
        } else if (mem.eql(u8, arg, "--sort-age")) {
            config.sort_age = true;
        } else if (mem.eql(u8, arg, "--delete")) {
            config.delete = true;
        } else if (mem.eql(u8, arg, "-i") or mem.eql(u8, arg, "--interactive")) {
            config.interactive = true;
        } else if (mem.eql(u8, arg, "--dry-run")) {
            config.dry_run = true;
        } else if (mem.eql(u8, arg, "--json")) {
            config.json_out = true;
        } else if (mem.eql(u8, arg, "--no-size")) {
            config.no_size = true;
        } else if (mem.eql(u8, arg, "--no-color")) {
            config.no_color = true;
        } else if (mem.eql(u8, arg, "-d") or mem.eql(u8, arg, "--depth")) {
            const v = args.next() orelse return error.MissingValue;
            config.depth = try std.fmt.parseInt(usize, v, 10);
        } else if (mem.eql(u8, arg, "-f") or mem.eql(u8, arg, "--filter")) {
            const v = args.next() orelse return error.MissingValue;
            config.filter = std.meta.stringToEnum(FilterType, v) orelse return error.InvalidFilter;
        } else if (mem.eql(u8, arg, "--min-size")) {
            const v = args.next() orelse return error.MissingValue;
            config.min_size = parseSize(v) orelse return error.InvalidSize;
        } else if (mem.eql(u8, arg, "--older-than")) {
            const v = args.next() orelse return error.MissingValue;
            config.older_than = try std.fmt.parseInt(u64, v, 10);
        } else if (mem.eql(u8, arg, "--export")) {
            config.export_path = args.next() orelse return error.MissingValue;
        } else if (mem.eql(u8, arg, "-t") or mem.eql(u8, arg, "--threads")) {
            const v = args.next() orelse return error.MissingValue;
            config.num_threads = try std.fmt.parseInt(usize, v, 10);
        } else if (mem.eql(u8, arg, "--target")) {
            const v = args.next() orelse return error.MissingValue;
            var it = mem.splitScalar(u8, v, ',');
            while (it.next()) |t| {
                const trimmed = mem.trim(u8, t, " \t");
                if (trimmed.len > 0) try config.extra_targets.append(trimmed);
            }
        }
    }
    return config;
}

// ── Scanner ───────────────────────────────────────────────────────────────────

const skip_names = [_][]const u8{
    "System Volume Information", "$RECYCLE.BIN",
    "Windows",                   "Program Files",
    "Program Files (x86)",       "ProgramData",
    "AppData",                   "__pycache__",
    ".git",
};

fn shouldSkip(name: []const u8) bool {
    for (skip_names) |s| if (std.ascii.eqlIgnoreCase(name, s)) return true;
    return false;
}

const NamedTarget = struct { name: []const u8, kind: DirKind };
const builtin_targets = [_]NamedTarget{
    .{ .name = ".venv", .kind = .python_venv },
    .{ .name = "venv", .kind = .python_venv },
    .{ .name = "my_venv", .kind = .python_venv },
    .{ .name = ".virtualenv", .kind = .python_venv },
    .{ .name = "node_modules", .kind = .node_modules },
    .{ .name = ".next", .kind = .next_cache },
    .{ .name = ".nuxt", .kind = .nuxt_cache },
};

fn kindMatchesFilter(kind: DirKind, filter: FilterType) bool {
    return switch (filter) {
        .all => true,
        .python => kind == .python_venv,
        .node => kind == .node_modules or kind == .next_cache or kind == .nuxt_cache,
        .rust => kind == .rust_target,
    };
}

const ScanItem = struct { path: []u8, depth: usize };

fn scanRoot(
    alloc: Allocator,
    root_abs: []const u8,
    config: *const Config,
    entries: *ArrayList(Entry),
    mu: *Mutex,
    found_count: *std.atomic.Value(u64),
) !void {
    var stack = ArrayList(ScanItem).init(alloc);
    defer {
        for (stack.items) |item| alloc.free(item.path);
        stack.deinit();
    }

    const root_copy = try alloc.dupe(u8, root_abs);
    try stack.append(.{ .path = root_copy, .depth = 0 });

    while (stack.items.len > 0) {
        const item = stack.pop().?;
        defer alloc.free(item.path);

        if (config.depth) |max_d| if (item.depth > max_d) continue;

        const name = fs.path.basename(item.path);
        if (name.len == 0 or shouldSkip(name)) continue;

        var matched = false;

        // Check builtin targets
        for (builtin_targets) |t| {
            if (mem.eql(u8, name, t.name) and kindMatchesFilter(t.kind, config.filter)) {
                const ent = Entry{
                    .path = try alloc.dupe(u8, item.path),
                    .kind = t.kind,
                    .custom_label = "",
                    .size_bytes = 0,
                    .mtime_ns = getDirMtime(item.path),
                };
                mu.lock();
                try entries.append(ent);
                mu.unlock();
                _ = found_count.fetchAdd(1, .monotonic);
                matched = true;
                break;
            }
        }

        // Rust target/ detection
        if (!matched and mem.eql(u8, name, "target") and
            (config.filter == .all or config.filter == .rust))
        {
            const parent = fs.path.dirname(item.path) orelse "";
            if (parent.len > 0) {
                const cargo_path = try fs.path.join(alloc, &.{ parent, "Cargo.toml" });
                defer alloc.free(cargo_path);
                if (fs.accessAbsolute(cargo_path, .{})) |_| {
                    const ent = Entry{
                        .path = try alloc.dupe(u8, item.path),
                        .kind = .rust_target,
                        .custom_label = "",
                        .size_bytes = 0,
                        .mtime_ns = getDirMtime(item.path),
                    };
                    mu.lock();
                    try entries.append(ent);
                    mu.unlock();
                    _ = found_count.fetchAdd(1, .monotonic);
                    matched = true;
                } else |_| {}
            }
        }

        // Custom targets
        if (!matched) {
            for (config.extra_targets.items) |ct| {
                if (mem.eql(u8, name, ct)) {
                    const ent = Entry{
                        .path = try alloc.dupe(u8, item.path),
                        .kind = .custom,
                        .custom_label = ct,
                        .size_bytes = 0,
                        .mtime_ns = getDirMtime(item.path),
                    };
                    mu.lock();
                    try entries.append(ent);
                    mu.unlock();
                    _ = found_count.fetchAdd(1, .monotonic);
                    matched = true;
                    break;
                }
            }
        }

        if (matched) continue;

        // Recurse into subdirs
        var dir = fs.openDirAbsolute(item.path, .{ .iterate = true }) catch continue;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |de| {
            if (de.kind != .directory) continue;
            const child = try fs.path.join(alloc, &.{ item.path, de.name });
            stack.append(.{ .path = child, .depth = item.depth + 1 }) catch { alloc.free(child); };
        }
    }
}

// ── Parallel size calculation ─────────────────────────────────────────────────

const SizeCtx = struct {
    alloc: Allocator,
    entries: []Entry,
    start: usize,
    stride: usize,
    done: *std.atomic.Value(u64),
};

fn sizeWorker(ctx: SizeCtx) void {
    var i = ctx.start;
    while (i < ctx.entries.len) : (i += ctx.stride) {
        ctx.entries[i].size_bytes = calcDirSize(ctx.alloc, ctx.entries[i].path);
        _ = ctx.done.fetchAdd(1, .monotonic);
    }
}

fn calcSizesParallel(alloc: Allocator, entries: []Entry, num_threads: usize) !void {
    if (entries.len == 0) return;
    const n = @min(num_threads, entries.len);
    var done = std.atomic.Value(u64).init(0);

    const threads = try alloc.alloc(Thread, n);
    defer alloc.free(threads);

    for (0..n) |i| {
        threads[i] = try Thread.spawn(.{}, sizeWorker, .{SizeCtx{
            .alloc = alloc,
            .entries = entries,
            .start = i,
            .stride = n,
            .done = &done,
        }});
    }

    const stderr = std.fs.File.stderr().deprecatedWriter();
    const total = entries.len;
    while (done.load(.monotonic) < total) {
        const d = done.load(.monotonic);
        const pct = if (total > 0) (d * 100) / total else 100;
        stderr.print("\r  Calculating sizes... {d}/{d} ({d}%)   ", .{ d, total, pct }) catch {};
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    stderr.writeAll("\r                                          \r") catch {};

    for (threads) |t| t.join();
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn padRight(buf: []u8, s: []const u8, width: usize) []u8 {
    const w = @min(width, buf.len);
    @memset(buf[0..w], ' ');
    const copy_len = @min(s.len, w);
    @memcpy(buf[0..copy_len], s[0..copy_len]);
    return buf[0..w];
}

// ── Output ────────────────────────────────────────────────────────────────────

fn printTable(entries: []const Entry, config: *const Config, total_bytes: u64) void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const nc = config.no_color;

    var max_kind: usize = 12;
    var max_path: usize = 30;
    for (entries) |*e| {
        max_kind = @max(max_kind, e.kindLabel().len);
        max_path = @max(max_path, e.path.len);
    }
    max_path = @min(max_path, 80);

    // Header
    if (!nc) stdout.writeAll(ansi.bold_white) catch {};
    var hdr_buf: [64]u8 = undefined;
    stdout.print("  {s}  {s:>10}  {s:>7}  {s}\n", .{
        padRight(&hdr_buf, "Type", max_kind), "Size", "Age(d)", "Path",
    }) catch {};
    if (!nc) stdout.writeAll(ansi.reset) catch {};

    // Separator
    const sep_alloc = std.heap.page_allocator;
    const sep_len = max_kind + 28 + max_path;
    const sep = sep_alloc.alloc(u8, sep_len) catch return;
    defer sep_alloc.free(sep);
    @memset(sep, '-');
    if (!nc) stdout.writeAll(ansi.dim) catch {};
    stdout.print("  {s}\n", .{sep}) catch {};
    if (!nc) stdout.writeAll(ansi.reset) catch {};

    // Rows
    for (entries) |*e| {
        var sb: [32]u8 = undefined;
        var ab: [16]u8 = undefined;
        const size_s = e.sizeStr(&sb);
        const age_s = std.fmt.bufPrint(&ab, "{d}", .{e.ageDays()}) catch "?";

        // Truncate path if needed
        const path_disp = if (e.path.len > max_path) e.path[e.path.len - max_path ..] else e.path;

        const size_color: []const u8 = if (nc) "" else blk: {
            if (e.size_bytes > 1 << 30) break :blk ansi.bold_red;
            if (e.size_bytes > 100 << 20) break :blk ansi.bold_yellow;
            break :blk ansi.green;
        };

        if (!nc) stdout.writeAll(e.kind.colorCode()) catch {};
        var kind_buf: [64]u8 = undefined;
        stdout.print("  {s}", .{padRight(&kind_buf, e.kindLabel(), max_kind)}) catch {};
        if (!nc) stdout.writeAll(ansi.reset) catch {};
        if (!nc) stdout.writeAll(size_color) catch {};
        stdout.print("  {s:>10}", .{size_s}) catch {};
        if (!nc) stdout.writeAll(ansi.reset) catch {};
        stdout.print("  {s:>7}", .{age_s}) catch {};
        if (!nc) stdout.writeAll(ansi.dim) catch {};
        stdout.print("  {s}\n", .{path_disp}) catch {};
        if (!nc) stdout.writeAll(ansi.reset) catch {};
    }

    // Footer separator
    if (!nc) stdout.writeAll(ansi.dim) catch {};
    stdout.print("  {s}\n", .{sep}) catch {};
    if (!nc) stdout.writeAll(ansi.reset) catch {};

    // Summary line
    var tb: [32]u8 = undefined;
    stdout.print("\n  ", .{}) catch {};
    if (!nc) stdout.writeAll(ansi.bold_white) catch {};
    stdout.print("{d} director{s}", .{ entries.len, if (entries.len == 1) "y" else "ies" }) catch {};
    if (!nc) stdout.writeAll(ansi.reset ++ "  " ++ ansi.bold_yellow) catch {};
    stdout.print("  {s} total\n", .{fmtSize(total_bytes, &tb)}) catch {};
    if (!nc) stdout.writeAll(ansi.reset) catch {};

    // Per-kind breakdown
    var counts = [_]struct { label: []const u8, clr: []const u8, n: u32, b: u64 }{
        .{ .label = "Python venv", .clr = ansi.yellow, .n = 0, .b = 0 },
        .{ .label = "Node / JS", .clr = ansi.green, .n = 0, .b = 0 },
        .{ .label = "Rust target", .clr = ansi.red, .n = 0, .b = 0 },
        .{ .label = "Custom", .clr = ansi.blue, .n = 0, .b = 0 },
    };
    for (entries) |*e| {
        const idx: usize = switch (e.kind) {
            .python_venv => 0,
            .node_modules, .next_cache, .nuxt_cache => 1,
            .rust_target => 2,
            .custom => 3,
        };
        counts[idx].n += 1;
        counts[idx].b += e.size_bytes;
    }
    for (counts) |c| {
        if (c.n == 0) continue;
        var kb: [32]u8 = undefined;
        if (!nc) stdout.writeAll(c.clr) catch {};
        stdout.print("    {s:<14}  ×{d}  {s}\n", .{ c.label, c.n, fmtSize(c.b, &kb) }) catch {};
        if (!nc) stdout.writeAll(ansi.reset) catch {};
    }
}

fn writeJson(entries: []const Entry, writer: anytype) !void {
    try writer.writeAll("[\n");
    for (entries, 0..) |*e, i| {
        var sb: [32]u8 = undefined;
        try writer.print(
            "  {{\"path\":\"{s}\",\"kind\":\"{s}\",\"size_bytes\":{d},\"size_human\":\"{s}\",\"age_days\":{d}}}{s}\n",
            .{ e.path, e.kindLabel(), e.size_bytes, e.sizeStr(&sb), e.ageDays(), if (i < entries.len - 1) "," else "" },
        );
    }
    try writer.writeAll("]\n");
}

fn exportFile(entries: []const Entry, path: []const u8) !void {
    const file = try fs.createFileAbsolute(path, .{});
    defer file.close();
    const w = file.deprecatedWriter();
    const ext = blk: {
        const dot = mem.lastIndexOfScalar(u8, path, '.') orelse break :blk "";
        break :blk path[dot..];
    };
    if (std.ascii.eqlIgnoreCase(ext, ".csv")) {
        try w.writeAll("path,kind,size_bytes,size_human,age_days\n");
        for (entries) |*e| {
            var sb: [32]u8 = undefined;
            try w.print("{s},{s},{d},{s},{d}\n", .{
                e.path, e.kindLabel(), e.size_bytes, e.sizeStr(&sb), e.ageDays(),
            });
        }
    } else {
        try writeJson(entries, w);
    }
}

// ── Deletion ──────────────────────────────────────────────────────────────────

fn doDelete(paths: []const []const u8, no_color: bool) struct { ok: u32, fail: u32, freed: u64 } {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    var ok: u32 = 0;
    var fail: u32 = 0;
    var freed: u64 = 0;
    for (paths) |p| {
        // Measure before delete (best-effort — may return 0 if already gone)
        const sz = calcDirSize(std.heap.page_allocator, p);
        fs.deleteTreeAbsolute(p) catch |err| {
            if (!no_color) stdout.writeAll(ansi.red) catch {};
            stdout.print("  ✗ {s}  ({s})\n", .{ p, @errorName(err) }) catch {};
            if (!no_color) stdout.writeAll(ansi.reset) catch {};
            fail += 1;
            continue;
        };
        if (!no_color) stdout.writeAll(ansi.green) catch {};
        stdout.print("  ✓ {s}\n", .{p}) catch {};
        if (!no_color) stdout.writeAll(ansi.reset) catch {};
        ok += 1;
        freed += sz;
    }
    return .{ .ok = ok, .fail = fail, .freed = freed };
}

fn interactiveSelect(alloc: Allocator, entries: []const Entry, no_color: bool) !ArrayList([]const u8) {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stdin = std.fs.File.stdin().deprecatedReader();
    var selected = ArrayList([]const u8).init(alloc);

    stdout.writeAll("\n  Select directories to delete:\n") catch {};
    for (entries, 1..) |*e, i| {
        var sb: [32]u8 = undefined;
        if (!no_color) stdout.writeAll(e.kind.colorCode()) catch {};
        stdout.print("  {d:>4}.  {s:<14}  {s:>10}  {s}\n", .{
            i, e.kindLabel(), e.sizeStr(&sb), e.path,
        }) catch {};
        if (!no_color) stdout.writeAll(ansi.reset) catch {};
    }
    stdout.writeAll("\n  Enter numbers (1,3,5 | 2-5 | all), blank=cancel:\n  > ") catch {};

    var line_buf: [1024]u8 = undefined;
    const raw = try stdin.readUntilDelimiterOrEof(&line_buf, '\n') orelse return selected;
    const input = mem.trim(u8, raw, " \t\r\n");
    if (input.len == 0) return selected;

    var chosen = ArrayList(usize).init(alloc);
    defer chosen.deinit();

    if (std.ascii.eqlIgnoreCase(input, "all")) {
        for (0..entries.len) |i| try chosen.append(i);
    } else {
        var parts = mem.splitScalar(u8, input, ',');
        while (parts.next()) |part| {
            const p = mem.trim(u8, part, " \t");
            if (mem.indexOfScalar(u8, p, '-')) |dash| {
                const a = std.fmt.parseInt(usize, p[0..dash], 10) catch continue;
                const b = std.fmt.parseInt(usize, p[dash + 1 ..], 10) catch continue;
                var k = a;
                while (k <= b) : (k += 1) if (k >= 1 and k <= entries.len) try chosen.append(k - 1);
            } else {
                const n = std.fmt.parseInt(usize, p, 10) catch continue;
                if (n >= 1 and n <= entries.len) try chosen.append(n - 1);
            }
        }
    }

    if (chosen.items.len == 0) return selected;

    var preview_total: u64 = 0;
    stdout.writeAll("\n  Selected for deletion:\n") catch {};
    for (chosen.items) |idx| {
        var sb: [32]u8 = undefined;
        stdout.print("    • [{s}] {s}\n", .{ entries[idx].sizeStr(&sb), entries[idx].path }) catch {};
        preview_total += entries[idx].size_bytes;
    }
    var pb: [32]u8 = undefined;
    stdout.print("  Total: {s}\n  Confirm? (y/N): ", .{fmtSize(preview_total, &pb)}) catch {};

    var cbuf: [8]u8 = undefined;
    const craw = try stdin.readUntilDelimiterOrEof(&cbuf, '\n') orelse return selected;
    const confirm = mem.trim(u8, craw, " \t\r\n");
    if (!std.ascii.eqlIgnoreCase(confirm, "y") and !std.ascii.eqlIgnoreCase(confirm, "yes"))
        return selected;

    for (chosen.items) |idx| try selected.append(entries[idx].path);
    return selected;
}

// ── Spinner thread ────────────────────────────────────────────────────────────

const SpinCtx = struct {
    running: *std.atomic.Value(bool),
    count: *std.atomic.Value(u64),
    no_color: bool,
};

fn spinWorker(ctx: SpinCtx) void {
    const frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
    var f: usize = 0;
    const w = std.fs.File.stderr().deprecatedWriter();
    while (ctx.running.load(.monotonic)) {
        const c = ctx.count.load(.monotonic);
        if (!ctx.no_color) w.writeAll(ansi.cyan) catch {};
        w.print("\r  {s}  found {d}  ", .{ frames[f % frames.len], c }) catch {};
        if (!ctx.no_color) w.writeAll(ansi.reset) catch {};
        f += 1;
        std.Thread.sleep(80 * std.time.ns_per_ms);
    }
    w.writeAll("\r                              \r") catch {};
}

// ── Main ──────────────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var config = parseArgs(alloc) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.print("Argument error: {s}\nRun with --help for usage.\n", .{@errorName(err)}) catch {};
        std.process.exit(1);
    };
    defer config.extra_targets.deinit();

    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stderr = std.fs.File.stderr().deprecatedWriter();

    if (config.show_help) {
        try stdout.writeAll(help_text);
        try stdout.writeAll("\n");
        return;
    }

    // Resolve root
    const root_abs = fs.realpathAlloc(alloc, config.root) catch |err| {
        stderr.print("Cannot resolve '{s}': {s}\n", .{ config.root, @errorName(err) }) catch {};
        std.process.exit(1);
    };
    defer alloc.free(root_abs);

    {
        var probe = fs.openDirAbsolute(root_abs, .{}) catch {
            stderr.print("Not a directory: {s}\n", .{root_abs}) catch {};
            std.process.exit(1);
        };
        probe.close();
    }

    // Banner
    if (!config.no_color) try stdout.writeAll(ansi.bold_cyan);
    try stdout.writeAll("  mouser");
    if (!config.no_color) try stdout.writeAll(ansi.reset ++ ansi.dim);
    try stdout.print("  scanning {s}", .{root_abs});
    if (config.depth) |d| try stdout.print("  depth≤{d}", .{d});
    if (config.filter != .all) try stdout.print("  [{s}]", .{@tagName(config.filter)});
    if (config.no_size) try stdout.writeAll("  [no-size]");
    try stdout.writeAll("\n");
    if (!config.no_color) try stdout.writeAll(ansi.reset);

    // Scan
    var entries = ArrayList(Entry).init(alloc);
    defer {
        for (entries.items) |*e| alloc.free(e.path);
        entries.deinit();
    }

    var scan_mu = Mutex{};
    var found_count = std.atomic.Value(u64).init(0);
    const t0 = std.time.milliTimestamp();

    var spin_running = std.atomic.Value(bool).init(true);
    const spin_thread = try Thread.spawn(.{}, spinWorker, .{SpinCtx{
        .running = &spin_running,
        .count = &found_count,
        .no_color = config.no_color,
    }});

    try scanRoot(alloc, root_abs, &config, &entries, &scan_mu, &found_count);

    spin_running.store(false, .monotonic);
    spin_thread.join();

    const scan_ms = std.time.milliTimestamp() - t0;
    try stderr.print("  Scan: {d} dirs, {d}ms\n", .{ entries.items.len, scan_ms });

    // Parallel size calculation
    if (!config.no_size and entries.items.len > 0) {
        const t1 = std.time.milliTimestamp();
        try calcSizesParallel(alloc, entries.items, config.num_threads);
        try stderr.print("  Sizes: {d}ms\n", .{std.time.milliTimestamp() - t1});
    }

    // Apply post-filters
    {
        var i: usize = 0;
        while (i < entries.items.len) {
            const e = &entries.items[i];
            var remove = false;
            if (config.min_size > 0 and e.size_bytes < config.min_size) remove = true;
            if (config.older_than) |days| if (e.ageDays() < days) { remove = true; };
            if (remove) {
                alloc.free(e.path);
                _ = entries.swapRemove(i);
            } else i += 1;
        }
    }

    if (entries.items.len == 0) {
        try stdout.writeAll("\n  No matching directories found.\n");
        return;
    }

    // Sort
    if (config.sort_size) {
        mem.sort(Entry, entries.items, {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool { return a.size_bytes > b.size_bytes; }
        }.lt);
    } else if (config.sort_age) {
        mem.sort(Entry, entries.items, {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool { return a.mtime_ns < b.mtime_ns; }
        }.lt);
    } else {
        mem.sort(Entry, entries.items, {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool { return mem.lessThan(u8, a.path, b.path); }
        }.lt);
    }

    const total_bytes: u64 = blk: {
        var s: u64 = 0;
        for (entries.items) |*e| s += e.size_bytes;
        break :blk s;
    };

    // JSON mode
    if (config.json_out) {
        try writeJson(entries.items, stdout);
        return;
    }

    // Table
    try stdout.writeAll("\n");
    printTable(entries.items, &config, total_bytes);
    try stdout.writeAll("\n");

    // Export
    if (config.export_path) |ep| {
        exportFile(entries.items, ep) catch |err| {
            try stderr.print("  Export failed: {s}\n", .{@errorName(err)});
        };
        if (!config.no_color) try stdout.writeAll(ansi.bold_green);
        try stdout.print("  Exported → {s}\n\n", .{ep});
        if (!config.no_color) try stdout.writeAll(ansi.reset);
    }

    // Dry-run
    if (config.dry_run) {
        var tb: [32]u8 = undefined;
        if (!config.no_color) try stdout.writeAll(ansi.bold_yellow);
        try stdout.print("  [dry-run] would delete {d} dirs ({s})\n", .{
            entries.items.len, fmtSize(total_bytes, &tb),
        });
        if (!config.no_color) try stdout.writeAll(ansi.reset);
        return;
    }

    // Interactive / delete
    var to_delete = ArrayList([]const u8).init(alloc);
    defer to_delete.deinit();

    if (config.interactive) {
        to_delete = try interactiveSelect(alloc, entries.items, config.no_color);
    } else if (config.delete) {
        var tb: [32]u8 = undefined;
        try stdout.print("\n  Delete {d} dirs ({s})? Cannot be undone.\n  Confirm (y/N): ", .{
            entries.items.len, fmtSize(total_bytes, &tb),
        });
        var cbuf: [8]u8 = undefined;
        const craw = try std.fs.File.stdin().deprecatedReader().readUntilDelimiterOrEof(&cbuf, '\n') orelse return;
        const ci = mem.trim(u8, craw, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(ci, "y") or std.ascii.eqlIgnoreCase(ci, "yes")) {
            for (entries.items) |*e| try to_delete.append(e.path);
        }
    }

    if (to_delete.items.len > 0) {
        try stdout.print("\n  Deleting {d} dirs...\n", .{to_delete.items.len});
        const res = doDelete(to_delete.items, config.no_color);
        var fb: [32]u8 = undefined;
        try stdout.writeAll("\n");
        if (!config.no_color) try stdout.writeAll(ansi.bold_green);
        try stdout.print("  {d} deleted", .{res.ok});
        if (!config.no_color) try stdout.writeAll(ansi.reset);
        if (res.fail > 0) {
            if (!config.no_color) try stdout.writeAll(ansi.red);
            try stdout.print("  {d} failed", .{res.fail});
            if (!config.no_color) try stdout.writeAll(ansi.reset);
        }
        if (!config.no_color) try stdout.writeAll("  " ++ ansi.bold_yellow);
        try stdout.print("  {s} freed\n", .{fmtSize(res.freed, &fb)});
        if (!config.no_color) try stdout.writeAll(ansi.reset);
    } else if (config.delete or config.interactive) {
        try stdout.writeAll("  Nothing deleted.\n");
    }
}
