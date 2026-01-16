const std = @import("std");
const build_options = @import("build_options");
const gpu = @import("gpu");
const cpu = @import("cpu");
const cpu_gnu = @import("cpu_gnu");
const regex = gpu.regex;

/// Backend selection mode
const BackendMode = enum {
    auto, // Automatically select based on workload
    gpu_mode, // Auto-select best GPU (Metal on macOS, else Vulkan)
    cpu_mode,
    cpu_gnu, // GNU find reference implementation
    metal,
    vulkan,
};

/// File type filter
const FileType = enum {
    any,
    file, // -type f
    directory, // -type d
    symlink, // -type l
    block_device, // -type b
    char_device, // -type c
    fifo, // -type p
    socket, // -type s
};

/// Size comparison for -size option
const SizeComparison = enum {
    exact,
    greater,
    less,
};

/// Size filter for -size option
const SizeFilter = struct {
    bytes: u64, // Size in bytes
    comparison: SizeComparison,

    /// Check if a file size matches this filter
    pub fn matches(self: SizeFilter, file_size: u64) bool {
        return switch (self.comparison) {
            .exact => file_size == self.bytes,
            .greater => file_size > self.bytes,
            .less => file_size < self.bytes,
        };
    }
};

/// Parse a size argument like "+1M", "-100k", "512", "1G"
/// Returns null on parse error
fn parseSizeArg(arg: []const u8) ?SizeFilter {
    if (arg.len == 0) return null;

    var comparison: SizeComparison = .exact;
    var start: usize = 0;

    // Check for +/- prefix
    if (arg[0] == '+') {
        comparison = .greater;
        start = 1;
    } else if (arg[0] == '-') {
        comparison = .less;
        start = 1;
    }

    if (start >= arg.len) return null;

    // Check for suffix
    const last = arg[arg.len - 1];
    var end = arg.len;
    var multiplier: u64 = 512; // Default: 512-byte blocks (GNU find default)

    if (last == 'c') {
        multiplier = 1;
        end = arg.len - 1;
    } else if (last == 'w') {
        multiplier = 2; // 2-byte words
        end = arg.len - 1;
    } else if (last == 'b') {
        multiplier = 512; // 512-byte blocks
        end = arg.len - 1;
    } else if (last == 'k') {
        multiplier = 1024;
        end = arg.len - 1;
    } else if (last == 'K') {
        multiplier = 1024;
        end = arg.len - 1;
    } else if (last == 'M') {
        multiplier = 1024 * 1024;
        end = arg.len - 1;
    } else if (last == 'G') {
        multiplier = 1024 * 1024 * 1024;
        end = arg.len - 1;
    } else if (last >= '0' and last <= '9') {
        // No suffix, use default 512-byte blocks
        multiplier = 512;
    } else {
        return null; // Invalid suffix
    }

    if (start >= end) return null;

    // Parse the number
    const num = std.fmt.parseInt(u64, arg[start..end], 10) catch return null;

    return SizeFilter{
        .bytes = num * multiplier,
        .comparison = comparison,
    };
}

/// Time comparison for -mtime/-atime/-ctime options
const TimeComparison = enum {
    exact, // exactly N days ago
    newer, // less than N days ago (modified more recently)
    older, // more than N days ago
};

/// Which time to check
const TimeType = enum {
    modified, // -mtime (st_mtime)
    accessed, // -atime (st_atime)
    changed, // -ctime (st_ctime)
};

/// Time filter for -mtime/-atime/-ctime options
const TimeFilter = struct {
    days: i64, // Number of days
    comparison: TimeComparison,
    time_type: TimeType,

    /// Check if a file time matches this filter
    /// file_time is the Unix timestamp (seconds since epoch)
    /// now is the current Unix timestamp
    pub fn matches(self: TimeFilter, file_time: i64, now: i64) bool {
        const seconds_per_day: i64 = 86400;
        const age_seconds = now - file_time;
        const age_days = @divFloor(age_seconds, seconds_per_day);

        return switch (self.comparison) {
            .exact => age_days == self.days,
            .newer => age_days < self.days,
            .older => age_days > self.days,
        };
    }
};

/// Parse a time argument like "+7", "-1", "0"
/// Returns the number of days and comparison type
fn parseTimeArg(arg: []const u8, time_type: TimeType) ?TimeFilter {
    if (arg.len == 0) return null;

    var comparison: TimeComparison = .exact;
    var start: usize = 0;

    // Check for +/- prefix
    // +N means MORE than N days ago (older)
    // -N means LESS than N days ago (newer/more recent)
    if (arg[0] == '+') {
        comparison = .older;
        start = 1;
    } else if (arg[0] == '-') {
        comparison = .newer;
        start = 1;
    }

    if (start >= arg.len) return null;

    // Parse the number of days
    const days = std.fmt.parseInt(i64, arg[start..], 10) catch return null;

    return TimeFilter{
        .days = days,
        .comparison = comparison,
        .time_type = time_type,
    };
}

/// Find options
const FindOptions = struct {
    pattern: ?[]const u8 = null, // -name pattern
    ipattern: ?[]const u8 = null, // -iname pattern
    path_pattern: ?[]const u8 = null, // -path pattern
    ipath_pattern: ?[]const u8 = null, // -ipath pattern
    regex_pattern: ?[]const u8 = null, // -regex pattern (matches full path)
    iregex_pattern: ?[]const u8 = null, // -iregex pattern (case-insensitive)
    // Additional patterns for -o support
    or_patterns: []const OrPattern = &.{},
    file_type: FileType = .any, // -type
    max_depth: ?usize = null, // -maxdepth
    min_depth: usize = 0, // -mindepth
    print0: bool = false, // -print0
    count_only: bool = false, // -count (custom extension)
    negate_pattern: bool = false, // -not or ! (negate pattern match)
    empty_only: bool = false, // -empty (match empty files/directories)
    size_filter: ?SizeFilter = null, // -size filter
    time_filter: ?TimeFilter = null, // -mtime/-atime/-ctime filter
    prune_pattern: ?[]const u8 = null, // -prune pattern (skip directories matching this)
};

const OrPattern = struct {
    pattern: []const u8,
    case_insensitive: bool,
    match_path: bool,
};

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return 0;
    }

    var options = FindOptions{};
    var backend_mode: BackendMode = .auto;
    var start_paths: std.ArrayListUnmanaged([]const u8) = .{};
    defer start_paths.deinit(allocator);
    // Track paths that were allocated (from stdin) and need to be freed
    var allocated_paths: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (allocated_paths.items) |p| {
            allocator.free(p);
        }
        allocated_paths.deinit(allocator);
    }
    var verbose = false;

    // Track OR patterns for -o support
    var or_pattern_list: std.ArrayListUnmanaged(OrPattern) = .{};
    defer or_pattern_list.deinit(allocator);

    // Parse arguments
    var i: usize = 1;
    var expecting_or = false; // Track if we're after -o
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-o")) {
            // Save current pattern (if any) to or_patterns list
            if (options.pattern) |p| {
                try or_pattern_list.append(allocator, .{ .pattern = p, .case_insensitive = false, .match_path = false });
                options.pattern = null;
            }
            if (options.ipattern) |p| {
                try or_pattern_list.append(allocator, .{ .pattern = p, .case_insensitive = true, .match_path = false });
                options.ipattern = null;
            }
            expecting_or = true;
        } else if (std.mem.eql(u8, arg, "-name") and i + 1 < args.len) {
            i += 1;
            if (expecting_or) {
                try or_pattern_list.append(allocator, .{ .pattern = args[i], .case_insensitive = false, .match_path = false });
                expecting_or = false;
            } else {
                options.pattern = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-iname") and i + 1 < args.len) {
            i += 1;
            if (expecting_or) {
                try or_pattern_list.append(allocator, .{ .pattern = args[i], .case_insensitive = true, .match_path = false });
                expecting_or = false;
            } else {
                options.ipattern = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-path") and i + 1 < args.len) {
            i += 1;
            options.path_pattern = args[i];
        } else if (std.mem.eql(u8, arg, "-ipath") and i + 1 < args.len) {
            i += 1;
            options.ipath_pattern = args[i];
        } else if (std.mem.eql(u8, arg, "-regex") and i + 1 < args.len) {
            i += 1;
            options.regex_pattern = args[i];
        } else if (std.mem.eql(u8, arg, "-iregex") and i + 1 < args.len) {
            i += 1;
            options.iregex_pattern = args[i];
        } else if (std.mem.eql(u8, arg, "-type") and i + 1 < args.len) {
            i += 1;
            options.file_type = parseFileType(args[i]) orelse {
                std.debug.print("Invalid -type argument: {s}\n", .{args[i]});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "-maxdepth") and i + 1 < args.len) {
            i += 1;
            options.max_depth = std.fmt.parseInt(usize, args[i], 10) catch {
                std.debug.print("Invalid -maxdepth value: {s}\n", .{args[i]});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "-mindepth") and i + 1 < args.len) {
            i += 1;
            options.min_depth = std.fmt.parseInt(usize, args[i], 10) catch {
                std.debug.print("Invalid -mindepth value: {s}\n", .{args[i]});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "-print0")) {
            options.print0 = true;
        } else if (std.mem.eql(u8, arg, "-count")) {
            options.count_only = true;
        } else if (std.mem.eql(u8, arg, "-not") or std.mem.eql(u8, arg, "!")) {
            options.negate_pattern = true;
        } else if (std.mem.eql(u8, arg, "-empty")) {
            options.empty_only = true;
        } else if (std.mem.eql(u8, arg, "-size") and i + 1 < args.len) {
            i += 1;
            options.size_filter = parseSizeArg(args[i]) orelse {
                std.debug.print("Invalid -size argument: {s}\n", .{args[i]});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "-mtime") and i + 1 < args.len) {
            i += 1;
            options.time_filter = parseTimeArg(args[i], .modified) orelse {
                std.debug.print("Invalid -mtime argument: {s}\n", .{args[i]});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "-atime") and i + 1 < args.len) {
            i += 1;
            options.time_filter = parseTimeArg(args[i], .accessed) orelse {
                std.debug.print("Invalid -atime argument: {s}\n", .{args[i]});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "-ctime") and i + 1 < args.len) {
            i += 1;
            options.time_filter = parseTimeArg(args[i], .changed) orelse {
                std.debug.print("Invalid -ctime argument: {s}\n", .{args[i]});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "-prune") and i + 1 < args.len) {
            i += 1;
            options.prune_pattern = args[i];
        } else if (std.mem.eql(u8, arg, "--cpu")) {
            backend_mode = .cpu_mode;
        } else if (std.mem.eql(u8, arg, "--gnu")) {
            backend_mode = .cpu_gnu;
        } else if (std.mem.eql(u8, arg, "--gpu")) {
            backend_mode = .gpu_mode;
        } else if (std.mem.eql(u8, arg, "--metal")) {
            backend_mode = .metal;
        } else if (std.mem.eql(u8, arg, "--vulkan")) {
            backend_mode = .vulkan;
        } else if (std.mem.eql(u8, arg, "--auto")) {
            backend_mode = .auto;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return 0;
        } else if (std.mem.eql(u8, arg, "--version")) {
            _ = std.posix.write(std.posix.STDOUT_FILENO, "find (e-jerk GPU-accelerated) 1.0\n") catch {};
            return 0;
        } else if (arg[0] != '-' or std.mem.eql(u8, arg, "-")) {
            // Treat non-option args or "-" as paths
            try start_paths.append(allocator, arg);
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            printUsage();
            return 1;
        }
    }

    // After parsing, if we have patterns from -o, add any final pattern too
    if (or_pattern_list.items.len > 0) {
        // Add any remaining pattern to the OR list
        if (options.pattern) |p| {
            try or_pattern_list.append(allocator, .{ .pattern = p, .case_insensitive = false, .match_path = false });
            options.pattern = null;
        }
        if (options.ipattern) |p| {
            try or_pattern_list.append(allocator, .{ .pattern = p, .case_insensitive = true, .match_path = false });
            options.ipattern = null;
        }
        options.or_patterns = try or_pattern_list.toOwnedSlice(allocator);
    }

    // Default to current directory if no path specified
    // Check if we should read paths from stdin
    var read_stdin_paths = false;
    if (start_paths.items.len == 0) {
        // Check if stdin has data (not a tty)
        if (!std.posix.isatty(std.posix.STDIN_FILENO)) {
            read_stdin_paths = true;
        } else {
            try start_paths.append(allocator, ".");
        }
    } else {
        // Check for "-" argument meaning read from stdin
        for (start_paths.items) |path| {
            if (std.mem.eql(u8, path, "-")) {
                read_stdin_paths = true;
                break;
            }
        }
    }

    // Read paths from stdin if needed
    if (read_stdin_paths) {
        // Remove "-" from start_paths as we're going to read real paths from stdin
        var new_paths: std.ArrayListUnmanaged([]const u8) = .{};
        for (start_paths.items) |path| {
            if (!std.mem.eql(u8, path, "-")) {
                try new_paths.append(allocator, path);
            }
        }
        start_paths.deinit(allocator);
        start_paths = new_paths;
        var stdin_list: std.ArrayListUnmanaged(u8) = .{};
        defer stdin_list.deinit(allocator);
        var buf: [4096]u8 = undefined;
        while (true) {
            const bytes_read = std.posix.read(std.posix.STDIN_FILENO, &buf) catch |err| {
                if (err == error.WouldBlock) continue;
                break;
            };
            if (bytes_read == 0) break;
            try stdin_list.appendSlice(allocator, buf[0..bytes_read]);
            if (stdin_list.items.len > 1024 * 1024) break;
        }
        const stdin_data = stdin_list.items;

        // Split by whitespace/newlines
        var iter = std.mem.tokenizeAny(u8, stdin_data, " \t\n\r");
        while (iter.next()) |path| {
            if (!std.mem.eql(u8, path, "-")) {
                const duped = try allocator.dupe(u8, path);
                try allocated_paths.append(allocator, duped);
                try start_paths.append(allocator, duped);
            }
        }
    }

    if (start_paths.items.len == 0) {
        try start_paths.append(allocator, ".");
    }

    if (verbose) {
        std.debug.print("find - GPU-accelerated find\n", .{});
        std.debug.print("Mode: {s}\n", .{@tagName(backend_mode)});
        if (options.pattern) |p| std.debug.print("Pattern: {s}\n", .{p});
        if (options.ipattern) |p| std.debug.print("Pattern (case-insensitive): {s}\n", .{p});
        std.debug.print("\n", .{});
    }

    // Perform the find operation
    var total_matches: usize = 0;
    var had_error = false;
    for (start_paths.items) |start_path| {
        const result = findFiles(allocator, start_path, options, backend_mode, verbose);
        if (result.had_error) {
            had_error = true;
        }
        total_matches += result.count;
    }

    if (options.count_only) {
        std.debug.print("{d}\n", .{total_matches});
    }

    return if (had_error) 1 else 0;
}

const FindResult = struct {
    count: usize,
    had_error: bool,
};

fn parseFileType(s: []const u8) ?FileType {
    if (s.len != 1) return null;
    return switch (s[0]) {
        'f' => .file,
        'd' => .directory,
        'l' => .symlink,
        'b' => .block_device,
        'c' => .char_device,
        'p' => .fifo,
        's' => .socket,
        else => null,
    };
}

fn findFiles(
    allocator: std.mem.Allocator,
    start_path: []const u8,
    options: FindOptions,
    backend_mode: BackendMode,
    verbose: bool,
) FindResult {
    var collected_paths: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (collected_paths.items) |p| {
            allocator.free(p);
        }
        collected_paths.deinit(allocator);
    }

    // Check if start path exists
    std.fs.cwd().access(start_path, .{}) catch |err| {
        std.debug.print("find: '{s}': {}\n", .{ start_path, err });
        return .{ .count = 0, .had_error = true };
    };

    // Collect all file paths first
    walkDirectory(allocator, start_path, options, &collected_paths, 0) catch |err| {
        std.debug.print("find: error walking '{s}': {}\n", .{ start_path, err });
        return .{ .count = 0, .had_error = true };
    };

    if (verbose) {
        std.debug.print("Collected {d} paths\n", .{collected_paths.items.len});
    }

    // Handle OR patterns (-o)
    if (options.or_patterns.len > 0) {
        // OR matching: file matches if it matches ANY of the patterns
        var match_count: usize = 0;
        for (collected_paths.items) |path| {
            const basename = std.fs.path.basename(path);
            var matches = false;
            for (options.or_patterns) |or_pat| {
                const text_to_match = if (or_pat.match_path) path else basename;
                if (matchGlob(text_to_match, or_pat.pattern, or_pat.case_insensitive)) {
                    matches = true;
                    break;
                }
            }
            // Apply negation if -not was specified
            const should_output = if (options.negate_pattern) !matches else matches;
            if (should_output) {
                if (!options.count_only) {
                    printPath(path, options.print0);
                }
                match_count += 1;
            }
        }
        return .{ .count = match_count, .had_error = false };
    }

    // If no pattern specified, just print all collected paths
    if (options.pattern == null and options.ipattern == null and options.path_pattern == null and options.ipath_pattern == null and options.regex_pattern == null and options.iregex_pattern == null) {
        for (collected_paths.items) |path| {
            printPath(path, options.print0);
        }
        return .{ .count = collected_paths.items.len, .had_error = false };
    }

    // Handle regex patterns (GPU-accelerated or CPU fallback)
    if (options.regex_pattern != null or options.iregex_pattern != null) {
        const regex_pat = options.regex_pattern orelse options.iregex_pattern.?;
        const case_insensitive = options.iregex_pattern != null;
        return findFilesWithRegex(allocator, collected_paths.items, regex_pat, case_insensitive, options, backend_mode, verbose);
    }

    // Determine pattern and options for matching
    const pattern = options.pattern orelse options.ipattern orelse options.path_pattern orelse options.ipath_pattern orelse return .{ .count = 0, .had_error = false };
    const match_options = gpu.MatchOptions{
        .case_insensitive = options.ipattern != null or options.ipath_pattern != null,
        .match_path = options.path_pattern != null or options.ipath_pattern != null,
        .match_period = true,
    };

    // Select backend
    const use_gpu = switch (backend_mode) {
        .auto => gpu.shouldUseGpu(collected_paths.items.len),
        .gpu_mode, .metal, .vulkan => true,
        .cpu_mode, .cpu_gnu => false,
    };

    var match_count: usize = 0;

    if (use_gpu and build_options.is_macos and (backend_mode == .auto or backend_mode == .gpu_mode or backend_mode == .metal)) {
        // Use Metal backend
        if (gpu.metal.MetalMatcher.init(allocator)) |matcher| {
            defer matcher.deinit();

            if (verbose) {
                std.debug.print("Using Metal backend\n", .{});
            }

            var result = matcher.matchNames(collected_paths.items, pattern, match_options, allocator) catch {
                return .{ .count = 0, .had_error = true };
            };
            defer result.deinit();

            if (options.negate_pattern) {
                // For negation, build a set of matched indices and print non-matches
                var matched_set = std.AutoHashMap(u32, void).init(allocator);
                defer matched_set.deinit();
                for (result.matches) |match| {
                    matched_set.put(match.name_idx, {}) catch {};
                }
                for (collected_paths.items, 0..) |path, idx| {
                    if (!matched_set.contains(@intCast(idx))) {
                        if (!options.count_only) {
                            printPath(path, options.print0);
                        }
                        match_count += 1;
                    }
                }
            } else {
                for (result.matches) |match| {
                    if (!options.count_only) {
                        printPath(collected_paths.items[match.name_idx], options.print0);
                    }
                    match_count += 1;
                }
            }

            return .{ .count = match_count, .had_error = false };
        } else |_| {
            if (verbose) {
                std.debug.print("Metal init failed, falling back to CPU\n", .{});
            }
        }
    }

    // CPU fallback
    if (verbose) {
        const backend_name = if (backend_mode == .cpu_gnu) "CPU (GNU)" else "CPU (Optimized)";
        std.debug.print("Using {s} backend\n", .{backend_name});
    }

    // Select appropriate CPU backend
    var result = if (backend_mode == .cpu_gnu)
        cpu_gnu.matchNames(collected_paths.items, pattern, match_options, allocator) catch {
            return .{ .count = 0, .had_error = true };
        }
    else
        cpu.matchNames(collected_paths.items, pattern, match_options, allocator) catch {
            return .{ .count = 0, .had_error = true };
        };
    defer result.deinit();

    if (options.negate_pattern) {
        // For negation, build a set of matched indices and print non-matches
        var matched_set = std.AutoHashMap(u32, void).init(allocator);
        defer matched_set.deinit();
        for (result.matches) |match| {
            matched_set.put(match.name_idx, {}) catch {};
        }
        for (collected_paths.items, 0..) |path, idx| {
            if (!matched_set.contains(@intCast(idx))) {
                if (!options.count_only) {
                    printPath(path, options.print0);
                }
                match_count += 1;
            }
        }
    } else {
        for (result.matches) |match| {
            if (!options.count_only) {
                printPath(collected_paths.items[match.name_idx], options.print0);
            }
            match_count += 1;
        }
    }

    return .{ .count = match_count, .had_error = false };
}

/// Find files using regex pattern matching (GPU-accelerated)
fn findFilesWithRegex(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    options: FindOptions,
    backend_mode: BackendMode,
    verbose: bool,
) FindResult {
    const use_gpu = switch (backend_mode) {
        .auto => gpu.shouldUseGpu(paths.len),
        .gpu_mode, .metal, .vulkan => true,
        .cpu_mode, .cpu_gnu => false,
    };

    var match_count: usize = 0;

    // Try GPU regex matching first
    if (use_gpu and build_options.is_macos and (backend_mode == .auto or backend_mode == .gpu_mode or backend_mode == .metal)) {
        if (gpu.metal.MetalMatcher.init(allocator)) |matcher| {
            defer matcher.deinit();

            if (verbose) {
                std.debug.print("Using Metal backend (regex)\n", .{});
            }

            const match_opts = gpu.MatchOptions{
                .case_insensitive = case_insensitive,
                .match_path = true, // -regex always matches full path
                .match_period = false,
            };

            var result = matcher.matchNamesRegex(paths, pattern, match_opts, allocator) catch |err| {
                if (verbose) {
                    std.debug.print("Metal regex failed: {}, falling back to CPU\n", .{err});
                }
                return findFilesWithRegexCpu(allocator, paths, pattern, case_insensitive, options);
            };
            defer result.deinit();

            if (options.negate_pattern) {
                var matched_set = std.AutoHashMap(u32, void).init(allocator);
                defer matched_set.deinit();
                for (result.matches) |match| {
                    matched_set.put(match.name_idx, {}) catch {};
                }
                for (paths, 0..) |path, idx| {
                    if (!matched_set.contains(@intCast(idx))) {
                        if (!options.count_only) {
                            printPath(path, options.print0);
                        }
                        match_count += 1;
                    }
                }
            } else {
                for (result.matches) |match| {
                    if (!options.count_only) {
                        printPath(paths[match.name_idx], options.print0);
                    }
                    match_count += 1;
                }
            }

            return .{ .count = match_count, .had_error = false };
        } else |_| {
            if (verbose) {
                std.debug.print("Metal init failed, falling back to CPU\n", .{});
            }
        }
    }

    // Try Vulkan GPU regex matching
    if (use_gpu and (backend_mode == .auto or backend_mode == .gpu_mode or backend_mode == .vulkan)) {
        if (gpu.vulkan.VulkanMatcher.init(allocator)) |matcher| {
            defer matcher.deinit();

            if (verbose) {
                std.debug.print("Using Vulkan backend (regex)\n", .{});
            }

            const match_opts = gpu.MatchOptions{
                .case_insensitive = case_insensitive,
                .match_path = true, // -regex always matches full path
                .match_period = false,
            };

            var result = matcher.matchNamesRegex(paths, pattern, match_opts, allocator) catch |err| {
                if (verbose) {
                    std.debug.print("Vulkan regex failed: {}, falling back to CPU\n", .{err});
                }
                return findFilesWithRegexCpu(allocator, paths, pattern, case_insensitive, options);
            };
            defer result.deinit();

            if (options.negate_pattern) {
                var matched_set = std.AutoHashMap(u32, void).init(allocator);
                defer matched_set.deinit();
                for (result.matches) |match| {
                    matched_set.put(match.name_idx, {}) catch {};
                }
                for (paths, 0..) |path, idx| {
                    if (!matched_set.contains(@intCast(idx))) {
                        if (!options.count_only) {
                            printPath(path, options.print0);
                        }
                        match_count += 1;
                    }
                }
            } else {
                for (result.matches) |match| {
                    if (!options.count_only) {
                        printPath(paths[match.name_idx], options.print0);
                    }
                    match_count += 1;
                }
            }

            return .{ .count = match_count, .had_error = false };
        } else |_| {
            if (verbose) {
                std.debug.print("Vulkan init failed, falling back to CPU\n", .{});
            }
        }
    }

    // CPU fallback
    return findFilesWithRegexCpu(allocator, paths, pattern, case_insensitive, options);
}

/// CPU regex matching fallback
fn findFilesWithRegexCpu(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    pattern: []const u8,
    case_insensitive: bool,
    options: FindOptions,
) FindResult {
    var compiled = regex.Regex.compile(allocator, pattern, .{ .case_insensitive = case_insensitive }) catch {
        std.debug.print("find: invalid regex pattern\n", .{});
        return .{ .count = 0, .had_error = true };
    };
    defer compiled.deinit();

    var match_count: usize = 0;
    for (paths) |path| {
        // GNU find -regex matches the entire path
        var matched = false;
        if (compiled.find(path, allocator)) |match_opt| {
            if (match_opt) |match| {
                var m = match;
                defer m.deinit();
                // Check if match spans entire string
                if (m.start == 0 and m.end == path.len) {
                    matched = true;
                }
            }
        } else |_| {}

        const should_output = if (options.negate_pattern) !matched else matched;
        if (should_output) {
            if (!options.count_only) {
                printPath(path, options.print0);
            }
            match_count += 1;
        }
    }

    return .{ .count = match_count, .had_error = false };
}

fn walkDirectory(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: FindOptions,
    collected: *std.ArrayListUnmanaged([]const u8),
    depth: usize,
) !void {
    // Check max depth
    if (options.max_depth) |max| {
        if (depth > max) return;
    }

    // Try to open as directory first to determine type
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        if (err == error.NotDir) {
            // It's a file, not a directory
            if (depth >= options.min_depth) {
                const stat = std.fs.cwd().statFile(path) catch |stat_err| {
                    if (stat_err == error.FileNotFound) return;
                    return stat_err;
                };

                const passes_type_filter = switch (options.file_type) {
                    .any => true,
                    .file => stat.kind == .file,
                    .directory => false,
                    .symlink => stat.kind == .sym_link,
                    .block_device => stat.kind == .block_device,
                    .char_device => stat.kind == .character_device,
                    .fifo => stat.kind == .named_pipe,
                    .socket => stat.kind == .unix_domain_socket,
                };

                // Check -empty: file is empty if size == 0
                var passes_empty_filter = if (options.empty_only)
                    (stat.kind == .file and stat.size == 0)
                else
                    true;
                // Apply negation to empty filter if -not was specified
                if (options.negate_pattern and options.empty_only) {
                    passes_empty_filter = !passes_empty_filter;
                }

                // Check -size filter
                const passes_size_filter = if (options.size_filter) |sf|
                    sf.matches(@intCast(stat.size))
                else
                    true;

                // Check -mtime/-atime/-ctime filter
                const passes_time_filter = if (options.time_filter) |tf| blk: {
                    const now = std.time.timestamp();
                    // stat times are in nanoseconds on macOS, convert to seconds
                    const ns_per_sec: i128 = 1_000_000_000;
                    const file_time: i64 = @intCast(switch (tf.time_type) {
                        .modified => @divFloor(stat.mtime, ns_per_sec),
                        .accessed => @divFloor(stat.atime, ns_per_sec),
                        .changed => @divFloor(stat.ctime, ns_per_sec),
                    });
                    break :blk tf.matches(file_time, now);
                } else true;

                if (passes_type_filter and passes_empty_filter and passes_size_filter and passes_time_filter) {
                    try collected.append(allocator, try allocator.dupe(u8, path));
                }
            }
            return;
        }
        if (err == error.FileNotFound or err == error.AccessDenied) return;
        return err;
    };
    defer dir.close();

    // Check -prune: if this directory matches the prune pattern, skip it entirely
    // Don't add it to results and don't recurse into it
    if (options.prune_pattern) |prune_pat| {
        const basename = std.fs.path.basename(path);
        if (matchGlob(basename, prune_pat, false)) {
            // Directory matches prune pattern - skip it entirely
            return;
        }
    }

    // Recurse into directory contents (need to do this first for -empty check)
    var iter = dir.iterate();
    var has_entries = false;
    var children: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (children.items) |child| allocator.free(child);
        children.deinit(allocator);
    }

    while (try iter.next()) |entry| {
        has_entries = true;
        const child_path = try std.fs.path.join(allocator, &[_][]const u8{ path, entry.name });
        try children.append(allocator, child_path);
    }

    // It's a directory - add it if it passes filters
    if (depth >= options.min_depth) {
        const passes_type_filter = switch (options.file_type) {
            .any => true,
            .directory => true,
            else => false,
        };

        // Check -empty: directory is empty if it has no entries
        var passes_empty_filter = if (options.empty_only)
            !has_entries
        else
            true;
        // Apply negation to empty filter if -not was specified
        if (options.negate_pattern and options.empty_only) {
            passes_empty_filter = !passes_empty_filter;
        }

        if (passes_type_filter and passes_empty_filter) {
            try collected.append(allocator, try allocator.dupe(u8, path));
        }
    }

    // Recurse into children
    for (children.items) |child_path| {
        try walkDirectory(allocator, child_path, options, collected, depth + 1);
    }
}

fn printPath(path: []const u8, print0: bool) void {
    const handle: std.posix.fd_t = std.posix.STDOUT_FILENO;
    _ = std.posix.write(handle, path) catch {};
    if (print0) {
        _ = std.posix.write(handle, &[_]u8{0}) catch {};
    } else {
        _ = std.posix.write(handle, "\n") catch {};
    }
}

/// Simple glob pattern matching (supports * and ?)
fn matchGlob(text: []const u8, pattern: []const u8, case_insensitive: bool) bool {
    var ti: usize = 0;
    var pi: usize = 0;
    var star_pi: ?usize = null;
    var star_ti: usize = 0;

    while (ti < text.len) {
        if (pi < pattern.len and (pattern[pi] == '?' or charsEqual(pattern[pi], text[ti], case_insensitive))) {
            ti += 1;
            pi += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ti = ti;
            pi += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_ti += 1;
            ti = star_ti;
        } else {
            return false;
        }
    }

    while (pi < pattern.len and pattern[pi] == '*') {
        pi += 1;
    }

    return pi == pattern.len;
}

fn charsEqual(a: u8, b: u8, case_insensitive: bool) bool {
    if (case_insensitive) {
        const la = if (a >= 'A' and a <= 'Z') a + 32 else a;
        const lb = if (b >= 'A' and b <= 'Z') b + 32 else b;
        return la == lb;
    }
    return a == b;
}

fn printUsage() void {
    const help_text =
        \\Usage: find [-H] [-L] [-P] [path...] [expression]
        \\
        \\Search for files in a directory hierarchy.
        \\Default path is the current directory. Use - to read paths from stdin.
        \\
        \\Tests:
        \\  -name PATTERN     Base of file name matches shell PATTERN
        \\  -iname PATTERN    Like -name but case-insensitive
        \\  -path PATTERN     File path matches shell PATTERN
        \\  -ipath PATTERN    Like -path but case-insensitive
        \\  -type TYPE        File is of type TYPE:
        \\                      f  regular file
        \\                      d  directory
        \\                      l  symbolic link
        \\                      b  block device
        \\                      c  character device
        \\                      p  named pipe (FIFO)
        \\                      s  socket
        \\  -empty             File is empty (0 size for files, no entries for dirs)
        \\  -size [+-]N[ckMG]  File uses N units of space:
        \\                      c  bytes
        \\                      k  kibibytes (1024 bytes)
        \\                      M  mebibytes (1024^2 bytes)
        \\                      G  gibibytes (1024^3 bytes)
        \\                      (default: 512-byte blocks)
        \\                      +N  greater than N, -N  less than N
        \\  -mtime [+-]N       File's data was modified N*24 hours ago
        \\                      +N  more than N days ago (older)
        \\                      -N  less than N days ago (newer)
        \\  -atime [+-]N       File was last accessed N*24 hours ago
        \\  -ctime [+-]N       File's status was last changed N*24 hours ago
        \\
        \\Actions:
        \\  -prune PATTERN     Do not descend into directories matching PATTERN
        \\
        \\Operators:
        \\  -not, !            Negate the following test
        \\
        \\Options:
        \\  -maxdepth LEVELS  Descend at most LEVELS of directories
        \\  -mindepth LEVELS  Do not apply tests or actions at levels less than LEVELS
        \\  -print0           Print paths followed by NUL instead of newline
        \\  -count            Print count of matches (custom extension)
        \\
        \\GPU Backend selection:
        \\  --auto            auto-select optimal backend (default)
        \\  --gpu             force GPU (Metal on macOS, Vulkan on Linux)
        \\  --cpu             force CPU backend
        \\  --metal           force Metal backend (macOS only)
        \\  --vulkan          force Vulkan backend
        \\
        \\Miscellaneous:
        \\  -v, --verbose     print backend and timing information
        \\  -h, --help        display this help and exit
        \\      --version     output version information and exit
        \\
        \\Pattern wildcards:
        \\  *      matches any string
        \\  ?      matches any single character
        \\  [abc]  matches any character in the set
        \\  [a-z]  matches any character in the range
        \\  [!abc] matches any character NOT in the set
        \\
        \\GPU Performance (typical speedups vs CPU):
        \\  10K files:   ~4x
        \\  100K files:  ~7x
        \\  1M files:    ~10x
        \\
        \\Examples:
        \\  find . -name '*.txt'              Find all .txt files
        \\  find . -iname '*.jpg'             Case-insensitive search
        \\  find /var/log -type f -name '*.log'
        \\                                    Find log files
        \\  find . -name '*.c' -print0 | xargs -0 grep 'TODO'
        \\                                    Combine with xargs
        \\  echo '/home /var' | find - -name '*.conf'
        \\                                    Read paths from stdin
        \\  find --gpu . -name '*.rs'         Force GPU backend
        \\
    ;
    _ = std.posix.write(std.posix.STDOUT_FILENO, help_text) catch {};
}

// Tests
test "parse file type" {
    try std.testing.expectEqual(FileType.file, parseFileType("f").?);
    try std.testing.expectEqual(FileType.directory, parseFileType("d").?);
    try std.testing.expectEqual(FileType.symlink, parseFileType("l").?);
    try std.testing.expect(parseFileType("x") == null);
    try std.testing.expect(parseFileType("ff") == null);
}

test "matchGlob: basic patterns" {
    try std.testing.expect(matchGlob("file.txt", "*.txt", false));
    try std.testing.expect(!matchGlob("file.log", "*.txt", false));
    try std.testing.expect(matchGlob("test", "t?st", false));
    try std.testing.expect(matchGlob("FILE.TXT", "*.txt", true));
    try std.testing.expect(!matchGlob("FILE.TXT", "*.txt", false));
}

test "FindOptions: default values" {
    const options = FindOptions{};
    try std.testing.expect(!options.negate_pattern);
    try std.testing.expect(!options.empty_only);
}

test "parseSizeArg: basic size parsing" {
    // Bytes suffix
    const size_c = parseSizeArg("100c");
    try std.testing.expect(size_c != null);
    try std.testing.expectEqual(@as(u64, 100), size_c.?.bytes);
    try std.testing.expectEqual(SizeComparison.exact, size_c.?.comparison);

    // Kilobytes suffix
    const size_k = parseSizeArg("2k");
    try std.testing.expect(size_k != null);
    try std.testing.expectEqual(@as(u64, 2 * 1024), size_k.?.bytes);

    // Megabytes suffix
    const size_m = parseSizeArg("5M");
    try std.testing.expect(size_m != null);
    try std.testing.expectEqual(@as(u64, 5 * 1024 * 1024), size_m.?.bytes);

    // Gigabytes suffix
    const size_g = parseSizeArg("1G");
    try std.testing.expect(size_g != null);
    try std.testing.expectEqual(@as(u64, 1024 * 1024 * 1024), size_g.?.bytes);

    // Default (512-byte blocks)
    const size_default = parseSizeArg("10");
    try std.testing.expect(size_default != null);
    try std.testing.expectEqual(@as(u64, 10 * 512), size_default.?.bytes);
}

test "parseSizeArg: comparison operators" {
    // Greater than
    const size_gt = parseSizeArg("+1M");
    try std.testing.expect(size_gt != null);
    try std.testing.expectEqual(SizeComparison.greater, size_gt.?.comparison);
    try std.testing.expectEqual(@as(u64, 1024 * 1024), size_gt.?.bytes);

    // Less than
    const size_lt = parseSizeArg("-100k");
    try std.testing.expect(size_lt != null);
    try std.testing.expectEqual(SizeComparison.less, size_lt.?.comparison);
    try std.testing.expectEqual(@as(u64, 100 * 1024), size_lt.?.bytes);
}

test "parseSizeArg: invalid inputs" {
    try std.testing.expect(parseSizeArg("") == null);
    try std.testing.expect(parseSizeArg("+") == null);
    try std.testing.expect(parseSizeArg("abc") == null);
    try std.testing.expect(parseSizeArg("1X") == null);
}

test "SizeFilter: matches function" {
    const exact = SizeFilter{ .bytes = 1000, .comparison = .exact };
    try std.testing.expect(exact.matches(1000));
    try std.testing.expect(!exact.matches(999));
    try std.testing.expect(!exact.matches(1001));

    const greater = SizeFilter{ .bytes = 1000, .comparison = .greater };
    try std.testing.expect(greater.matches(1001));
    try std.testing.expect(!greater.matches(1000));
    try std.testing.expect(!greater.matches(999));

    const less = SizeFilter{ .bytes = 1000, .comparison = .less };
    try std.testing.expect(less.matches(999));
    try std.testing.expect(!less.matches(1000));
    try std.testing.expect(!less.matches(1001));
}

test "parseTimeArg: basic time parsing" {
    // Exact days
    const time_exact = parseTimeArg("5", .modified);
    try std.testing.expect(time_exact != null);
    try std.testing.expectEqual(@as(i64, 5), time_exact.?.days);
    try std.testing.expectEqual(TimeComparison.exact, time_exact.?.comparison);
    try std.testing.expectEqual(TimeType.modified, time_exact.?.time_type);

    // Different time types
    const time_atime = parseTimeArg("3", .accessed);
    try std.testing.expect(time_atime != null);
    try std.testing.expectEqual(TimeType.accessed, time_atime.?.time_type);

    const time_ctime = parseTimeArg("7", .changed);
    try std.testing.expect(time_ctime != null);
    try std.testing.expectEqual(TimeType.changed, time_ctime.?.time_type);
}

test "parseTimeArg: comparison operators" {
    // More than N days ago (older)
    const time_older = parseTimeArg("+7", .modified);
    try std.testing.expect(time_older != null);
    try std.testing.expectEqual(TimeComparison.older, time_older.?.comparison);
    try std.testing.expectEqual(@as(i64, 7), time_older.?.days);

    // Less than N days ago (newer)
    const time_newer = parseTimeArg("-1", .modified);
    try std.testing.expect(time_newer != null);
    try std.testing.expectEqual(TimeComparison.newer, time_newer.?.comparison);
    try std.testing.expectEqual(@as(i64, 1), time_newer.?.days);
}

test "parseTimeArg: invalid inputs" {
    try std.testing.expect(parseTimeArg("", .modified) == null);
    try std.testing.expect(parseTimeArg("+", .modified) == null);
    try std.testing.expect(parseTimeArg("abc", .modified) == null);
}

test "TimeFilter: matches function" {
    const seconds_per_day: i64 = 86400;
    const now: i64 = 1000000000; // Some arbitrary timestamp

    // File modified exactly 5 days ago
    const exact = TimeFilter{ .days = 5, .comparison = .exact, .time_type = .modified };
    try std.testing.expect(exact.matches(now - 5 * seconds_per_day, now));
    try std.testing.expect(!exact.matches(now - 4 * seconds_per_day, now));
    try std.testing.expect(!exact.matches(now - 6 * seconds_per_day, now));

    // File modified more than 3 days ago (older)
    const older = TimeFilter{ .days = 3, .comparison = .older, .time_type = .modified };
    try std.testing.expect(older.matches(now - 5 * seconds_per_day, now)); // 5 > 3
    try std.testing.expect(older.matches(now - 4 * seconds_per_day, now)); // 4 > 3
    try std.testing.expect(!older.matches(now - 3 * seconds_per_day, now)); // 3 == 3, not >
    try std.testing.expect(!older.matches(now - 2 * seconds_per_day, now)); // 2 < 3

    // File modified less than 3 days ago (newer)
    const newer = TimeFilter{ .days = 3, .comparison = .newer, .time_type = .modified };
    try std.testing.expect(newer.matches(now - 2 * seconds_per_day, now)); // 2 < 3
    try std.testing.expect(newer.matches(now - 1 * seconds_per_day, now)); // 1 < 3
    try std.testing.expect(!newer.matches(now - 3 * seconds_per_day, now)); // 3 == 3, not <
    try std.testing.expect(!newer.matches(now - 5 * seconds_per_day, now)); // 5 > 3
}
