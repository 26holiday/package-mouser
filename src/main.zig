const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.array_list.Managed; // managed: init(alloc), append(item), deinit()
const Thread = std.Thread;
const Mutex = Thread.Mutex;

// ── Win32 FFI ─────────────────────────────────────────────────────────────────
const windows = std.os.windows;
const FILETIME = extern struct { low: u32, high: u32 };
const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes:   u32,
    ftCreationTime:     FILETIME,
    ftLastAccessTime:   FILETIME,
    ftLastWriteTime:    FILETIME,
    nFileSizeHigh:      u32,
    nFileSizeLow:       u32,
    dwReserved0:        u32,
    dwReserved1:        u32,
    cFileName:          [260]u16,
    cAlternateFileName: [14]u16,
};
const FILE_ATTRIBUTE_DIRECTORY:    u32 = 0x10;
const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
const FIND_FIRST_EX_LARGE_FETCH:   u32 = 0x2;

extern "kernel32" fn FindFirstFileExW(
    lpFileName:        [*:0]const u16,
    fInfoLevelId:      u32,   // 1 = FindExInfoBasic (no 8.3 names)
    lpFindFileData:    *WIN32_FIND_DATAW,
    fSearchOp:         u32,   // 0 = FindExSearchNameMatch
    lpSearchFilter:    ?*anyopaque,
    dwAdditionalFlags: u32,
) callconv(.winapi) windows.HANDLE;

extern "kernel32" fn FindNextFileW(
    hFindFile:     windows.HANDLE,
    lpFindFileData: *WIN32_FIND_DATAW,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn FindClose(
    hFindFile: windows.HANDLE,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn SetConsoleOutputCP(wCodePageID: u32) callconv(.winapi) windows.BOOL;
extern "kernel32" fn SetConsoleCP(wCodePageID: u32) callconv(.winapi) windows.BOOL;

// ── ANSI colors ───────────────────────────────────────────────────────────────

const ansi = struct {
    const reset        = "\x1b[0m";
    const bold         = "\x1b[1m";
    const dim          = "\x1b[2m";
    const underline    = "\x1b[4m";
    const red          = "\x1b[31m";
    const green        = "\x1b[32m";
    const yellow       = "\x1b[33m";
    const blue         = "\x1b[34m";
    const magenta      = "\x1b[35m";
    const cyan         = "\x1b[36m";
    const bold_red     = "\x1b[1;31m";
    const bold_yellow  = "\x1b[1;33m";
    const bold_cyan    = "\x1b[1;36m";
    const bold_green   = "\x1b[1;32m";
    const bold_white   = "\x1b[1;37m";
    const bold_magenta = "\x1b[1;35m";
    const bright_cyan  = "\x1b[96m";
    const bright_green = "\x1b[92m";
    const bright_red   = "\x1b[91m";
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

// Fast iterative dir size using FindFirstFileExW + FIND_FIRST_EX_LARGE_FETCH.
// Windows batches up to 64 KB of directory entries per kernel call instead of
// returning one entry at a time, cutting syscall overhead by ~10-50x on large dirs.
fn calcDirSize(alloc: Allocator, path: []const u8) u64 {
    var total: u64 = 0;
    var stack = ArrayList([]u8).init(alloc);
    defer {
        for (stack.items) |p| alloc.free(p);
        stack.deinit();
    }
    const root = alloc.dupe(u8, path) catch return 0;
    stack.append(root) catch { alloc.free(root); return 0; };

    var find_data: WIN32_FIND_DATAW = undefined;
    var wide_buf: [32768]u16 = undefined; // well above MAX_PATH

    while (stack.items.len > 0) {
        const cur = stack.pop().?;
        defer alloc.free(cur);

        // Build wide pattern: "<cur>\*\0"
        const enc_len = std.unicode.utf8ToUtf16Le(wide_buf[0 .. wide_buf.len - 3], cur) catch continue;
        wide_buf[enc_len]     = '\\';
        wide_buf[enc_len + 1] = '*';
        wide_buf[enc_len + 2] = 0;
        const pattern: [*:0]const u16 = @ptrCast(&wide_buf[0]);

        const handle = FindFirstFileExW(
            pattern,
            1,    // FindExInfoBasic — skip 8.3 names (faster)
            &find_data,
            0,    // FindExSearchNameMatch
            null,
            FIND_FIRST_EX_LARGE_FETCH, // <— the key flag: 64KB batching
        );
        if (handle == windows.INVALID_HANDLE_VALUE) continue;
        defer _ = FindClose(handle);

        while (true) {
            entry: {
                const nlen = mem.indexOfScalar(u16, &find_data.cFileName, 0) orelse 260;
                const wname = find_data.cFileName[0..nlen];

                // Skip . and ..
                const dot    = nlen == 1 and wname[0] == '.';
                const dotdot = nlen == 2 and wname[0] == '.' and wname[1] == '.';
                if (dot or dotdot) break :entry;

                const is_dir     = find_data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY    != 0;
                const is_reparse = find_data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0;

                if (is_dir and !is_reparse) {
                    // Convert wide name → UTF-8, build child path
                    var name_u8: [1024]u8 = undefined;
                    const u8_len = std.unicode.utf16LeToUtf8(&name_u8, wname) catch break :entry;
                    const child  = fs.path.join(alloc, &.{ cur, name_u8[0..u8_len] }) catch break :entry;
                    stack.append(child) catch alloc.free(child);
                } else if (!is_dir) {
                    // Direct file size from FIND_DATA — no extra stat() call needed
                    total += (@as(u64, find_data.nFileSizeHigh) << 32) | @as(u64, find_data.nFileSizeLow);
                }
                // else: reparse point (OneDrive stub, junction, AppX) — skip safely
            }
            if (FindNextFileW(handle, &find_data) == 0) break;
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
    num_threads: usize = 0, // 0 = auto (cpu count)
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
    // Always heap-allocate root so main can unconditionally free it
    config.root = try alloc.dupe(u8, ".");
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next(); // skip argv[0]

    var got_path = false;
    while (args.next()) |arg| {
        if (!got_path and arg.len > 0 and arg[0] != '-') {
            alloc.free(config.root); // free the default "." dupe before overwriting
            config.root = try alloc.dupe(u8, arg);
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
            const v = args.next() orelse return error.MissingValue;
            config.export_path = try alloc.dupe(u8, v);
        } else if (mem.eql(u8, arg, "-t") or mem.eql(u8, arg, "--threads")) {
            const v = args.next() orelse return error.MissingValue;
            config.num_threads = try std.fmt.parseInt(usize, v, 10);
        } else if (mem.eql(u8, arg, "--target")) {
            const v = args.next() orelse return error.MissingValue;
            var it = mem.splitScalar(u8, v, ',');
            while (it.next()) |t| {
                const trimmed = mem.trim(u8, t, " \t");
                if (trimmed.len > 0) try config.extra_targets.append(try alloc.dupe(u8, trimmed));
            }
        }
    }
    return config;
}

// ── Scanner ───────────────────────────────────────────────────────────────────

const skip_names = [_][]const u8{
    "System Volume Information", "$RECYCLE.BIN",
    "Windows",      "Program Files", "Program Files (x86)", "ProgramData",
    "AppData",      "__pycache__",   ".git",
    // Windows package/app stores — massive subtrees, no dependency dirs inside
    "Packages",     "WinGet",        "WindowsApps",
    "WinSxS",       "MicrosoftEdgeBackups",
};

// Extra path-suffix guards for when scan root IS inside AppData or reached via junction
const skip_path_suffixes = [_][]const u8{
    "\\AppData\\Local\\Packages",
    "\\AppData\\Local\\Microsoft\\WinGet",
    "\\AppData\\Local\\Microsoft\\WindowsApps",
    "\\AppData\\Roaming\\Microsoft",
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

// Shared state for parallel scanner workers
const ScanShared = struct {
    alloc:       Allocator,
    queue:       ArrayList(ScanItem),
    queue_mu:    Mutex,
    entries:     *ArrayList(Entry),
    entries_mu:  *Mutex,
    config:      *const Config,
    found_count: *std.atomic.Value(u64),
    // remaining = items currently in queue + items being actively processed
    // workers exit when remaining hits 0 (nothing left to do)
    remaining:   std.atomic.Value(i64),
};

fn scanWorker(shared: *ScanShared) void {
    while (true) {
        // Grab one item from the shared queue
        shared.queue_mu.lock();
        const item_opt: ?ScanItem = if (shared.queue.items.len > 0) shared.queue.pop().? else null;
        shared.queue_mu.unlock();

        if (item_opt == null) {
            // Queue empty — check if any other thread still has work
            if (shared.remaining.load(.seq_cst) <= 0) return;
            std.Thread.yield() catch {};
            continue;
        }

        const item = item_opt.?;
        defer shared.alloc.free(item.path);

        // Process item (match logic same as old scanRoot)
        processItem(shared, item);

        // Done with this item — decrement remaining
        _ = shared.remaining.fetchSub(1, .seq_cst);
    }
}

fn processItem(shared: *ScanShared, item: ScanItem) void {
    if (shared.config.depth) |max_d| if (item.depth > max_d) return;

    const name = fs.path.basename(item.path);
    if (name.len == 0 or shouldSkip(name)) return;

    // Path-suffix guard for Windows package stores reached via junction
    for (skip_path_suffixes) |sfx| {
        if (mem.endsWith(u8, item.path, sfx)) return;
    }

    var matched = false;

    // Check builtin targets
    for (builtin_targets) |t| {
        if (mem.eql(u8, name, t.name) and kindMatchesFilter(t.kind, shared.config.filter)) {
            const path_copy = shared.alloc.dupe(u8, item.path) catch return;
            const ent = Entry{
                .path = path_copy,
                .kind = t.kind,
                .custom_label = "",
                .size_bytes = 0,
                .mtime_ns = getDirMtime(item.path),
            };
            shared.entries_mu.lock();
            shared.entries.append(ent) catch { shared.alloc.free(path_copy); shared.entries_mu.unlock(); return; };
            shared.entries_mu.unlock();
            _ = shared.found_count.fetchAdd(1, .monotonic);
            matched = true;
            break;
        }
    }

    // Rust target/ detection
    if (!matched and mem.eql(u8, name, "target") and
        (shared.config.filter == .all or shared.config.filter == .rust))
    {
        const parent = fs.path.dirname(item.path) orelse "";
        if (parent.len > 0) {
            const cargo_path = fs.path.join(shared.alloc, &.{ parent, "Cargo.toml" }) catch null;
            if (cargo_path) |cp| {
                defer shared.alloc.free(cp);
                if (fs.accessAbsolute(cp, .{})) |_| {
                    const path_copy = shared.alloc.dupe(u8, item.path) catch return;
                    const ent = Entry{
                        .path = path_copy,
                        .kind = .rust_target,
                        .custom_label = "",
                        .size_bytes = 0,
                        .mtime_ns = getDirMtime(item.path),
                    };
                    shared.entries_mu.lock();
                    shared.entries.append(ent) catch { shared.alloc.free(path_copy); shared.entries_mu.unlock(); return; };
                    shared.entries_mu.unlock();
                    _ = shared.found_count.fetchAdd(1, .monotonic);
                    matched = true;
                } else |_| {}
            }
        }
    }

    // Custom targets
    if (!matched) {
        for (shared.config.extra_targets.items) |ct| {
            if (mem.eql(u8, name, ct)) {
                const path_copy = shared.alloc.dupe(u8, item.path) catch return;
                const ent = Entry{
                    .path = path_copy,
                    .kind = .custom,
                    .custom_label = ct,
                    .size_bytes = 0,
                    .mtime_ns = getDirMtime(item.path),
                };
                shared.entries_mu.lock();
                shared.entries.append(ent) catch { shared.alloc.free(path_copy); shared.entries_mu.unlock(); return; };
                shared.entries_mu.unlock();
                _ = shared.found_count.fetchAdd(1, .monotonic);
                matched = true;
                break;
            }
        }
    }

    if (matched) return;

    // Recurse into subdirs — push children BEFORE decrementing remaining
    var dir = fs.openDirAbsolute(item.path, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (true) {
        const maybe_de = it.next() catch break;
        const de = maybe_de orelse break;
        if (de.kind != .directory) continue;
        const child_path = fs.path.join(shared.alloc, &.{ item.path, de.name }) catch continue;
        const child = ScanItem{ .path = child_path, .depth = item.depth + 1 };
        // Increment remaining BEFORE pushing so workers see it immediately
        _ = shared.remaining.fetchAdd(1, .seq_cst);
        shared.queue_mu.lock();
        shared.queue.append(child) catch {
            shared.queue_mu.unlock();
            shared.alloc.free(child_path);
            _ = shared.remaining.fetchSub(1, .seq_cst);
            continue;
        };
        shared.queue_mu.unlock();
    }
}

// ── Parallel size calculation ─────────────────────────────────────────────────

const SizeCtx = struct {
    alloc:    Allocator,
    entries:  []Entry,
    next_idx: *std.atomic.Value(usize), // shared fetch-add counter — work-stealing
    done:     *std.atomic.Value(u64),
};

fn sizeWorker(ctx: SizeCtx) void {
    while (true) {
        const i = ctx.next_idx.fetchAdd(1, .monotonic);
        if (i >= ctx.entries.len) break;
        ctx.entries[i].size_bytes = calcDirSize(ctx.alloc, ctx.entries[i].path);
        _ = ctx.done.fetchAdd(1, .monotonic);
    }
}

fn calcSizesParallel(alloc: Allocator, entries: []Entry, num_threads: usize) !void {
    if (entries.len == 0) return;
    const n = @min(num_threads, entries.len);
    var next_idx = std.atomic.Value(usize).init(0);
    var done     = std.atomic.Value(u64).init(0);

    const threads = try alloc.alloc(Thread, n);
    defer alloc.free(threads);

    for (0..n) |i| {
        threads[i] = try Thread.spawn(.{}, sizeWorker, .{SizeCtx{
            .alloc    = alloc,
            .entries  = entries,
            .next_idx = &next_idx,
            .done     = &done,
        }});
    }

    // Progress bar
    const stderr = std.fs.File.stderr().deprecatedWriter();
    const total  = entries.len;
    const bar_w  = 28;
    while (done.load(.monotonic) < total) {
        const d   = done.load(.monotonic);
        const pct = if (total > 0) (d * 100) / total else 100;
        const filled = (pct * bar_w) / 100;
        stderr.writeAll("\r  ") catch {};
        for (0..bar_w) |b| {
            if (b < filled) stderr.writeAll("\x1b[92m█\x1b[0m") catch {}
            else             stderr.writeAll("\x1b[2m░\x1b[0m")  catch {};
        }
        stderr.print("  \x1b[1;37m{d}%\x1b[0m  \x1b[2m{d}/{d}\x1b[0m  ", .{ pct, d, total }) catch {};
        std.Thread.sleep(80 * std.time.ns_per_ms);
    }
    stderr.writeAll("\r" ++ " " ** 72 ++ "\r") catch {};

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
    max_path = @min(max_path, 60);

    // Col widths: type=max_kind  size=10  age=5  path=max_path
    const row_inner = max_kind + 2 + 10 + 2 + 5 + 2 + max_path; // spaces between cols

    // ── Box top ────────────────────────────────────────────────────────────────
    if (!nc) stdout.writeAll(ansi.dim) catch {};
    stdout.writeAll("  ╭") catch {};
    for (0..max_kind + 2) |_| stdout.writeAll("─") catch {};
    stdout.writeAll("┬") catch {};
    for (0..12) |_| stdout.writeAll("─") catch {};
    stdout.writeAll("┬") catch {};
    for (0..7) |_| stdout.writeAll("─") catch {};
    stdout.writeAll("┬") catch {};
    for (0..max_path + 2) |_| stdout.writeAll("─") catch {};
    stdout.writeAll("╮\n") catch {};
    if (!nc) stdout.writeAll(ansi.reset) catch {};

    // ── Header row ─────────────────────────────────────────────────────────────
    if (!nc) stdout.writeAll(ansi.bold_white) catch {};
    var hdr_buf: [64]u8 = undefined;
    var path_hdr_buf: [128]u8 = undefined;
    stdout.print("  │ {s} │ {s:>10} │ {s:>5} │ {s} │\n", .{
        padRight(&hdr_buf, "TYPE", max_kind),
        "SIZE", "DAYS",
        padRight(&path_hdr_buf, "PATH", max_path),
    }) catch {};
    if (!nc) stdout.writeAll(ansi.reset) catch {};

    // ── Header divider ─────────────────────────────────────────────────────────
    if (!nc) stdout.writeAll(ansi.dim) catch {};
    stdout.writeAll("  ├") catch {};
    for (0..max_kind + 2) |_| stdout.writeAll("─") catch {};
    stdout.writeAll("┼") catch {};
    for (0..12) |_| stdout.writeAll("─") catch {};
    stdout.writeAll("┼") catch {};
    for (0..7) |_| stdout.writeAll("─") catch {};
    stdout.writeAll("┼") catch {};
    for (0..max_path + 2) |_| stdout.writeAll("─") catch {};
    stdout.writeAll("┤\n") catch {};
    if (!nc) stdout.writeAll(ansi.reset) catch {};

    // ── Rows ───────────────────────────────────────────────────────────────────
    for (entries) |*e| {
        var sb: [32]u8 = undefined;
        var ab: [16]u8 = undefined;
        const size_s = e.sizeStr(&sb);
        const age_s  = std.fmt.bufPrint(&ab, "{d}", .{e.ageDays()}) catch "?";

        // Left-truncate long paths with ellipsis
        const path_disp = if (e.path.len > max_path)
            e.path[e.path.len - max_path + 1 ..]
        else
            e.path;
        const path_prefix: []const u8 = if (e.path.len > max_path) "…" else " ";

        const size_color: []const u8 = if (nc) "" else blk: {
            if (e.size_bytes > 1 << 30) break :blk ansi.bright_red;
            if (e.size_bytes > 100 << 20) break :blk ansi.bold_yellow;
            break :blk ansi.bright_green;
        };

        if (!nc) stdout.writeAll(ansi.dim) catch {};
        stdout.writeAll("  │ ") catch {};
        if (!nc) stdout.writeAll(ansi.reset) catch {};

        // Type column (colored)
        if (!nc) stdout.writeAll(e.kind.colorCode()) catch {};
        var kind_buf: [64]u8 = undefined;
        stdout.print("{s}", .{padRight(&kind_buf, e.kindLabel(), max_kind)}) catch {};
        if (!nc) stdout.writeAll(ansi.reset) catch {};

        if (!nc) stdout.writeAll(ansi.dim) catch {};
        stdout.writeAll(" │ ") catch {};
        if (!nc) stdout.writeAll(ansi.reset) catch {};

        // Size column
        if (!nc) stdout.writeAll(size_color) catch {};
        stdout.print("{s:>10}", .{size_s}) catch {};
        if (!nc) stdout.writeAll(ansi.reset) catch {};

        if (!nc) stdout.writeAll(ansi.dim) catch {};
        stdout.writeAll(" │ ") catch {};
        if (!nc) stdout.writeAll(ansi.reset) catch {};

        // Age column
        if (!nc) stdout.writeAll(ansi.dim) catch {};
        stdout.print("{s:>5}", .{age_s}) catch {};
        if (!nc) stdout.writeAll(ansi.reset) catch {};

        if (!nc) stdout.writeAll(ansi.dim) catch {};
        stdout.writeAll(" │ ") catch {};

        // Path column
        stdout.print("{s}{s}", .{ path_prefix, path_disp }) catch {};
        // Pad to max_path
        const printed = path_disp.len + 1; // +1 for prefix char
        if (printed < max_path) {
            for (0..max_path - printed) |_| stdout.writeAll(" ") catch {};
        }
        stdout.writeAll(" │\n") catch {};
        if (!nc) stdout.writeAll(ansi.reset) catch {};
    }

    // ── Box bottom ─────────────────────────────────────────────────────────────
    if (!nc) stdout.writeAll(ansi.dim) catch {};
    stdout.writeAll("  ╰") catch {};
    for (0..max_kind + 2) |_| stdout.writeAll("─") catch {};
    stdout.writeAll("┴") catch {};
    for (0..12) |_| stdout.writeAll("─") catch {};
    stdout.writeAll("┴") catch {};
    for (0..7) |_| stdout.writeAll("─") catch {};
    stdout.writeAll("┴") catch {};
    for (0..max_path + 2) |_| stdout.writeAll("─") catch {};
    stdout.writeAll("╯\n") catch {};
    if (!nc) stdout.writeAll(ansi.reset) catch {};

    // ── Summary panel ──────────────────────────────────────────────────────────
    var counts = [_]struct { label: []const u8, clr: []const u8, n: u32, b: u64 }{
        .{ .label = "Python venv", .clr = ansi.yellow,  .n = 0, .b = 0 },
        .{ .label = "Node / JS",   .clr = ansi.green,   .n = 0, .b = 0 },
        .{ .label = "Rust target", .clr = ansi.red,     .n = 0, .b = 0 },
        .{ .label = "Custom",      .clr = ansi.blue,    .n = 0, .b = 0 },
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

    const panel_w = row_inner + 4; // inner width of summary panel
    const summary_inner = 46;

    stdout.writeAll("\n") catch {};
    if (!nc) stdout.writeAll(ansi.bold_cyan) catch {};
    stdout.writeAll("  ╔") catch {};
    for (0..summary_inner) |_| stdout.writeAll("═") catch {};
    stdout.writeAll("╗\n") catch {};
    stdout.print("  ║  \x1b[1;37mSUMMARY\x1b[1;36m", .{}) catch {};
    for (0..summary_inner - 9) |_| stdout.writeAll(" ") catch {};
    stdout.writeAll("║\n") catch {};
    stdout.writeAll("  ╠") catch {};
    for (0..summary_inner) |_| stdout.writeAll("═") catch {};
    stdout.writeAll("╣\n") catch {};
    if (!nc) stdout.writeAll(ansi.reset) catch {};

    // summary_inner = 46 chars between ║ and ║.
    // Each row: "  " (2) + content + padding + "  " (2) = 46 → content+padding = 42
    const row_avail = summary_inner - 4;

    for (counts) |c| {
        if (c.n == 0) continue;
        var kb: [32]u8 = undefined;
        const size_str = fmtSize(c.b, &kb);
        const plural: []const u8 = if (c.n == 1) "" else "s";
        // Measure visible content: label(14) + "  ·  "(5) + digits + " dir"(4) + plural + "  ·  "(5) + size
        const n_digits: usize = if (c.n >= 1000) 4 else if (c.n >= 100) 3 else if (c.n >= 10) 2 else 1;
        const content_len = 14 + 5 + n_digits + 4 + plural.len + 5 + size_str.len;
        const pad = if (row_avail > content_len) row_avail - content_len else 0;

        if (!nc) stdout.writeAll(ansi.bold_cyan) catch {};
        stdout.writeAll("  ║  ") catch {};
        if (!nc) stdout.writeAll(c.clr) catch {};
        stdout.print("{s:<14}", .{c.label}) catch {};
        if (!nc) stdout.writeAll(ansi.dim) catch {};
        stdout.print("  ·  {d} dir{s}  ·  ", .{ c.n, plural }) catch {};
        if (!nc) stdout.writeAll(ansi.bold_yellow) catch {};
        stdout.print("{s}", .{size_str}) catch {};
        if (!nc) stdout.writeAll(ansi.reset) catch {};
        for (0..pad) |_| stdout.writeAll(" ") catch {};
        if (!nc) stdout.writeAll(ansi.bold_cyan) catch {};
        stdout.writeAll("  ║\n") catch {};
    }

    if (!nc) stdout.writeAll(ansi.bold_cyan) catch {};
    stdout.writeAll("  ╠") catch {};
    for (0..summary_inner) |_| stdout.writeAll("═") catch {};
    stdout.writeAll("╣\n") catch {};
    stdout.writeAll("  ║  ") catch {};
    if (!nc) stdout.writeAll(ansi.bold_white) catch {};
    var tb: [32]u8 = undefined;
    const total_str = fmtSize(total_bytes, &tb);
    stdout.print("TOTAL  ·  {d} dir{s}  ·  ", .{
        entries.len, if (entries.len == 1) "" else "s",
    }) catch {};
    if (!nc) stdout.writeAll(ansi.bold_yellow) catch {};
    stdout.print("{s}", .{total_str}) catch {};
    if (!nc) stdout.writeAll(ansi.dim) catch {};
    stdout.writeAll("  reclaimable") catch {};
    if (!nc) stdout.writeAll(ansi.reset) catch {};
    // "TOTAL  ·  " = 10, digits, " dir"(4), "s"/"", "  ·  "(5), size, "  reclaimable"(13)
    const t_plural: []const u8 = if (entries.len == 1) "" else "s";
    const t_digits: usize = if (entries.len >= 1000) 4 else if (entries.len >= 100) 3 else if (entries.len >= 10) 2 else 1;
    const t_content = 10 + t_digits + 4 + t_plural.len + 5 + total_str.len + 13;
    const t_pad = if (row_avail > t_content) row_avail - t_content else 0;
    for (0..t_pad) |_| stdout.writeAll(" ") catch {};
    if (!nc) stdout.writeAll(ansi.bold_cyan) catch {};
    stdout.writeAll("  ║\n") catch {};
    stdout.writeAll("  ╚") catch {};
    for (0..summary_inner) |_| stdout.writeAll("═") catch {};
    stdout.writeAll("╝\n") catch {};
    if (!nc) stdout.writeAll(ansi.reset) catch {};

    _ = panel_w; // suppress unused warning
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

    const picker_w: usize = 60;
    stdout.writeAll("\n") catch {};
    if (!no_color) stdout.writeAll(ansi.bold_cyan) catch {};
    stdout.writeAll("  ┌") catch {};
    for (0..picker_w) |_| stdout.writeAll("─") catch {};
    stdout.writeAll("┐\n") catch {};
    stdout.print("  │  \x1b[1;37mSELECT DIRECTORIES TO DELETE\x1b[1;36m", .{}) catch {};
    for (0..picker_w - 31) |_| stdout.writeAll(" ") catch {};
    stdout.writeAll("│\n") catch {};
    stdout.writeAll("  ├") catch {};
    for (0..picker_w) |_| stdout.writeAll("─") catch {};
    stdout.writeAll("┤\n") catch {};
    if (!no_color) stdout.writeAll(ansi.reset) catch {};

    for (entries, 1..) |*e, i| {
        var sb: [32]u8 = undefined;
        const size_s = e.sizeStr(&sb);
        if (!no_color) stdout.writeAll(ansi.bold_cyan) catch {};
        stdout.writeAll("  │ ") catch {};
        if (!no_color) stdout.writeAll(ansi.bold_white) catch {};
        stdout.print("{d:>3}  ", .{i}) catch {};
        if (!no_color) stdout.writeAll(e.kind.colorCode()) catch {};
        stdout.print("{s:<14} ", .{e.kindLabel()}) catch {};
        // size colored
        const sc: []const u8 = if (no_color) "" else if (e.size_bytes > 1 << 30) ansi.bright_red
            else if (e.size_bytes > 100 << 20) ansi.bold_yellow else ansi.bright_green;
        if (!no_color) stdout.writeAll(sc) catch {};
        stdout.print("{s:>10}  ", .{size_s}) catch {};
        if (!no_color) stdout.writeAll(ansi.dim) catch {};
        const path_max = picker_w - 33;
        const path_disp = if (e.path.len > path_max) e.path[e.path.len - path_max..] else e.path;
        stdout.print("{s}", .{path_disp}) catch {};
        // pad
        if (path_disp.len < path_max) for (0..path_max - path_disp.len) |_| stdout.writeAll(" ") catch {};
        if (!no_color) stdout.writeAll(ansi.reset ++ ansi.bold_cyan) catch {};
        stdout.writeAll(" │\n") catch {};
    }
    if (!no_color) stdout.writeAll(ansi.bold_cyan) catch {};
    stdout.writeAll("  └") catch {};
    for (0..picker_w) |_| stdout.writeAll("─") catch {};
    stdout.writeAll("┘\n") catch {};
    if (!no_color) stdout.writeAll(ansi.reset) catch {};

    if (!no_color) stdout.writeAll(ansi.dim) catch {};
    stdout.writeAll("  enter: 1,3  │  2-5  │  all  │  blank=cancel\n") catch {};
    if (!no_color) stdout.writeAll(ansi.reset ++ ansi.bold_cyan) catch {};
    stdout.writeAll("  ❯ ") catch {};
    if (!no_color) stdout.writeAll(ansi.reset) catch {};

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
    running:  *std.atomic.Value(bool),
    count:    *std.atomic.Value(u64),
    no_color: bool,
};

fn spinWorker(ctx: SpinCtx) void {
    const frames = [_]u8{ '|', '/', '-', '\\' }; // ASCII — works in every font/terminal
    var f: usize = 0;
    const w = std.fs.File.stderr().deprecatedWriter();
    while (ctx.running.load(.monotonic)) {
        const c = ctx.count.load(.monotonic);
        if (!ctx.no_color) {
            w.print("\r  \x1b[1;36m{c}\x1b[0m  \x1b[2mscanning\x1b[0m  \x1b[1;33m{d} found\x1b[0m   ", .{ frames[f % frames.len], c }) catch {};
        } else {
            w.print("\r  {c}  scanning  {d} found   ", .{ frames[f % frames.len], c }) catch {};
        }
        f += 1;
        std.Thread.sleep(80 * std.time.ns_per_ms);
    }
    w.writeAll("\r" ++ " " ** 60 ++ "\r") catch {};
}

// ── Main ──────────────────────────────────────────────────────────────────────

pub fn main() !void {
    // Set Windows console to UTF-8 so box-drawing and other Unicode renders correctly
    _ = SetConsoleOutputCP(65001);
    _ = SetConsoleCP(65001);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var config = parseArgs(alloc) catch |err| {
        const stderr = std.fs.File.stderr().deprecatedWriter();
        stderr.print("Argument error: {s}\nRun with --help for usage.\n", .{@errorName(err)}) catch {};
        std.process.exit(1);
    };
    defer {
        alloc.free(config.root);
        if (config.export_path) |ep| alloc.free(ep);
        for (config.extra_targets.items) |t| alloc.free(t);
        config.extra_targets.deinit();
    }

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

    // Auto thread count
    if (config.num_threads == 0) {
        config.num_threads = std.Thread.getCpuCount() catch 4;
    }

    // Banner
    if (!config.no_color) {
        try stdout.writeAll("\n  \x1b[1;36m╔══════════════════════════════════════╗\x1b[0m\n");
        try stdout.writeAll("  \x1b[1;36m║\x1b[0m  \x1b[1;37m░▒▓ \x1b[1;96mMOUSER\x1b[0m\x1b[1;37m ▓▒░\x1b[0m\x1b[2m  v1.0  dependency reclaimer  \x1b[0m\x1b[1;36m║\x1b[0m\n");
        try stdout.writeAll("  \x1b[1;36m╚══════════════════════════════════════╝\x1b[0m\n\n");
        try stdout.writeAll(ansi.dim);
    } else {
        try stdout.writeAll("\n  ╔══════════════════════════════════════╗\n");
        try stdout.writeAll("  ║  MOUSER v1.0  dependency reclaimer  ║\n");
        try stdout.writeAll("  ╚══════════════════════════════════════╝\n\n");
    }
    try stdout.print("  scanning  {s}", .{root_abs});
    if (!config.no_color) try stdout.writeAll(ansi.reset);
    if (config.depth) |d| try stdout.print("  depth≤{d}", .{d});
    if (config.filter != .all) try stdout.print("  filter:{s}", .{@tagName(config.filter)});
    if (config.no_size) try stdout.writeAll("  no-size");
    try stdout.print("  threads:{d}", .{config.num_threads});
    try stdout.writeAll("\n\n");

    // Scan — parallel work-stealing scanner
    var entries = ArrayList(Entry).init(alloc);
    defer {
        for (entries.items) |*e| alloc.free(e.path);
        entries.deinit();
    }

    var entries_mu = Mutex{};
    var found_count = std.atomic.Value(u64).init(0);
    const t0 = std.time.milliTimestamp();

    var spin_running = std.atomic.Value(bool).init(true);
    const spin_thread = try Thread.spawn(.{}, spinWorker, .{SpinCtx{
        .running  = &spin_running,
        .count    = &found_count,
        .no_color = config.no_color,
    }});

    {
        // Root item starts with remaining=1
        const root_copy = try alloc.dupe(u8, root_abs);
        var shared = ScanShared{
            .alloc       = alloc,
            .queue       = ArrayList(ScanItem).init(alloc),
            .queue_mu    = Mutex{},
            .entries     = &entries,
            .entries_mu  = &entries_mu,
            .config      = &config,
            .found_count = &found_count,
            .remaining   = std.atomic.Value(i64).init(1),
        };
        defer {
            for (shared.queue.items) |item| alloc.free(item.path);
            shared.queue.deinit();
        }
        try shared.queue.append(.{ .path = root_copy, .depth = 0 });

        const n_scan = config.num_threads;
        const scan_threads = try alloc.alloc(Thread, n_scan);
        defer alloc.free(scan_threads);
        for (0..n_scan) |i| {
            scan_threads[i] = try Thread.spawn(.{}, scanWorker, .{&shared});
        }
        for (scan_threads) |t| t.join();
    }

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
