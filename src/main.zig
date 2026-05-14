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

/// Convert a character to TimeType for -newerXY parsing
fn charToTimeType(c: u8) TimeType {
    return switch (c) {
        'a' => .accessed,
        'c' => .changed,
        'm' => .modified,
        else => .modified, // default to m
    };
}

/// -newerXY filter: compare time X of file to time Y of reference
const NewerXYFilter = struct {
    file_time_type: TimeType, // X: which time of the evaluated file
    ref_time_type: TimeType, // Y: which time of the reference file
    ref_path: []const u8,
};

/// Time filter for -mtime/-atime/-ctime/-mmin/-amin/-cmin options
const TimeFilter = struct {
    days: i64, // Number of days (or minutes when is_minutes=true)
    comparison: TimeComparison,
    time_type: TimeType,
    is_minutes: bool = false, // true for -mmin/-amin/-cmin

    /// Check if a file time matches this filter
    /// file_time is the Unix timestamp (seconds since epoch)
    /// now is the current Unix timestamp
    pub fn matches(self: TimeFilter, file_time: i64, now: i64) bool {
        const age_seconds = now - file_time;
        if (self.is_minutes) {
            const age_minutes = @divFloor(age_seconds, 60);
            return switch (self.comparison) {
                .exact => age_minutes == self.days,
                .newer => age_minutes < self.days,
                .older => age_minutes > self.days,
            };
        } else {
            const seconds_per_day: i64 = 86400;
            const age_days = @divFloor(age_seconds, seconds_per_day);
            return switch (self.comparison) {
                .exact => age_days == self.days,
                .newer => age_days < self.days,
                .older => age_days > self.days,
            };
        }
    }
};

/// Parse a time argument like "+7", "-1", "0"
/// Returns the number of days/minutes and comparison type
fn parseTimeArg(arg: []const u8, time_type: TimeType, is_minutes: bool) ?TimeFilter {
    if (arg.len == 0) return null;

    var comparison: TimeComparison = .exact;
    var start: usize = 0;

    // Check for +/- prefix
    // +N means MORE than N days/minutes ago (older)
    // -N means LESS than N days/minutes ago (newer/more recent)
    if (arg[0] == '+') {
        comparison = .older;
        start = 1;
    } else if (arg[0] == '-') {
        comparison = .newer;
        start = 1;
    }

    if (start >= arg.len) return null;

    // Parse the number of days/minutes
    const days = std.fmt.parseInt(i64, arg[start..], 10) catch return null;

    return TimeFilter{
        .days = days,
        .comparison = comparison,
        .time_type = time_type,
        .is_minutes = is_minutes,
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
    delete_matched: bool = false, // -delete
    exec_command: ?[]const []const u8 = null, // -exec command args ;
    exec_plus: bool = false, // -exec command {} +
    ok_command: ?[]const []const u8 = null, // -ok command args ;
    execdir_command: ?[]const []const u8 = null, // -execdir command args ;
    okdir_command: ?[]const []const u8 = null, // -okdir command args ;
    list_detailed: bool = false, // -ls
    newer_than: ?[]const u8 = null, // -newer FILE (legacy, same as -newermm)
    newer_xy: ?NewerXYFilter = null, // -newerXY reference
    user_name: ?[]const u8 = null, // -user NAME
    group_name: ?[]const u8 = null, // -group NAME
    perm_mode: ?[]const u8 = null, // -perm MODE
    follow_symlinks: bool = false, // -follow / -L
    depth_first: bool = false, // -depth
    stay_on_filesystem: bool = false, // -mount / -xdev
    links_count: ?u32 = null, // -links N
    always_true: bool = false, // -true
    always_false: bool = false, // -false
    quit_after_first: bool = false, // -quit
    printf_format: ?[]const u8 = null, // -printf FORMAT
    fprint_file: ?[]const u8 = null, // -fprint FILE
    fprintf_file: ?[]const u8 = null, // -fprintf FILE FORMAT
    fprintf_format: ?[]const u8 = null, // -fprintf FILE FORMAT
    start_device: ?u64 = null, // Device ID of start path for -mount
    inode_number: ?u64 = null, // -inum N
    samefile_path: ?[]const u8 = null, // -samefile FILE
    no_user: bool = false, // -nouser
    no_group: bool = false, // -nogroup
    readable: bool = false, // -readable
    writable: bool = false, // -writable
    executable: bool = false, // -executable
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
            options.time_filter = parseTimeArg(args[i], .modified, false) orelse {
                std.debug.print("Invalid -mtime argument: {s}\n", .{args[i]});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "-atime") and i + 1 < args.len) {
            i += 1;
            options.time_filter = parseTimeArg(args[i], .accessed, false) orelse {
                std.debug.print("Invalid -atime argument: {s}\n", .{args[i]});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "-ctime") and i + 1 < args.len) {
            i += 1;
            options.time_filter = parseTimeArg(args[i], .changed, false) orelse {
                std.debug.print("Invalid -ctime argument: {s}\n", .{args[i]});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "-mmin") and i + 1 < args.len) {
            i += 1;
            options.time_filter = parseTimeArg(args[i], .modified, true) orelse {
                std.debug.print("Invalid -mmin argument: {s}\n", .{args[i]});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "-amin") and i + 1 < args.len) {
            i += 1;
            options.time_filter = parseTimeArg(args[i], .accessed, true) orelse {
                std.debug.print("Invalid -amin argument: {s}\n", .{args[i]});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "-cmin") and i + 1 < args.len) {
            i += 1;
            options.time_filter = parseTimeArg(args[i], .changed, true) orelse {
                std.debug.print("Invalid -cmin argument: {s}\n", .{args[i]});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "-prune") and i + 1 < args.len) {
            i += 1;
            options.prune_pattern = args[i];
        } else if (std.mem.eql(u8, arg, "-delete")) {
            options.delete_matched = true;
        } else if (std.mem.startsWith(u8, arg, "-newer") and i + 1 < args.len) {
            i += 1;
            const ref_path = args[i];
            if (arg.len == 6) {
                // -newer alone = -newermm
                options.newer_xy = NewerXYFilter{ .file_time_type = .modified, .ref_time_type = .modified, .ref_path = ref_path };
            } else if (arg.len >= 8) {
                // -newerXY where X and Y are each a/c/m
                const x = arg[6];
                const y = arg[7];
                options.newer_xy = NewerXYFilter{ .file_time_type = charToTimeType(x), .ref_time_type = charToTimeType(y), .ref_path = ref_path };
            } else {
                // -newerX (single suffix) = -newerXm
                const x = arg[6];
                options.newer_xy = NewerXYFilter{ .file_time_type = charToTimeType(x), .ref_time_type = .modified, .ref_path = ref_path };
            }
        } else if (std.mem.eql(u8, arg, "-user") and i + 1 < args.len) {
            i += 1;
            options.user_name = args[i];
        } else if (std.mem.eql(u8, arg, "-group") and i + 1 < args.len) {
            i += 1;
            options.group_name = args[i];
        } else if (std.mem.eql(u8, arg, "-perm") and i + 1 < args.len) {
            i += 1;
            options.perm_mode = args[i];
        } else if (std.mem.eql(u8, arg, "-follow") or std.mem.eql(u8, arg, "-L")) {
            options.follow_symlinks = true;
        } else if (std.mem.eql(u8, arg, "-depth")) {
            options.depth_first = true;
        } else if (std.mem.eql(u8, arg, "-mount") or std.mem.eql(u8, arg, "-xdev")) {
            options.stay_on_filesystem = true;
        } else if (std.mem.eql(u8, arg, "-links") and i + 1 < args.len) {
            i += 1;
            options.links_count = std.fmt.parseInt(u32, args[i], 10) catch {
                std.debug.print("Invalid -links value: {s}\n", .{args[i]});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "-true")) {
            options.always_true = true;
        } else if (std.mem.eql(u8, arg, "-false")) {
            options.always_false = true;
        } else if (std.mem.eql(u8, arg, "-quit")) {
            options.quit_after_first = true;
        } else if (std.mem.eql(u8, arg, "-printf") and i + 1 < args.len) {
            i += 1;
            options.printf_format = args[i];
        } else if (std.mem.eql(u8, arg, "-fprint") and i + 1 < args.len) {
            i += 1;
            options.fprint_file = args[i];
        } else if (std.mem.eql(u8, arg, "-fprintf") and i + 2 < args.len) {
            i += 1;
            options.fprintf_file = args[i];
            i += 1;
            options.fprintf_format = args[i];
        } else if (std.mem.eql(u8, arg, "-inum") and i + 1 < args.len) {
            i += 1;
            options.inode_number = std.fmt.parseInt(u64, args[i], 10) catch {
                std.debug.print("Invalid -inum value: {s}\n", .{args[i]});
                return 1;
            };
        } else if (std.mem.eql(u8, arg, "-samefile") and i + 1 < args.len) {
            i += 1;
            options.samefile_path = args[i];
        } else if (std.mem.eql(u8, arg, "-nouser")) {
            options.no_user = true;
        } else if (std.mem.eql(u8, arg, "-nogroup")) {
            options.no_group = true;
        } else if (std.mem.eql(u8, arg, "-exec")) {
            // Collect command and args until ; or +
            var exec_args: std.ArrayListUnmanaged([]const u8) = .{};
            i += 1;
            while (i < args.len) : (i += 1) {
                const exec_arg = args[i];
                if (std.mem.eql(u8, exec_arg, ";")) {
                    options.exec_plus = false;
                    break;
                } else if (std.mem.eql(u8, exec_arg, "+")) {
                    options.exec_plus = true;
                    break;
                } else {
                    try exec_args.append(allocator, exec_arg);
                }
            }
            if (exec_args.items.len > 0) {
                options.exec_command = try exec_args.toOwnedSlice(allocator);
            }
        } else if (std.mem.eql(u8, arg, "-ok")) {
            // Collect command and args until ;
            var exec_args: std.ArrayListUnmanaged([]const u8) = .{};
            i += 1;
            while (i < args.len) : (i += 1) {
                const exec_arg = args[i];
                if (std.mem.eql(u8, exec_arg, ";")) {
                    break;
                } else {
                    try exec_args.append(allocator, exec_arg);
                }
            }
            if (exec_args.items.len > 0) {
                options.ok_command = try exec_args.toOwnedSlice(allocator);
            }
        } else if (std.mem.eql(u8, arg, "-execdir")) {
            // Collect command and args until ;
            var exec_args: std.ArrayListUnmanaged([]const u8) = .{};
            i += 1;
            while (i < args.len) : (i += 1) {
                const exec_arg = args[i];
                if (std.mem.eql(u8, exec_arg, ";")) {
                    break;
                } else {
                    try exec_args.append(allocator, exec_arg);
                }
            }
            if (exec_args.items.len > 0) {
                options.execdir_command = try exec_args.toOwnedSlice(allocator);
            }
        } else if (std.mem.eql(u8, arg, "-okdir")) {
            // Collect command and args until ;
            var exec_args: std.ArrayListUnmanaged([]const u8) = .{};
            i += 1;
            while (i < args.len) : (i += 1) {
                const exec_arg = args[i];
                if (std.mem.eql(u8, exec_arg, ";")) {
                    break;
                } else {
                    try exec_args.append(allocator, exec_arg);
                }
            }
            if (exec_args.items.len > 0) {
                options.okdir_command = try exec_args.toOwnedSlice(allocator);
            }
        } else if (std.mem.eql(u8, arg, "-ls")) {
            options.list_detailed = true;
        } else if (std.mem.eql(u8, arg, "-readable")) {
            options.readable = true;
        } else if (std.mem.eql(u8, arg, "-writable")) {
            options.writable = true;
        } else if (std.mem.eql(u8, arg, "-executable")) {
            options.executable = true;
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

var g_quit_requested = false;

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

    // Get start device for -mount/-xdev
    var options_with_device = options;
    if (options.stay_on_filesystem) {
        const c_path = allocator.dupeZ(u8, start_path) catch null;
        if (c_path) |cp| {
            defer allocator.free(cp);
            var st: std.posix.Stat = undefined;
            if (std.c.stat(cp, &st) == 0) {
                options_with_device.start_device = @intCast(st.dev);
            }
        }
    }

    g_quit_requested = false;

    // Collect all file paths first
    walkDirectory(allocator, start_path, options_with_device, &collected_paths, 0) catch |err| {
        if (err == error.QuitRequested) {
            // Normal exit after -quit
        } else {
            std.debug.print("find: error walking '{s}': {}\n", .{ start_path, err });
            return .{ .count = 0, .had_error = true };
        }
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
                        performAction(path, options, allocator);
                    }
                    match_count += 1;
                }
        }
        return .{ .count = match_count, .had_error = false };
    }

    // If no pattern specified, just print all collected paths
    if (options.pattern == null and options.ipattern == null and options.path_pattern == null and options.ipath_pattern == null and options.regex_pattern == null and options.iregex_pattern == null) {
        for (collected_paths.items) |path| {
            performAction(path, options, allocator);
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
                            performAction(path, options, allocator);
                        }
                        match_count += 1;
                    }
                }
            } else {
                for (result.matches) |match| {
                    if (!options.count_only) {
                        performAction(collected_paths.items[match.name_idx], options, allocator);
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
                    performAction(path, options, allocator);
                }
                match_count += 1;
            }
        }
    } else {
        for (result.matches) |match| {
            if (!options.count_only) {
                performAction(collected_paths.items[match.name_idx], options, allocator);
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
                            performAction(path, options, allocator);
                        }
                        match_count += 1;
                    }
                }
            } else {
                for (result.matches) |match| {
                    if (!options.count_only) {
                        performAction(paths[match.name_idx], options, allocator);
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
                            performAction(path, options, allocator);
                        }
                        match_count += 1;
                    }
                }
            } else {
                for (result.matches) |match| {
                    if (!options.count_only) {
                        performAction(paths[match.name_idx], options, allocator);
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
                performAction(path, options, allocator);
            }
            match_count += 1;
        }
    }

    return .{ .count = match_count, .had_error = false };
}

const QuitError = error{QuitRequested};

/// Check if a directory has no entries (other than . and ..)
fn isDirEmpty(path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return false;
    defer dir.close();
    var iter = dir.iterate();
    const entry = iter.next() catch return false;
    return entry == null;
}

/// Check if a file/directory passes all metadata filters
fn passesFilters(path: []const u8, stat: std.fs.File.Stat, posix_stat: ?std.posix.Stat, options: FindOptions) bool {
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

    // Check -empty: file is empty if size == 0, dir is empty if no entries
    var passes_empty_filter = true;
    if (options.empty_only) {
        if (stat.kind == .file) {
            passes_empty_filter = stat.size == 0;
        } else if (stat.kind == .directory) {
            passes_empty_filter = isDirEmpty(path);
        } else {
            passes_empty_filter = false;
        }
    }
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
        const ns_per_sec: i128 = 1_000_000_000;
        const file_time: i64 = @intCast(switch (tf.time_type) {
            .modified => @divFloor(stat.mtime, ns_per_sec),
            .accessed => @divFloor(stat.atime, ns_per_sec),
            .changed => @divFloor(stat.ctime, ns_per_sec),
        });
        break :blk tf.matches(file_time, now);
    } else true;

    // Check -newer / -newerXY filter
    const passes_newer_filter = if (options.newer_xy) |nf| blk: {
        const ref_stat = std.fs.cwd().statFile(nf.ref_path) catch {
            break :blk false;
        };
        const file_time = switch (nf.file_time_type) {
            .modified => stat.mtime,
            .accessed => stat.atime,
            .changed => stat.ctime,
        };
        const ref_time = switch (nf.ref_time_type) {
            .modified => ref_stat.mtime,
            .accessed => ref_stat.atime,
            .changed => ref_stat.ctime,
        };
        break :blk file_time > ref_time;
    } else true;

    // Check -user filter
    const passes_user_filter = if (options.user_name) |uname| blk: {
        if (posix_stat == null) break :blk false;
        const target_uid = std.fmt.parseInt(u32, uname, 10) catch {
            const c_uname = std.heap.page_allocator.dupeZ(u8, uname) catch { break :blk false; };
            defer std.heap.page_allocator.free(c_uname);
            const pw = std.c.getpwnam(c_uname);
            if (pw == null) break :blk false;
            break :blk posix_stat.?.uid == pw.?.uid;
        };
        break :blk posix_stat.?.uid == target_uid;
    } else true;

    // Check -group filter
    const passes_group_filter = if (options.group_name) |gname| blk: {
        if (posix_stat == null) break :blk false;
        const target_gid = std.fmt.parseInt(u32, gname, 10) catch {
            const c_gname = std.heap.page_allocator.dupeZ(u8, gname) catch { break :blk false; };
            defer std.heap.page_allocator.free(c_gname);
            const gr = std.c.getgrnam(c_gname);
            if (gr == null) break :blk false;
            break :blk posix_stat.?.gid == gr.?.gid;
        };
        break :blk posix_stat.?.gid == target_gid;
    } else true;

    // Check -readable, -writable, -executable
    var passes_access_filter = true;
    if (options.readable or options.writable or options.executable) {
        const c_path = std.heap.page_allocator.dupeZ(u8, path) catch null;
        if (c_path) |cp| {
            defer std.heap.page_allocator.free(cp);
            var access_mode: c_uint = 0;
            if (options.readable) access_mode |= @intCast(std.posix.R_OK);
            if (options.writable) access_mode |= @intCast(std.posix.W_OK);
            if (options.executable) access_mode |= @intCast(std.posix.X_OK);
            passes_access_filter = std.c.access(cp, access_mode) == 0;
        } else {
            passes_access_filter = false;
        }
    }

    // Check -perm filter
    const passes_perm_filter = if (options.perm_mode) |pmode| blk: {
        if (posix_stat == null) break :blk false;
        // Handle /MODE (any bit set), -MODE (all bits set), or MODE (exact match)
        if (pmode.len > 0 and (pmode[0] == '/' or pmode[0] == '+')) {
            // Any of the permission bits are set
            const target_mode = std.fmt.parseInt(u32, pmode[1..], 8) catch {
                break :blk false;
            };
            break :blk (posix_stat.?.mode & target_mode) != 0;
        } else if (pmode.len > 0 and pmode[0] == '-') {
            // All of the permission bits are set
            const target_mode = std.fmt.parseInt(u32, pmode[1..], 8) catch {
                break :blk false;
            };
            break :blk (posix_stat.?.mode & target_mode) == target_mode;
        } else {
            // Exact match
            const target_mode = std.fmt.parseInt(u32, pmode, 8) catch {
                break :blk false;
            };
            break :blk (posix_stat.?.mode & 0o7777) == (target_mode & 0o7777);
        }
    } else true;

    // Check -links filter
    const passes_links_filter = if (options.links_count) |n| blk: {
        if (posix_stat == null) break :blk false;
        break :blk posix_stat.?.nlink == n;
    } else true;

    // Check -inum filter
    const passes_inode_filter = if (options.inode_number) |inum| blk: {
        if (posix_stat == null) break :blk false;
        break :blk @as(u64, @intCast(posix_stat.?.ino)) == inum;
    } else true;

    // Check -samefile filter
    const passes_samefile_filter = if (options.samefile_path) |sf_path| blk: {
        if (posix_stat == null) break :blk false;
        const c_sf_path = std.heap.page_allocator.dupeZ(u8, sf_path) catch { break :blk false; };
        defer std.heap.page_allocator.free(c_sf_path);
        var st: std.posix.Stat = undefined;
        if (std.c.stat(c_sf_path, &st) != 0) break :blk false;
        break :blk posix_stat.?.ino == st.ino and posix_stat.?.dev == st.dev;
    } else true;

    // Check -nouser filter
    const passes_nouser_filter = if (options.no_user) blk: {
        if (posix_stat == null) break :blk false;
        const pw = std.c.getpwuid(posix_stat.?.uid);
        break :blk pw == null;
    } else true;

    // Check -nogroup filter
    const passes_nogroup_filter = if (options.no_group) blk: {
        if (posix_stat == null) break :blk false;
        const gr = std.c.getgrgid(posix_stat.?.gid);
        break :blk gr == null;
    } else true;

    // Check -true / -false
    if (options.always_false) return false;
    // -true doesn't override other filters, it just adds no constraint

    return passes_type_filter and passes_empty_filter and passes_size_filter and passes_time_filter and passes_newer_filter and passes_user_filter and passes_group_filter and passes_perm_filter and passes_links_filter and passes_access_filter and passes_inode_filter and passes_samefile_filter and passes_nouser_filter and passes_nogroup_filter;
}

fn walkDirectory(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: FindOptions,
    collected: *std.ArrayListUnmanaged([]const u8),
    depth: usize,
) !void {
    if (g_quit_requested) return error.QuitRequested;

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

                const need_posix_stat = options.user_name != null or options.group_name != null or options.perm_mode != null or options.links_count != null or options.inode_number != null or options.samefile_path != null or options.no_user or options.no_group;
                const posix_stat = if (need_posix_stat) blk: {
                    const c_path = allocator.dupeZ(u8, path) catch break :blk null;
                    defer allocator.free(c_path);
                    var st: std.posix.Stat = undefined;
                    if (std.c.stat(c_path, &st) != 0) break :blk null;
                    break :blk st;
                } else null;

                if (passesFilters(path, stat, posix_stat, options)) {
                    try collected.append(allocator, try allocator.dupe(u8, path));
                    if (options.quit_after_first) {
                        g_quit_requested = true;
                        return error.QuitRequested;
                    }
                }
            }
            return;
        }
        if (err == error.FileNotFound or err == error.AccessDenied) return;
        return err;
    };
    defer dir.close();

    // Check -prune: if this directory matches the prune pattern, skip it entirely
    if (options.prune_pattern) |prune_pat| {
        const basename = std.fs.path.basename(path);
        if (matchGlob(basename, prune_pat, false)) {
            return;
        }
    }

    // Check -mount: don't descend into directories on different filesystems
    if (options.stay_on_filesystem and options.start_device != null) {
        const c_path = allocator.dupeZ(u8, path) catch return;
        defer allocator.free(c_path);
        var st: std.posix.Stat = undefined;
        if (std.c.stat(c_path, &st) == 0) {
            if (@as(u64, @intCast(st.dev)) != options.start_device.?) {
                return; // Different filesystem, skip
            }
        }
    }

    // Recurse into directory contents
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

    // With -depth, recurse into children BEFORE adding the directory
    if (options.depth_first) {
        for (children.items) |child_path| {
            try walkDirectory(allocator, child_path, options, collected, depth + 1);
            if (g_quit_requested) return error.QuitRequested;
        }
    }

    // It's a directory - add it if it passes filters
    if (depth >= options.min_depth) {
        // For directories, we need to check filters. statFile works on directories too.
        const stat = std.fs.cwd().statFile(path) catch |stat_err| {
            if (stat_err == error.FileNotFound) return;
            return stat_err;
        };

        const need_posix_stat = options.user_name != null or options.group_name != null or options.perm_mode != null or options.links_count != null;
        const posix_stat = if (need_posix_stat) blk: {
            const c_path = allocator.dupeZ(u8, path) catch break :blk null;
            defer allocator.free(c_path);
            var st: std.posix.Stat = undefined;
            if (std.c.stat(c_path, &st) != 0) break :blk null;
            break :blk st;
        } else null;

        if (passesFilters(path, stat, posix_stat, options)) {
            try collected.append(allocator, try allocator.dupe(u8, path));
            if (options.quit_after_first) {
                g_quit_requested = true;
                return error.QuitRequested;
            }
        }
    }

    // Without -depth, recurse into children AFTER adding the directory
    if (!options.depth_first) {
        for (children.items) |child_path| {
            try walkDirectory(allocator, child_path, options, collected, depth + 1);
            if (g_quit_requested) return error.QuitRequested;
        }
    }
}

fn printPath(path: []const u8, print0: bool) void {
    if (print0) {
        _ = std.posix.write(std.posix.STDOUT_FILENO, path) catch {};
        _ = std.posix.write(std.posix.STDOUT_FILENO, &[_]u8{0}) catch {};
    } else {
        _ = std.posix.write(std.posix.STDOUT_FILENO, path) catch {};
        _ = std.posix.write(std.posix.STDOUT_FILENO, "\n") catch {};
    }
}

fn printPathToFile(path: []const u8, print0: bool, outfile: []const u8) void {
    const file = std.fs.cwd().openFile(outfile, .{ .mode = .write_only }) catch |err| {
        if (err == error.FileNotFound) {
            // Create the file
            const new_file = std.fs.cwd().createFile(outfile, .{}) catch return;
            defer new_file.close();
            if (print0) {
                _ = new_file.write(path) catch {};
                _ = new_file.write(&[_]u8{0}) catch {};
            } else {
                _ = new_file.write(path) catch {};
                _ = new_file.write("\n") catch {};
            }
            return;
        }
        return;
    };
    defer file.close();
    // Append to existing file
    file.seekFromEnd(0) catch {};
    if (print0) {
        _ = file.write(path) catch {};
        _ = file.write(&[_]u8{0}) catch {};
    } else {
        _ = file.write(path) catch {};
        _ = file.write("\n") catch {};
    }
}

fn printFormattedToFile(path: []const u8, format: []const u8, outfile: []const u8, allocator: std.mem.Allocator) void {
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(allocator);

    // Cache stat info lazily
    var stat_cache: ?std.posix.Stat = null;
    var fs_stat_cache: ?std.fs.File.Stat = null;

    const getPstat = struct {
        s: *?std.posix.Stat,
        p: []const u8,
        a: std.mem.Allocator,
        fn get(self: @This()) ?*std.posix.Stat {
            if (self.s.* == null) {
                const c_path = self.a.dupeZ(u8, self.p) catch return null;
                defer self.a.free(c_path);
                var st: std.posix.Stat = undefined;
                if (std.c.stat(c_path, &st) == 0) {
                    self.s.* = st;
                }
            }
            return if (self.s.*) |*st| st else null;
        }
    };
    const getFstat = struct {
        s: *?std.fs.File.Stat,
        p: []const u8,
        fn get(self: @This()) ?*std.fs.File.Stat {
            if (self.s.* == null) {
                self.s.* = std.fs.cwd().statFile(self.p) catch return null;
            }
            return if (self.s.*) |*st| st else null;
        }
    };
    const pstat = getPstat{ .s = &stat_cache, .p = path, .a = allocator };
    const fstat = getFstat{ .s = &fs_stat_cache, .p = path };

    var i: usize = 0;
    while (i < format.len) : (i += 1) {
        if (format[i] == '%' and i + 1 < format.len) {
            i += 1;
            const esc = format[i];
            switch (esc) {
                'p' => output.appendSlice(allocator, path) catch {},
                'f' => output.appendSlice(allocator, std.fs.path.basename(path)) catch {},
                'd' => {
                    const dirname = std.fs.path.dirname(path);
                    output.appendSlice(allocator, dirname orelse ".") catch {};
                },
                's' => {
                    if (pstat.get()) |st| {
                        var buf: [32]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "{d}", .{st.size}) catch "";
                        output.appendSlice(allocator, str) catch {};
                    }
                },
                'U' => {
                    if (pstat.get()) |st| {
                        var buf: [32]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "{d}", .{st.uid}) catch "";
                        output.appendSlice(allocator, str) catch {};
                    }
                },
                'G' => {
                    if (pstat.get()) |st| {
                        var buf: [32]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "{d}", .{st.gid}) catch "";
                        output.appendSlice(allocator, str) catch {};
                    }
                },
                'm' => {
                    if (pstat.get()) |st| {
                        var buf: [16]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "{o}", .{st.mode & 0o7777}) catch "";
                        output.appendSlice(allocator, str) catch {};
                    }
                },
                'M' => {
                    if (pstat.get()) |st| {
                        const mode: u16 = @intCast(st.mode);
                        const file_type_char = fileTypeChar(mode);
                        const has_setuid = (mode & @as(u16, @intCast(std.posix.S.ISUID))) != 0;
                        const has_setgid = (mode & @as(u16, @intCast(std.posix.S.ISGID))) != 0;
                        const has_sticky = (mode & @as(u16, @intCast(std.posix.S.ISVTX))) != 0;
                        const usr_exec = (mode & @as(u16, @intCast(std.posix.S.IXUSR))) != 0;
                        const grp_exec = (mode & @as(u16, @intCast(std.posix.S.IXGRP))) != 0;
                        const oth_exec = (mode & @as(u16, @intCast(std.posix.S.IXOTH))) != 0;
                        const rwx = [3]u8{
                            if (mode & @as(u16, @intCast(std.posix.S.IRUSR)) != 0) 'r' else '-',
                            if (mode & @as(u16, @intCast(std.posix.S.IWUSR)) != 0) 'w' else '-',
                            if (has_setuid) (if (usr_exec) 's' else 'S') else (if (usr_exec) 'x' else '-'),
                        };
                        const rwxg = [3]u8{
                            if (mode & @as(u16, @intCast(std.posix.S.IRGRP)) != 0) 'r' else '-',
                            if (mode & @as(u16, @intCast(std.posix.S.IWGRP)) != 0) 'w' else '-',
                            if (has_setgid) (if (grp_exec) 's' else 'S') else (if (grp_exec) 'x' else '-'),
                        };
                        const rwxo = [3]u8{
                            if (mode & @as(u16, @intCast(std.posix.S.IROTH)) != 0) 'r' else '-',
                            if (mode & @as(u16, @intCast(std.posix.S.IWOTH)) != 0) 'w' else '-',
                            if (has_sticky) (if (oth_exec) 't' else 'T') else (if (oth_exec) 'x' else '-'),
                        };
                        var buf: [16]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "{c}{s}{s}{s}", .{
                            file_type_char,
                            &rwx,
                            &rwxg,
                            &rwxo,
                        }) catch "";
                        output.appendSlice(allocator, str) catch {};
                    }
                },
                'u' => {
                    if (pstat.get()) |st| {
                        if (std.c.getpwuid(st.uid)) |pw| {
                            if (pw.name) |name| {
                                output.appendSlice(allocator, std.mem.span(name)) catch {};
                            }
                        } else {
                            var buf: [32]u8 = undefined;
                            const str = std.fmt.bufPrint(&buf, "{d}", .{st.uid}) catch "";
                            output.appendSlice(allocator, str) catch {};
                        }
                    }
                },
                'g' => {
                    if (pstat.get()) |st| {
                        if (std.c.getgrgid(st.gid)) |gr| {
                            if (gr.name) |name| {
                                output.appendSlice(allocator, std.mem.span(name)) catch {};
                            }
                        } else {
                            var buf: [32]u8 = undefined;
                            const str = std.fmt.bufPrint(&buf, "{d}", .{st.gid}) catch "";
                            output.appendSlice(allocator, str) catch {};
                        }
                    }
                },
                'y' => {
                    if (pstat.get()) |st| {
                        const c = fileTypeCharShort(@intCast(st.mode));
                        output.append(allocator, c) catch {};
                    }
                },
                'i' => {
                    if (pstat.get()) |st| {
                        var buf: [32]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "{d}", .{st.ino}) catch "";
                        output.appendSlice(allocator, str) catch {};
                    }
                },
                'n' => {
                    if (pstat.get()) |st| {
                        var buf: [8]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "{d}", .{st.nlink}) catch "";
                        output.appendSlice(allocator, str) catch {};
                    }
                },
                'T' => {
                    // Time format: %T@ = seconds since epoch, %T+ = ISO-like, %TY = year, etc.
                    if (i + 1 < format.len) {
                        i += 1;
                        const time_esc = format[i];
                        if (fstat.get()) |st| {
                            const mtime_sec: i64 = @intCast(@divFloor(st.mtime, std.time.ns_per_s));
                            switch (time_esc) {
                                '@' => {
                                    var buf: [32]u8 = undefined;
                                    const str = std.fmt.bufPrint(&buf, "{d}.{d}", .{ mtime_sec, @divFloor(@mod(st.mtime, std.time.ns_per_s), 1000000) }) catch "";
                                    output.appendSlice(allocator, str) catch {};
                                },
                                '+' => {
                                    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(mtime_sec) };
                                    const epoch_day = epoch.getEpochDay();
                                    const year_day = epoch_day.calculateYearDay();
                                    const month_day = year_day.calculateMonthDay();
                                    const day_secs = epoch.getDaySeconds();
                                    var buf: [64]u8 = undefined;
                                    const str = std.fmt.bufPrint(&buf, "{d}-{d:0>2}-{d:0>2}+{d:0>2}:{d:0>2}:{d:0>2}", .{
                                        year_day.year,
                                        month_day.month,
                                        month_day.day_index + 1,
                                        day_secs.getHoursIntoDay(),
                                        day_secs.getMinutesIntoHour(),
                                        day_secs.getSecondsIntoMinute(),
                                    }) catch "";
                                    output.appendSlice(allocator, str) catch {};
                                },
                                'Y' => {
                                    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(mtime_sec) };
                                    const year_day = epoch.getEpochDay().calculateYearDay();
                                    var buf: [16]u8 = undefined;
                                    const str = std.fmt.bufPrint(&buf, "{d}", .{year_day.year}) catch "";
                                    output.appendSlice(allocator, str) catch {};
                                },
                                'm' => {
                                    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(mtime_sec) };
                                    const month_day = epoch.getEpochDay().calculateYearDay().calculateMonthDay();
                                    var buf: [8]u8 = undefined;
                                    const str = std.fmt.bufPrint(&buf, "{d:0>2}", .{month_day.month}) catch "";
                                    output.appendSlice(allocator, str) catch {};
                                },
                                'd' => {
                                    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(mtime_sec) };
                                    const month_day = epoch.getEpochDay().calculateYearDay().calculateMonthDay();
                                    var buf: [8]u8 = undefined;
                                    const str = std.fmt.bufPrint(&buf, "{d:0>2}", .{month_day.day_index + 1}) catch "";
                                    output.appendSlice(allocator, str) catch {};
                                },
                                'H' => {
                                    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(mtime_sec) };
                                    var buf: [8]u8 = undefined;
                                    const str = std.fmt.bufPrint(&buf, "{d:0>2}", .{epoch.getDaySeconds().getHoursIntoDay()}) catch "";
                                    output.appendSlice(allocator, str) catch {};
                                },
                                'M' => {
                                    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(mtime_sec) };
                                    var buf: [8]u8 = undefined;
                                    const str = std.fmt.bufPrint(&buf, "{d:0>2}", .{epoch.getDaySeconds().getMinutesIntoHour()}) catch "";
                                    output.appendSlice(allocator, str) catch {};
                                },
                                'S' => {
                                    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(mtime_sec) };
                                    var buf: [8]u8 = undefined;
                                    const str = std.fmt.bufPrint(&buf, "{d:0>2}", .{epoch.getDaySeconds().getSecondsIntoMinute()}) catch "";
                                    output.appendSlice(allocator, str) catch {};
                                },
                                else => {
                                    output.append(allocator, '%') catch {};
                                    output.append(allocator, 'T') catch {};
                                    output.append(allocator, time_esc) catch {};
                                },
                            }
                        }
                    }
                },
                '%' => output.append(allocator, '%') catch {},
                else => {
                    output.append(allocator, '%') catch {};
                    output.append(allocator, esc) catch {};
                },
            }
        } else if (format[i] == '\\' and i + 1 < format.len) {
            i += 1;
            const esc = format[i];
            switch (esc) {
                'n' => output.append(allocator, '\n') catch {},
                't' => output.append(allocator, '\t') catch {},
                'r' => output.append(allocator, '\r') catch {},
                '0'...'7' => {
                    // Octal escape: up to 3 digits
                    var octal_val: u8 = esc - '0';
                    var j: usize = 0;
                    while (j < 2 and i + 1 < format.len and format[i + 1] >= '0' and format[i + 1] <= '7') : (j += 1) {
                        i += 1;
                        octal_val = octal_val * 8 + (format[i] - '0');
                    }
                    if (j > 0) {
                        output.append(allocator, octal_val) catch {};
                        i += j - 1;
                    } else {
                        output.append(allocator, '\\') catch {};
                        output.append(allocator, esc) catch {};
                    }
                },
                else => {
                    output.append(allocator, '\\') catch {};
                    output.append(allocator, esc) catch {};
                },
            }
        } else {
            output.append(allocator, format[i]) catch {};
        }
    }

    const file = std.fs.cwd().openFile(outfile, .{ .mode = .write_only }) catch |err| {
        if (err == error.FileNotFound) {
            const new_file = std.fs.cwd().createFile(outfile, .{}) catch return;
            defer new_file.close();
            _ = new_file.write(output.items) catch {};
            return;
        }
        return;
    };
    defer file.close();
    _ = file.seekFromEnd(0) catch 0;
    _ = file.write(output.items) catch {};
}

fn deletePath(path: []const u8) void {
    // Try to delete as file first, then as empty directory
    std.fs.cwd().deleteFile(path) catch {
        std.fs.cwd().deleteDir(path) catch {};
    };
}

fn fileTypeChar(mode: u16) u8 {
    const m = mode & @as(u16, @intCast(std.posix.S.IFMT));
    if (m == @as(u16, @intCast(std.posix.S.IFREG))) return '-';
    if (m == @as(u16, @intCast(std.posix.S.IFDIR))) return 'd';
    if (m == @as(u16, @intCast(std.posix.S.IFLNK))) return 'l';
    if (m == @as(u16, @intCast(std.posix.S.IFBLK))) return 'b';
    if (m == @as(u16, @intCast(std.posix.S.IFCHR))) return 'c';
    if (m == @as(u16, @intCast(std.posix.S.IFIFO))) return 'p';
    if (m == @as(u16, @intCast(std.posix.S.IFSOCK))) return 's';
    return '?';
}

fn fileTypeCharShort(mode: u16) u8 {
    const c = fileTypeChar(mode);
    return if (c == '-') 'f' else c;
}

/// Print formatted output according to GNU find -printf FORMAT string
fn printFormatted(path: []const u8, format: []const u8, allocator: std.mem.Allocator) void {
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(allocator);

    // Cache stat info lazily
    var stat_cache: ?std.posix.Stat = null;
    var fs_stat_cache: ?std.fs.File.Stat = null;

    const getPstat = struct {
        s: *?std.posix.Stat,
        p: []const u8,
        a: std.mem.Allocator,
        fn get(self: @This()) ?*std.posix.Stat {
            if (self.s.* == null) {
                const c_path = self.a.dupeZ(u8, self.p) catch return null;
                defer self.a.free(c_path);
                var st: std.posix.Stat = undefined;
                if (std.c.stat(c_path, &st) == 0) {
                    self.s.* = st;
                }
            }
            return if (self.s.*) |*st| st else null;
        }
    };
    const getFstat = struct {
        s: *?std.fs.File.Stat,
        p: []const u8,
        fn get(self: @This()) ?*std.fs.File.Stat {
            if (self.s.* == null) {
                self.s.* = std.fs.cwd().statFile(self.p) catch return null;
            }
            return if (self.s.*) |*st| st else null;
        }
    };
    const pstat = getPstat{ .s = &stat_cache, .p = path, .a = allocator };
    const fstat = getFstat{ .s = &fs_stat_cache, .p = path };

    var i: usize = 0;
    while (i < format.len) : (i += 1) {
        if (format[i] == '%' and i + 1 < format.len) {
            i += 1;
            const esc = format[i];
            switch (esc) {
                'p' => output.appendSlice(allocator, path) catch {},
                'f' => output.appendSlice(allocator, std.fs.path.basename(path)) catch {},
                'd' => {
                    const dirname = std.fs.path.dirname(path);
                    output.appendSlice(allocator, dirname orelse ".") catch {};
                },
                's' => {
                    if (pstat.get()) |st| {
                        var buf: [32]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "{d}", .{st.size}) catch "";
                        output.appendSlice(allocator, str) catch {};
                    }
                },
                'U' => {
                    if (pstat.get()) |st| {
                        var buf: [32]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "{d}", .{st.uid}) catch "";
                        output.appendSlice(allocator, str) catch {};
                    }
                },
                'G' => {
                    if (pstat.get()) |st| {
                        var buf: [32]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "{d}", .{st.gid}) catch "";
                        output.appendSlice(allocator, str) catch {};
                    }
                },
                'm' => {
                    if (pstat.get()) |st| {
                        var buf: [16]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "{o}", .{st.mode & 0o7777}) catch "";
                        output.appendSlice(allocator, str) catch {};
                    }
                },
                'M' => {
                    if (pstat.get()) |st| {
                        const mode: u16 = @intCast(st.mode);
                        const file_type_char = fileTypeChar(mode);
                        const has_setuid = (mode & @as(u16, @intCast(std.posix.S.ISUID))) != 0;
                        const has_setgid = (mode & @as(u16, @intCast(std.posix.S.ISGID))) != 0;
                        const has_sticky = (mode & @as(u16, @intCast(std.posix.S.ISVTX))) != 0;
                        const usr_exec = (mode & @as(u16, @intCast(std.posix.S.IXUSR))) != 0;
                        const grp_exec = (mode & @as(u16, @intCast(std.posix.S.IXGRP))) != 0;
                        const oth_exec = (mode & @as(u16, @intCast(std.posix.S.IXOTH))) != 0;
                        const rwx = [3]u8{
                            if (mode & @as(u16, @intCast(std.posix.S.IRUSR)) != 0) 'r' else '-',
                            if (mode & @as(u16, @intCast(std.posix.S.IWUSR)) != 0) 'w' else '-',
                            if (has_setuid) (if (usr_exec) 's' else 'S') else (if (usr_exec) 'x' else '-'),
                        };
                        const rwxg = [3]u8{
                            if (mode & @as(u16, @intCast(std.posix.S.IRGRP)) != 0) 'r' else '-',
                            if (mode & @as(u16, @intCast(std.posix.S.IWGRP)) != 0) 'w' else '-',
                            if (has_setgid) (if (grp_exec) 's' else 'S') else (if (grp_exec) 'x' else '-'),
                        };
                        const rwxo = [3]u8{
                            if (mode & @as(u16, @intCast(std.posix.S.IROTH)) != 0) 'r' else '-',
                            if (mode & @as(u16, @intCast(std.posix.S.IWOTH)) != 0) 'w' else '-',
                            if (has_sticky) (if (oth_exec) 't' else 'T') else (if (oth_exec) 'x' else '-'),
                        };
                        var buf: [16]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "{c}{s}{s}{s}", .{
                            file_type_char,
                            &rwx,
                            &rwxg,
                            &rwxo,
                        }) catch "";
                        output.appendSlice(allocator, str) catch {};
                    }
                },
                'u' => {
                    if (pstat.get()) |st| {
                        if (std.c.getpwuid(st.uid)) |pw| {
                            if (pw.name) |name| {
                                output.appendSlice(allocator, std.mem.span(name)) catch {};
                            }
                        } else {
                            var buf: [32]u8 = undefined;
                            const str = std.fmt.bufPrint(&buf, "{d}", .{st.uid}) catch "";
                            output.appendSlice(allocator, str) catch {};
                        }
                    }
                },
                'g' => {
                    if (pstat.get()) |st| {
                        if (std.c.getgrgid(st.gid)) |gr| {
                            if (gr.name) |name| {
                                output.appendSlice(allocator, std.mem.span(name)) catch {};
                            }
                        } else {
                            var buf: [32]u8 = undefined;
                            const str = std.fmt.bufPrint(&buf, "{d}", .{st.gid}) catch "";
                            output.appendSlice(allocator, str) catch {};
                        }
                    }
                },
                'y' => {
                    if (pstat.get()) |st| {
                        output.append(allocator, fileTypeCharShort(@intCast(st.mode))) catch {};
                    }
                },
                'i' => {
                    if (pstat.get()) |st| {
                        var buf: [32]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "{d}", .{st.ino}) catch "";
                        output.appendSlice(allocator, str) catch {};
                    }
                },
                'n' => {
                    if (pstat.get()) |st| {
                        var buf: [16]u8 = undefined;
                        const str = std.fmt.bufPrint(&buf, "{d}", .{st.nlink}) catch "";
                        output.appendSlice(allocator, str) catch {};
                    }
                },
                'T' => {
                    // Time format: %T@ = seconds since epoch, %T+ = ISO-like, %TY = year, etc.
                    if (i + 1 < format.len) {
                        i += 1;
                        const time_esc = format[i];
                        if (fstat.get()) |st| {
                            const mtime_sec: i64 = @intCast(@divFloor(st.mtime, std.time.ns_per_s));
                            switch (time_esc) {
                                '@' => {
                                    var buf: [32]u8 = undefined;
                                    const str = std.fmt.bufPrint(&buf, "{d}.{d}", .{ mtime_sec, @divFloor(@mod(st.mtime, std.time.ns_per_s), 1000000) }) catch "";
                                    output.appendSlice(allocator, str) catch {};
                                },
                                '+' => {
                                    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(mtime_sec) };
                                    const epoch_day = epoch.getEpochDay();
                                    const year_day = epoch_day.calculateYearDay();
                                    const month_day = year_day.calculateMonthDay();
                                    const day_secs = epoch.getDaySeconds();
                                    var buf: [64]u8 = undefined;
                                    const str = std.fmt.bufPrint(&buf, "{d}-{d:0>2}-{d:0>2}+{d:0>2}:{d:0>2}:{d:0>2}", .{
                                        year_day.year,
                                        month_day.month,
                                        month_day.day_index + 1,
                                        day_secs.getHoursIntoDay(),
                                        day_secs.getMinutesIntoHour(),
                                        day_secs.getSecondsIntoMinute(),
                                    }) catch "";
                                    output.appendSlice(allocator, str) catch {};
                                },
                                'Y' => {
                                    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(mtime_sec) };
                                    const year_day = epoch.getEpochDay().calculateYearDay();
                                    var buf: [16]u8 = undefined;
                                    const str = std.fmt.bufPrint(&buf, "{d}", .{year_day.year}) catch "";
                                    output.appendSlice(allocator, str) catch {};
                                },
                                'm' => {
                                    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(mtime_sec) };
                                    const month_day = epoch.getEpochDay().calculateYearDay().calculateMonthDay();
                                    var buf: [8]u8 = undefined;
                                    const str = std.fmt.bufPrint(&buf, "{d:0>2}", .{month_day.month}) catch "";
                                    output.appendSlice(allocator, str) catch {};
                                },
                                'd' => {
                                    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(mtime_sec) };
                                    const month_day = epoch.getEpochDay().calculateYearDay().calculateMonthDay();
                                    var buf: [8]u8 = undefined;
                                    const str = std.fmt.bufPrint(&buf, "{d:0>2}", .{month_day.day_index + 1}) catch "";
                                    output.appendSlice(allocator, str) catch {};
                                },
                                'H' => {
                                    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(mtime_sec) };
                                    var buf: [8]u8 = undefined;
                                    const str = std.fmt.bufPrint(&buf, "{d:0>2}", .{epoch.getDaySeconds().getHoursIntoDay()}) catch "";
                                    output.appendSlice(allocator, str) catch {};
                                },
                                'M' => {
                                    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(mtime_sec) };
                                    var buf: [8]u8 = undefined;
                                    const str = std.fmt.bufPrint(&buf, "{d:0>2}", .{epoch.getDaySeconds().getMinutesIntoHour()}) catch "";
                                    output.appendSlice(allocator, str) catch {};
                                },
                                'S' => {
                                    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(mtime_sec) };
                                    var buf: [8]u8 = undefined;
                                    const str = std.fmt.bufPrint(&buf, "{d:0>2}", .{epoch.getDaySeconds().getSecondsIntoMinute()}) catch "";
                                    output.appendSlice(allocator, str) catch {};
                                },
                                else => {
                                    output.append(allocator, '%') catch {};
                                    output.append(allocator, 'T') catch {};
                                    output.append(allocator, time_esc) catch {};
                                },
                            }
                        }
                    }
                },
                't' => output.append(allocator, '\t') catch {},
                'r' => output.append(allocator, '\r') catch {},
                'a' => output.append(allocator, '\x07') catch {},
                'b' => output.append(allocator, '\x08') catch {},
                'c' => output.append(allocator, ' ') catch {},
                '0'...'7' => {
                    // Octal escape: \0NNN where NNN is 1-3 octal digits
                    var octal_val: u8 = 0;
                    var j: usize = 0;
                    while (j < 3 and i + j < format.len and format[i + j] >= '0' and format[i + j] <= '7') : (j += 1) {
                        octal_val = octal_val * 8 + (format[i + j] - '0');
                    }
                    if (j > 0) {
                        output.append(allocator, octal_val) catch {};
                        i += j - 1;
                    } else {
                        output.append(allocator, '%') catch {};
                        output.append(allocator, esc) catch {};
                    }
                },
                '%' => output.append(allocator, '%') catch {},
                '\\' => output.append(allocator, '\\') catch {},
                else => {
                    output.append(allocator, '%') catch {};
                    output.append(allocator, esc) catch {};
                },
            }
        } else if (format[i] == '\\' and i + 1 < format.len) {
            i += 1;
            const esc = format[i];
            switch (esc) {
                'n' => output.append(allocator, '\n') catch {},
                't' => output.append(allocator, '\t') catch {},
                'r' => output.append(allocator, '\r') catch {},
                'a' => output.append(allocator, '\x07') catch {},
                'b' => output.append(allocator, '\x08') catch {},
                'c' => output.append(allocator, ' ') catch {},
                'f' => output.append(allocator, '\x0c') catch {},
                '0'...'7' => {
                    var octal_val: u8 = 0;
                    var j: usize = 0;
                    while (j < 3 and i + j < format.len and format[i + j] >= '0' and format[i + j] <= '7') : (j += 1) {
                        octal_val = octal_val * 8 + (format[i + j] - '0');
                    }
                    if (j > 0) {
                        output.append(allocator, octal_val) catch {};
                        i += j - 1;
                    } else {
                        output.append(allocator, '\\') catch {};
                        output.append(allocator, esc) catch {};
                    }
                },
                else => {
                    output.append(allocator, '\\') catch {};
                    output.append(allocator, esc) catch {};
                },
            }
        } else {
            output.append(allocator, format[i]) catch {};
        }
    }

    _ = std.posix.write(std.posix.STDOUT_FILENO, output.items) catch {};
}

/// Format a POSIX mode into ls -l style string (e.g., "-rw-r--r--")
fn formatMode(mode: u32) [10]u8 {
    var result: [10]u8 = undefined;
    // File type
    result[0] = switch (mode & 0o170000) {
        0o040000 => 'd',
        0o100000 => '-',
        0o120000 => 'l',
        0o020000 => 'c',
        0o060000 => 'b',
        0o010000 => 'p',
        0o140000 => 's',
        else => '?',
    };
    // Owner permissions
    result[1] = if (mode & 0o400 != 0) 'r' else '-';
    result[2] = if (mode & 0o200 != 0) 'w' else '-';
    result[3] = if (mode & 0o4000 != 0) 's' else if (mode & 0o100 != 0) 'x' else '-';
    // Group permissions
    result[4] = if (mode & 0o040 != 0) 'r' else '-';
    result[5] = if (mode & 0o020 != 0) 'w' else '-';
    result[6] = if (mode & 0o2000 != 0) 's' else if (mode & 0o010 != 0) 'x' else '-';
    // Other permissions
    result[7] = if (mode & 0o004 != 0) 'r' else '-';
    result[8] = if (mode & 0o002 != 0) 'w' else '-';
    result[9] = if (mode & 0o1000 != 0) 't' else if (mode & 0o001 != 0) 'x' else '-';
    return result;
}

/// Print detailed listing like `ls -dils` for a file
fn printDetailedListing(path: []const u8, allocator: std.mem.Allocator) void {
    // Use statFile to get standard fs.Stat, then use POSIX stat for detailed fields
    const stat = std.fs.cwd().statFile(path) catch return;

    const c_path = allocator.dupeZ(u8, path) catch return;
    defer allocator.free(c_path);
    var pst: std.posix.Stat = undefined;
    if (std.c.stat(c_path, &pst) != 0) return;

    const mode_str = formatMode(@intCast(pst.mode));
    const nlink = pst.nlink;
    const uid = pst.uid;
    const gid = pst.gid;
    const size = pst.size;
    const ino = pst.ino;
    const blocks = pst.blocks;

    // Format time like ls -l: "Mon DD HH:MM" or "Mon DD  YYYY"
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const mtime_sec: i64 = @intCast(@divFloor(stat.mtime, std.time.ns_per_s));
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(mtime_sec) };
    const epoch_day = epoch.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch.getDaySeconds();

    var time_buf: [64]u8 = undefined;
    const time_str = blk: {
        const now = std.time.timestamp();
        const age_seconds = now - mtime_sec;
        const six_months: i64 = 6 * 30 * 24 * 3600;
        const month_idx = @intFromEnum(month_day.month) - 1;
        if (@abs(age_seconds) > six_months) {
            break :blk std.fmt.bufPrint(&time_buf, "{s} {: >2}  {d}", .{
                months[month_idx],
                month_day.day_index + 1,
                year_day.year,
            }) catch "??? ??  ????";
        } else {
            break :blk std.fmt.bufPrint(&time_buf, "{s} {: >2} {:0>2}:{:0>2}", .{
                months[month_idx],
                month_day.day_index + 1,
                day_secs.getHoursIntoDay(),
                day_secs.getMinutesIntoHour(),
            }) catch "??? ?? ??:??";
        }
    };

    // Look up user and group names (fallback to numeric IDs)
    var uname_buf: [64]u8 = undefined;
    var gname_buf: [64]u8 = undefined;
    const uname = std.fmt.bufPrint(&uname_buf, "{d}", .{uid}) catch "?";
    const gname = std.fmt.bufPrint(&gname_buf, "{d}", .{gid}) catch "?";

    const basename = std.fs.path.basename(path);

    // Format: ino blocks mode nlink owner group size time basename
    var output_buf: [4096]u8 = undefined;
    const output = std.fmt.bufPrint(&output_buf, "{d} {d} {s} {d} {s} {s} {d} {s} {s}\n", .{
        ino,
        @divFloor(blocks, 2), // GNU find -ls uses 1K blocks; st.blocks is 512-byte blocks
        &mode_str,
        nlink,
        uname,
        gname,
        size,
        time_str,
        basename,
    }) catch return;

    _ = std.posix.write(std.posix.STDOUT_FILENO, output) catch {};
}

fn performAction(path: []const u8, options: FindOptions, allocator: std.mem.Allocator) void {
    if (options.delete_matched) {
        deletePath(path);
    } else if (options.exec_command) |cmd| {
        // Build command args, replacing {} with path
        var child_args: std.ArrayListUnmanaged([]const u8) = .{};
        defer child_args.deinit(allocator);
        for (cmd) |arg| {
            if (std.mem.eql(u8, arg, "{}")) {
                child_args.append(allocator, path) catch {};
            } else {
                child_args.append(allocator, arg) catch {};
            }
        }
        if (child_args.items.len > 0) {
            var child = std.process.Child.init(child_args.items, allocator);
            _ = child.spawnAndWait() catch {};
        }
    } else if (options.ok_command) |cmd| {
        // Build command line for display
        var display_buf: [4096]u8 = undefined;
        var db_pos: usize = 0;
        for (cmd, 0..) |arg, idx| {
            if (idx > 0) {
                if (db_pos < display_buf.len) { display_buf[db_pos] = ' '; db_pos += 1; }
            }
            const a = if (std.mem.eql(u8, arg, "{}")) path else arg;
            if (db_pos + a.len < display_buf.len) {
                @memcpy(display_buf[db_pos..db_pos + a.len], a);
                db_pos += a.len;
            }
        }
        const display = display_buf[0..db_pos];
        _ = std.posix.write(std.posix.STDOUT_FILENO, display) catch {};
        _ = std.posix.write(std.posix.STDOUT_FILENO, " ? ") catch {};

        // Read one character from stdin
        var buf: [1]u8 = undefined;
        const bytes_read = std.posix.read(std.posix.STDIN_FILENO, &buf) catch 0;
        if (bytes_read > 0 and (buf[0] == 'y' or buf[0] == 'Y')) {
            // Build command args, replacing {} with path
            var child_args: std.ArrayListUnmanaged([]const u8) = .{};
            defer child_args.deinit(allocator);
            for (cmd) |arg| {
                if (std.mem.eql(u8, arg, "{}")) {
                    child_args.append(allocator, path) catch {};
                } else {
                    child_args.append(allocator, arg) catch {};
                }
            }
            if (child_args.items.len > 0) {
                var child = std.process.Child.init(child_args.items, allocator);
                _ = child.spawnAndWait() catch {};
            }
        }
        // Consume rest of line
        while (true) {
            var discard: [1]u8 = undefined;
            const n = std.posix.read(std.posix.STDIN_FILENO, &discard) catch break;
            if (n == 0 or discard[0] == '\n') break;
        }
    } else if (options.execdir_command) |cmd| {
        // Execute in the file's parent directory, replacing {} with basename
        const basename = std.fs.path.basename(path);
        const dirname = std.fs.path.dirname(path) orelse ".";
        var child_args: std.ArrayListUnmanaged([]const u8) = .{};
        defer child_args.deinit(allocator);
        for (cmd) |arg| {
            if (std.mem.eql(u8, arg, "{}")) {
                child_args.append(allocator, basename) catch {};
            } else {
                child_args.append(allocator, arg) catch {};
            }
        }
        if (child_args.items.len > 0) {
            // Save original cwd, chdir to parent, spawn child, restore cwd
            const original_cwd = std.process.getCwdAlloc(allocator) catch null;
            defer if (original_cwd) |ocwd| allocator.free(ocwd);
            _ = std.posix.chdir(dirname) catch {};
            var child = std.process.Child.init(child_args.items, allocator);
            _ = child.spawnAndWait() catch {};
            if (original_cwd) |ocwd| {
                _ = std.posix.chdir(ocwd) catch {};
            }
        }
    } else if (options.okdir_command) |cmd| {
        // Like -ok but runs in file's parent directory with basename
        const basename = std.fs.path.basename(path);
        const dirname = std.fs.path.dirname(path) orelse ".";
        // Build command line for display
        var display_buf: [4096]u8 = undefined;
        var db_pos: usize = 0;
        for (cmd, 0..) |arg, idx| {
            if (idx > 0) {
                if (db_pos < display_buf.len) { display_buf[db_pos] = ' '; db_pos += 1; }
            }
            const a = if (std.mem.eql(u8, arg, "{}")) basename else arg;
            if (db_pos + a.len < display_buf.len) {
                @memcpy(display_buf[db_pos..db_pos + a.len], a);
                db_pos += a.len;
            }
        }
        const display = display_buf[0..db_pos];
        _ = std.posix.write(std.posix.STDOUT_FILENO, display) catch {};
        _ = std.posix.write(std.posix.STDOUT_FILENO, " ? ") catch {};

        // Read one character from stdin
        var buf: [1]u8 = undefined;
        const bytes_read = std.posix.read(std.posix.STDIN_FILENO, &buf) catch 0;
        if (bytes_read > 0 and (buf[0] == 'y' or buf[0] == 'Y')) {
            var child_args: std.ArrayListUnmanaged([]const u8) = .{};
            defer child_args.deinit(allocator);
            for (cmd) |arg| {
                if (std.mem.eql(u8, arg, "{}")) {
                    child_args.append(allocator, basename) catch {};
                } else {
                    child_args.append(allocator, arg) catch {};
                }
            }
            if (child_args.items.len > 0) {
                const original_cwd = std.process.getCwdAlloc(allocator) catch null;
                defer if (original_cwd) |ocwd| allocator.free(ocwd);
                _ = std.posix.chdir(dirname) catch {};
                var child = std.process.Child.init(child_args.items, allocator);
                _ = child.spawnAndWait() catch {};
                if (original_cwd) |ocwd| {
                    _ = std.posix.chdir(ocwd) catch {};
                }
            }
        }
        // Consume rest of line
        while (true) {
            var discard: [1]u8 = undefined;
            const n = std.posix.read(std.posix.STDIN_FILENO, &discard) catch break;
            if (n == 0 or discard[0] == '\n') break;
        }
    } else if (options.list_detailed) {
        printDetailedListing(path, allocator);
    } else if (options.fprintf_file) |outfile| {
        if (options.fprintf_format) |fmt| {
            printFormattedToFile(path, fmt, outfile, allocator);
        }
    } else if (options.fprint_file) |outfile| {
        printPathToFile(path, options.print0, outfile);
    } else if (options.printf_format) |fmt| {
        printFormatted(path, fmt, allocator);
    } else {
        printPath(path, options.print0);
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
        \\GPU-accelerated file search in directory hierarchies.
        \\Default path is current directory. Use - to read paths from stdin.
        \\
        \\Tests (Pattern Matching):                        [GPU+SIMD]
        \\  -name PATTERN     Base of file name matches shell PATTERN
        \\  -iname PATTERN    Like -name but case-insensitive
        \\  -path PATTERN     File path matches shell PATTERN
        \\  -ipath PATTERN    Like -path but case-insensitive
        \\
        \\Tests (File Type):                               [CPU]
        \\  -type TYPE        File is of type TYPE:
        \\                      f  regular file
        \\                      d  directory
        \\                      l  symbolic link
        \\                      b  block device
        \\                      c  character device
        \\                      p  named pipe (FIFO)
        \\                      s  socket
        \\
        \\Tests (File Attributes):                         [CPU]
        \\  -empty             File is empty (0 size for files, no entries for dirs)
        \\  -size [+-]N[ckMG]  File uses N units of space:
        \\                      c  bytes, k  kibibytes, M  mebibytes, G  gibibytes
        \\                      (default: 512-byte blocks)
        \\                      +N  greater than N, -N  less than N
        \\  -mtime [+-]N       File modified N*24 hours ago (+N older, -N newer)
        \\  -atime [+-]N       File accessed N*24 hours ago
        \\  -ctime [+-]N       File status changed N*24 hours ago
        \\  -mmin [+-]N        File modified N minutes ago
        \\  -amin [+-]N         File accessed N minutes ago
        \\  -cmin [+-]N         File status changed N minutes ago
        \\  -newer FILE        File is newer than FILE (modification time)
        \\  -newerXY FILE      File time X newer than reference time Y
        \\                      X,Y: a=access, c=change, m=modify
        \\  -prune PATTERN     Do not descend into directories matching PATTERN
        \\  -exec CMD \;       Execute CMD for each matched file (replace {} with path)
        \\  -ok CMD \;        Like -exec but prompts user before each execution
        \\  -execdir CMD \;   Like -exec but runs CMD in file's parent directory
        \\  -ls               Detailed listing of each file (like ls -dils)
        \\  -delete            Delete matched files/directories
        \\  -not, !            Negate the following test
        \\  -maxdepth LEVELS  Descend at most LEVELS of directories
        \\  -mindepth LEVELS  Skip tests at levels less than LEVELS
        \\  -print0           Print paths followed by NUL instead of newline
        \\  -count            Print count of matches (extension)
        \\  --auto            Auto-select optimal backend (default)
        \\  --gpu             Force GPU (Metal on macOS, Vulkan on Linux)
        \\  --cpu             Force CPU backend (SIMD-optimized)
        \\  --metal           Force Metal backend (macOS only)
        \\  --vulkan          Force Vulkan backend
        \\  -v, --verbose     Print backend and timing information
        \\  -h, --help        Display this help and exit
        \\      --version     Output version information and exit
        \\  *      matches any string (including empty)
        \\  ?      matches any single character
        \\  [abc]  matches any character in the set
        \\  [a-z]  matches any character in the range
        \\  [!abc] matches any character NOT in the set
        \\  [GPU+SIMD] Pattern matching uses GPU compute shaders (Metal/Vulkan)
        \\             for parallel glob evaluation. CPU fallback uses 16/32-byte
        \\             SIMD vector operations for accelerated string comparison.
        \\  [CPU]      File type and attribute tests require filesystem syscalls
        \\             and cannot be GPU-accelerated.
        \\  10K files:   ~4x faster
        \\  100K files:  ~7x faster
        \\  1M files:    ~10x faster
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
    const time_exact = parseTimeArg("5", .modified, false);
    try std.testing.expect(time_exact != null);
    try std.testing.expectEqual(@as(i64, 5), time_exact.?.days);
    try std.testing.expectEqual(TimeComparison.exact, time_exact.?.comparison);
    try std.testing.expectEqual(TimeType.modified, time_exact.?.time_type);

    // Different time types
    const time_atime = parseTimeArg("3", .accessed, false);
    try std.testing.expect(time_atime != null);
    try std.testing.expectEqual(TimeType.accessed, time_atime.?.time_type);

    const time_ctime = parseTimeArg("7", .changed, false);
    try std.testing.expect(time_ctime != null);
    try std.testing.expectEqual(TimeType.changed, time_ctime.?.time_type);
}

test "parseTimeArg: comparison operators" {
    // More than N days ago (older)
    const time_older = parseTimeArg("+7", .modified, false);
    try std.testing.expect(time_older != null);
    try std.testing.expectEqual(TimeComparison.older, time_older.?.comparison);
    try std.testing.expectEqual(@as(i64, 7), time_older.?.days);

    // Less than N days ago (newer)
    const time_newer = parseTimeArg("-1", .modified, false);
    try std.testing.expect(time_newer != null);
    try std.testing.expectEqual(TimeComparison.newer, time_newer.?.comparison);
    try std.testing.expectEqual(@as(i64, 1), time_newer.?.days);
}

test "parseTimeArg: invalid inputs" {
    try std.testing.expect(parseTimeArg("", .modified, false) == null);
    try std.testing.expect(parseTimeArg("+", .modified, false) == null);
    try std.testing.expect(parseTimeArg("abc", .modified, false) == null);
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
