const std = @import("std");
const build_options = @import("build_options");
const gpu = @import("gpu");
const cpu = @import("cpu");

/// Backend selection mode
const BackendMode = enum {
    auto, // Automatically select based on workload
    gpu_mode, // Auto-select best GPU (Metal on macOS, else Vulkan)
    cpu_mode,
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

/// Find options
const FindOptions = struct {
    pattern: ?[]const u8 = null, // -name pattern
    ipattern: ?[]const u8 = null, // -iname pattern
    path_pattern: ?[]const u8 = null, // -path pattern
    ipath_pattern: ?[]const u8 = null, // -ipath pattern
    // Additional patterns for -o support
    or_patterns: []const OrPattern = &.{},
    file_type: FileType = .any, // -type
    max_depth: ?usize = null, // -maxdepth
    min_depth: usize = 0, // -mindepth
    print0: bool = false, // -print0
    count_only: bool = false, // -count (custom extension)
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
        } else if (std.mem.eql(u8, arg, "--cpu")) {
            backend_mode = .cpu_mode;
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
            if (matches) {
                if (!options.count_only) {
                    printPath(path, options.print0);
                }
                match_count += 1;
            }
        }
        return .{ .count = match_count, .had_error = false };
    }

    // If no pattern specified, just print all collected paths
    if (options.pattern == null and options.ipattern == null and options.path_pattern == null and options.ipath_pattern == null) {
        for (collected_paths.items) |path| {
            printPath(path, options.print0);
        }
        return .{ .count = collected_paths.items.len, .had_error = false };
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
        .cpu_mode => false,
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

            for (result.matches) |match| {
                if (!options.count_only) {
                    printPath(collected_paths.items[match.name_idx], options.print0);
                }
                match_count += 1;
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
        std.debug.print("Using CPU backend\n", .{});
    }

    var result = cpu.matchNames(collected_paths.items, pattern, match_options, allocator) catch {
        return .{ .count = 0, .had_error = true };
    };
    defer result.deinit();

    for (result.matches) |match| {
        if (!options.count_only) {
            printPath(collected_paths.items[match.name_idx], options.print0);
        }
        match_count += 1;
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

    // Add this path if it passes min_depth filter
    if (depth >= options.min_depth) {
        // Check file type filter
        const stat = std.fs.cwd().statFile(path) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };

        const passes_type_filter = switch (options.file_type) {
            .any => true,
            .file => stat.kind == .file,
            .directory => stat.kind == .directory,
            .symlink => stat.kind == .sym_link,
            .block_device => stat.kind == .block_device,
            .char_device => stat.kind == .character_device,
            .fifo => stat.kind == .named_pipe,
            .socket => stat.kind == .unix_domain_socket,
        };

        if (passes_type_filter) {
            try collected.append(allocator, try allocator.dupe(u8, path));
        }
    }

    // Recurse into directories
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |err| {
        if (err == error.NotDir or err == error.AccessDenied) return;
        return err;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const child_path = try std.fs.path.join(allocator, &[_][]const u8{ path, entry.name });
        defer allocator.free(child_path);

        // Recurse
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
