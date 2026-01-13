const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const gpu = @import("gpu");
const cpu = @import("cpu");

const MatchOptions = gpu.MatchOptions;
const MatchResult = gpu.MatchResult;
const BatchMatchResult = gpu.BatchMatchResult;

/// Smoke test results
const TestResult = struct {
    name: []const u8,
    passed: bool,
    cpu_throughput_kps: f64, // thousands of paths per second
    metal_throughput_kps: ?f64,
    vulkan_throughput_kps: ?f64,
    expected_matches: u64,
    cpu_matches: u64,
    metal_matches: ?u64,
    vulkan_matches: ?u64,
};

/// Test case definition
const TestCase = struct {
    name: []const u8,
    pattern: []const u8,
    options: MatchOptions,
    path_generator: *const fn (std.mem.Allocator, usize) anyerror![][]const u8,
    expected_match_ratio: f64,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Default test size: 50K paths for thorough testing
    var num_paths: usize = 50000;
    var iterations: usize = 3;

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--paths") and i + 1 < args.len) {
            i += 1;
            num_paths = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--iterations") and i + 1 < args.len) {
            i += 1;
            iterations = try std.fmt.parseInt(usize, args[i], 10);
        }
    }

    std.debug.print("\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("                    FIND SMOKE TESTS\n", .{});
    std.debug.print("        Based on GNU find test patterns for real-world use cases\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});
    std.debug.print("Configuration:\n", .{});
    std.debug.print("  Number of paths: {d}\n", .{num_paths});
    std.debug.print("  Iterations:      {d}\n\n", .{iterations});

    const test_cases = [_]TestCase{
        // Test 1: Simple extension matching (-name "*.txt")
        .{
            .name = "extension_txt",
            .pattern = "*.txt",
            .options = .{},
            .path_generator = generateMixedExtensions,
            .expected_match_ratio = 0.1,
        },
        // Test 2: Case-insensitive matching (-iname "*.JPG")
        .{
            .name = "case_insensitive_jpg",
            .pattern = "*.JPG",
            .options = .{ .case_insensitive = true },
            .path_generator = generateImageFiles,
            .expected_match_ratio = 0.25,
        },
        // Test 3: Full path matching (-path "*src/*.c")
        .{
            .name = "path_src_c",
            .pattern = "*src/*.c",
            .options = .{ .match_path = true },
            .path_generator = generateCodePaths,
            .expected_match_ratio = 0.05,
        },
        // Test 4: Single character wildcard (-name "?.txt")
        .{
            .name = "single_char_wildcard",
            .pattern = "?.txt",
            .options = .{},
            .path_generator = generateShortNames,
            .expected_match_ratio = 0.1,
        },
        // Test 5: Character class (-name "[a-f]*.log")
        .{
            .name = "char_class_log",
            .pattern = "[a-f]*.log",
            .options = .{},
            .path_generator = generateLogFiles,
            .expected_match_ratio = 0.15,
        },
        // Test 6: Negated character class (-name "[!0-9]*")
        .{
            .name = "negated_char_class",
            .pattern = "[!0-9]*",
            .options = .{},
            .path_generator = generateMixedNames,
            .expected_match_ratio = 0.7,
        },
        // Test 7: Complex pattern (-name "test_*_v[0-9].txt")
        .{
            .name = "complex_pattern",
            .pattern = "test_*_v[0-9].txt",
            .options = .{},
            .path_generator = generateTestFiles,
            .expected_match_ratio = 0.05,
        },
        // Test 8: Hidden files (-name ".*")
        .{
            .name = "hidden_files",
            .pattern = ".*",
            .options = .{ .match_period = false },
            .path_generator = generateHiddenFiles,
            .expected_match_ratio = 0.2,
        },
    };

    var results: [test_cases.len]TestResult = undefined;
    var all_passed = true;

    for (test_cases, 0..) |tc, test_idx| {
        std.debug.print("-" ** 70 ++ "\n", .{});
        std.debug.print("Test {d}/{d}: {s}\n", .{ test_idx + 1, test_cases.len, tc.name });
        std.debug.print("  Pattern: \"{s}\" | Options: case_i={}, match_path={}, match_period={}\n", .{
            tc.pattern,
            tc.options.case_insensitive,
            tc.options.match_path,
            tc.options.match_period,
        });
        std.debug.print("-" ** 70 ++ "\n", .{});

        const paths = try tc.path_generator(allocator, num_paths);
        defer {
            for (paths) |p| allocator.free(p);
            allocator.free(paths);
        }

        results[test_idx] = try runTest(allocator, tc.name, paths, tc.pattern, tc.options, iterations);

        if (!results[test_idx].passed) all_passed = false;

        std.debug.print("  Result: {s}\n\n", .{if (results[test_idx].passed) "PASS" else "FAIL"});
    }

    // Print summary
    std.debug.print("\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("                         RESULTS SUMMARY\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    std.debug.print("{s:<20} {s:>8} {s:>12} {s:>12} {s:>12} {s:>8}\n", .{
        "Test Name",
        "Status",
        "CPU (K/s)",
        "Metal (K/s)",
        "Vulkan (K/s)",
        "Speedup",
    });
    std.debug.print("{s:-<20} {s:->8} {s:->12} {s:->12} {s:->12} {s:->8}\n", .{ "", "", "", "", "", "" });

    var max_cpu: f64 = 0;
    var max_metal: f64 = 0;
    var max_vulkan: f64 = 0;

    for (results) |r| {
        const status = if (r.passed) "PASS" else "FAIL";

        if (r.metal_throughput_kps) |m| max_metal = @max(max_metal, m);
        if (r.vulkan_throughput_kps) |v| max_vulkan = @max(max_vulkan, v);
        max_cpu = @max(max_cpu, r.cpu_throughput_kps);

        const best_gpu = @max(r.metal_throughput_kps orelse 0, r.vulkan_throughput_kps orelse 0);
        const speedup = if (best_gpu > 0) best_gpu / r.cpu_throughput_kps else 1.0;

        var metal_buf: [16]u8 = undefined;
        var vulkan_buf: [16]u8 = undefined;
        const metal_formatted = if (r.metal_throughput_kps) |m|
            std.fmt.bufPrint(&metal_buf, "{d:.1}", .{m}) catch "N/A"
        else
            "N/A";
        const vulkan_formatted = if (r.vulkan_throughput_kps) |v|
            std.fmt.bufPrint(&vulkan_buf, "{d:.1}", .{v}) catch "N/A"
        else
            "N/A";

        std.debug.print("{s:<20} {s:>8} {d:>12.1} {s:>12} {s:>12} {d:>7.1}x\n", .{
            r.name,
            status,
            r.cpu_throughput_kps,
            metal_formatted,
            vulkan_formatted,
            speedup,
        });
    }

    std.debug.print("\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("                      MAXIMUM THROUGHPUT\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});
    std.debug.print("  CPU:    {d:.1} K paths/s\n", .{max_cpu});
    if (max_metal > 0) {
        std.debug.print("  Metal:  {d:.1} K paths/s - {d:.1}x CPU\n", .{ max_metal, max_metal / max_cpu });
    }
    if (max_vulkan > 0) {
        std.debug.print("  Vulkan: {d:.1} K paths/s - {d:.1}x CPU\n", .{ max_vulkan, max_vulkan / max_cpu });
    }
    std.debug.print("=" ** 70 ++ "\n\n", .{});

    if (all_passed) {
        std.debug.print("All smoke tests PASSED!\n\n", .{});
    } else {
        std.debug.print("Some smoke tests FAILED!\n\n", .{});
        std.process.exit(1);
    }
}

fn runTest(
    allocator: std.mem.Allocator,
    name: []const u8,
    paths: [][]const u8,
    pattern: []const u8,
    options: MatchOptions,
    iterations: usize,
) !TestResult {
    var result = TestResult{
        .name = name,
        .passed = true,
        .cpu_throughput_kps = 0,
        .metal_throughput_kps = null,
        .vulkan_throughput_kps = null,
        .expected_matches = 0,
        .cpu_matches = 0,
        .metal_matches = null,
        .vulkan_matches = null,
    };

    // Run CPU benchmark
    std.debug.print("  CPU benchmark...\n", .{});
    const cpu_stats = try benchmarkCpu(allocator, paths, pattern, options, iterations);
    result.cpu_throughput_kps = cpu_stats.throughput_kps;
    result.cpu_matches = cpu_stats.matches;
    result.expected_matches = cpu_stats.matches;
    std.debug.print("    Throughput: {d:.1} K paths/s, Matches: {d}\n", .{ cpu_stats.throughput_kps, cpu_stats.matches });

    // Run Metal benchmark (macOS only)
    if (build_options.is_macos) {
        std.debug.print("  Metal benchmark...\n", .{});
        if (benchmarkMetal(allocator, paths, pattern, options, iterations)) |metal_stats| {
            result.metal_throughput_kps = metal_stats.throughput_kps;
            result.metal_matches = metal_stats.matches;
            std.debug.print("    Throughput: {d:.1} K paths/s, Matches: {d}\n", .{ metal_stats.throughput_kps, metal_stats.matches });

            // Verify correctness
            if (metal_stats.matches != result.expected_matches) {
                std.debug.print("    WARNING: Metal match count mismatch! Expected {d}, got {d}\n", .{ result.expected_matches, metal_stats.matches });
                result.passed = false;
            }
        } else |_| {
            std.debug.print("    Metal unavailable\n", .{});
        }
    }

    // Run Vulkan benchmark
    std.debug.print("  Vulkan benchmark...\n", .{});
    if (benchmarkVulkan(allocator, paths, pattern, options, iterations)) |vulkan_stats| {
        result.vulkan_throughput_kps = vulkan_stats.throughput_kps;
        result.vulkan_matches = vulkan_stats.matches;
        std.debug.print("    Throughput: {d:.1} K paths/s, Matches: {d}\n", .{ vulkan_stats.throughput_kps, vulkan_stats.matches });

        // Verify correctness
        if (vulkan_stats.matches != result.expected_matches) {
            std.debug.print("    WARNING: Vulkan match count mismatch! Expected {d}, got {d}\n", .{ result.expected_matches, vulkan_stats.matches });
            result.passed = false;
        }
    } else |_| {
        std.debug.print("    Vulkan unavailable\n", .{});
    }

    return result;
}

const BenchStats = struct {
    throughput_kps: f64,
    matches: u64,
};

fn benchmarkCpu(
    allocator: std.mem.Allocator,
    paths: [][]const u8,
    pattern: []const u8,
    options: MatchOptions,
    iterations: usize,
) !BenchStats {
    var total_time: i64 = 0;
    var matches: u64 = 0;

    for (0..iterations) |_| {
        const start = std.time.milliTimestamp();
        var result = try cpu.matchNames(paths, pattern, options, allocator);
        const elapsed = std.time.milliTimestamp() - start;
        matches = result.total_matches;
        result.deinit();
        total_time += elapsed;
    }

    const avg_time_ms = @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(iterations));
    const throughput = @as(f64, @floatFromInt(paths.len)) / (avg_time_ms / 1000.0) / 1000.0;

    return BenchStats{ .throughput_kps = throughput, .matches = matches };
}

fn benchmarkMetal(
    allocator: std.mem.Allocator,
    paths: [][]const u8,
    pattern: []const u8,
    options: MatchOptions,
    iterations: usize,
) !BenchStats {
    if (!build_options.is_macos) return error.NotAvailable;

    const matcher = gpu.metal.MetalMatcher.init(allocator) catch return error.InitFailed;
    defer matcher.deinit();

    var total_time: i64 = 0;
    var matches: u64 = 0;

    for (0..iterations) |_| {
        const start = std.time.milliTimestamp();
        var result = try matcher.matchNames(paths, pattern, options, allocator);
        const elapsed = std.time.milliTimestamp() - start;
        matches = result.total_matches;
        result.deinit();
        total_time += elapsed;
    }

    const avg_time_ms = @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(iterations));
    const throughput = @as(f64, @floatFromInt(paths.len)) / (avg_time_ms / 1000.0) / 1000.0;

    return BenchStats{ .throughput_kps = throughput, .matches = matches };
}

fn benchmarkVulkan(
    allocator: std.mem.Allocator,
    paths: [][]const u8,
    pattern: []const u8,
    options: MatchOptions,
    iterations: usize,
) !BenchStats {
    const matcher = gpu.vulkan.VulkanMatcher.init(allocator) catch return error.InitFailed;
    defer matcher.deinit();

    var total_time: i64 = 0;
    var matches: u64 = 0;

    for (0..iterations) |_| {
        const start = std.time.milliTimestamp();
        var result = try matcher.matchNames(paths, pattern, options, allocator);
        const elapsed = std.time.milliTimestamp() - start;
        matches = result.total_matches;
        result.deinit();
        total_time += elapsed;
    }

    const avg_time_ms = @as(f64, @floatFromInt(total_time)) / @as(f64, @floatFromInt(iterations));
    const throughput = @as(f64, @floatFromInt(paths.len)) / (avg_time_ms / 1000.0) / 1000.0;

    return BenchStats{ .throughput_kps = throughput, .matches = matches };
}

// Path generators for different test scenarios

fn generateMixedExtensions(allocator: std.mem.Allocator, count: usize) ![][]const u8 {
    const extensions = [_][]const u8{ ".txt", ".c", ".h", ".py", ".js", ".rs", ".zig", ".md", ".json", ".yaml" };
    const dirs = [_][]const u8{ "src", "lib", "tests", "docs", "config", "data" };

    return generatePaths(allocator, count, &dirs, &extensions);
}

fn generateImageFiles(allocator: std.mem.Allocator, count: usize) ![][]const u8 {
    const extensions = [_][]const u8{ ".jpg", ".JPG", ".jpeg", ".JPEG", ".png", ".PNG", ".gif", ".GIF", ".bmp", ".svg" };
    const dirs = [_][]const u8{ "images", "photos", "assets", "media", "uploads" };

    return generatePaths(allocator, count, &dirs, &extensions);
}

fn generateCodePaths(allocator: std.mem.Allocator, count: usize) ![][]const u8 {
    const extensions = [_][]const u8{ ".c", ".h", ".cpp", ".hpp", ".py", ".js", ".ts", ".rs", ".go", ".java" };
    const dirs = [_][]const u8{ "src", "lib", "include", "pkg", "cmd", "internal", "vendor", "third_party" };

    return generatePaths(allocator, count, &dirs, &extensions);
}

fn generateShortNames(allocator: std.mem.Allocator, count: usize) ![][]const u8 {
    const paths = try allocator.alloc([]const u8, count);
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();

    const short_names = [_][]const u8{ "a", "b", "c", "d", "e", "f", "ab", "cd", "ef", "gh", "abc", "def" };
    const extensions = [_][]const u8{ ".txt", ".log", ".dat", ".tmp", ".bak" };

    for (paths, 0..) |*p, idx| {
        const name = short_names[random.intRangeAtMost(usize, 0, short_names.len - 1)];
        const ext = extensions[random.intRangeAtMost(usize, 0, extensions.len - 1)];

        var buf: [256]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "dir{d}/{s}{s}", .{ idx % 10, name, ext }) catch unreachable;
        p.* = try allocator.dupe(u8, buf[0..len.len]);
    }

    return paths;
}

fn generateLogFiles(allocator: std.mem.Allocator, count: usize) ![][]const u8 {
    const paths = try allocator.alloc([]const u8, count);
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();

    const prefixes = [_][]const u8{ "app", "error", "access", "debug", "system", "auth", "audit", "backup" };
    const extensions = [_][]const u8{ ".log", ".txt", ".out", ".err" };

    for (paths, 0..) |*p, idx| {
        const prefix = prefixes[random.intRangeAtMost(usize, 0, prefixes.len - 1)];
        const ext = extensions[random.intRangeAtMost(usize, 0, extensions.len - 1)];

        var buf: [256]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "logs/{s}_{d}{s}", .{ prefix, idx, ext }) catch unreachable;
        p.* = try allocator.dupe(u8, buf[0..len.len]);
    }

    return paths;
}

fn generateMixedNames(allocator: std.mem.Allocator, count: usize) ![][]const u8 {
    const paths = try allocator.alloc([]const u8, count);
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();

    for (paths, 0..) |*p, idx| {
        var buf: [256]u8 = undefined;
        const first_char: u8 = if (random.intRangeAtMost(u8, 0, 9) < 3)
            '0' + random.intRangeAtMost(u8, 0, 9)
        else
            'a' + random.intRangeAtMost(u8, 0, 25);

        const len = std.fmt.bufPrint(&buf, "data/{c}file_{d}.dat", .{ first_char, idx }) catch unreachable;
        p.* = try allocator.dupe(u8, buf[0..len.len]);
    }

    return paths;
}

fn generateTestFiles(allocator: std.mem.Allocator, count: usize) ![][]const u8 {
    const paths = try allocator.alloc([]const u8, count);
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();

    const test_types = [_][]const u8{ "unit", "integration", "e2e", "smoke", "perf", "stress" };
    const extensions = [_][]const u8{ ".txt", ".json", ".xml", ".yaml" };

    for (paths, 0..) |*p, idx| {
        const test_type = test_types[random.intRangeAtMost(usize, 0, test_types.len - 1)];
        const ext = extensions[random.intRangeAtMost(usize, 0, extensions.len - 1)];
        const version = random.intRangeAtMost(u8, 0, 9);

        var buf: [256]u8 = undefined;
        // Some paths match "test_*_v[0-9].txt", others don't
        const len = if (random.intRangeAtMost(u8, 0, 19) == 0)
            std.fmt.bufPrint(&buf, "tests/test_{s}_v{d}.txt", .{ test_type, version }) catch unreachable
        else
            std.fmt.bufPrint(&buf, "tests/{s}_{d}{s}", .{ test_type, idx, ext }) catch unreachable;

        p.* = try allocator.dupe(u8, buf[0..len.len]);
    }

    return paths;
}

fn generateHiddenFiles(allocator: std.mem.Allocator, count: usize) ![][]const u8 {
    const paths = try allocator.alloc([]const u8, count);
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();

    const hidden_names = [_][]const u8{ ".gitignore", ".env", ".bashrc", ".zshrc", ".vimrc", ".config", ".cache" };
    const normal_names = [_][]const u8{ "README", "LICENSE", "Makefile", "config", "data", "output" };

    for (paths, 0..) |*p, idx| {
        var buf: [256]u8 = undefined;
        const is_hidden = random.intRangeAtMost(u8, 0, 4) == 0;
        const name = if (is_hidden)
            hidden_names[random.intRangeAtMost(usize, 0, hidden_names.len - 1)]
        else
            normal_names[random.intRangeAtMost(usize, 0, normal_names.len - 1)];

        const len = std.fmt.bufPrint(&buf, "project{d}/{s}", .{ idx % 20, name }) catch unreachable;
        p.* = try allocator.dupe(u8, buf[0..len.len]);
    }

    return paths;
}

fn generatePaths(
    allocator: std.mem.Allocator,
    count: usize,
    dirs: []const []const u8,
    extensions: []const []const u8,
) ![][]const u8 {
    const paths = try allocator.alloc([]const u8, count);
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    const random = prng.random();

    for (paths, 0..) |*p, idx| {
        const dir = dirs[random.intRangeAtMost(usize, 0, dirs.len - 1)];
        const ext = extensions[random.intRangeAtMost(usize, 0, extensions.len - 1)];

        var buf: [256]u8 = undefined;
        const len = std.fmt.bufPrint(&buf, "{s}/file_{d}{s}", .{ dir, idx, ext }) catch unreachable;
        p.* = try allocator.dupe(u8, buf[0..len.len]);
    }

    return paths;
}
