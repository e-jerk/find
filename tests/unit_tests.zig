const std = @import("std");
const build_options = @import("build_options");
const gpu = @import("gpu");
const cpu = @import("cpu");

const MatchOptions = gpu.MatchOptions;

// ============================================================================
// Unit Tests for find
// Tests basic glob pattern matching with small inputs
// ============================================================================

// ----------------------------------------------------------------------------
// CPU Tests - Glob Pattern Matching
// ----------------------------------------------------------------------------

test "cpu: exact match" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ "hello.txt", "world.txt", "hello.txt" };

    var result = try cpu.matchNames(&names, "hello.txt", .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "cpu: wildcard star" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ "file.txt", "file.doc", "other.txt" };

    var result = try cpu.matchNames(&names, "*.txt", .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "cpu: wildcard question" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ "a.txt", "ab.txt", "abc.txt" };

    var result = try cpu.matchNames(&names, "?.txt", .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
}

test "cpu: character class" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ "a.txt", "b.txt", "c.txt", "d.txt" };

    var result = try cpu.matchNames(&names, "[abc].txt", .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "cpu: character range" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ "1.txt", "5.txt", "9.txt", "a.txt" };

    var result = try cpu.matchNames(&names, "[0-5].txt", .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "cpu: case insensitive" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ "Hello.TXT", "hello.txt", "HELLO.txt" };

    var result = try cpu.matchNames(&names, "hello.txt", .{ .case_insensitive = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "cpu: no matches" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ "file.txt", "file.doc" };

    var result = try cpu.matchNames(&names, "*.pdf", .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 0), result.total_matches);
}

test "cpu: match all" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ "a", "b", "c" };

    var result = try cpu.matchNames(&names, "*", .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 3), result.total_matches);
}

test "cpu: basename matching from path" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ "/path/to/file.txt", "/other/path/file.txt", "/path/file.doc" };

    // When match_path=false, should match basename only
    var result = try cpu.matchNames(&names, "file.txt", .{ .match_path = false }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "cpu: full path matching" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ "/path/to/file.txt", "/other/path/file.txt" };

    // When match_path=true, should match full path
    var result = try cpu.matchNames(&names, "*/to/*", .{ .match_path = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
}

test "cpu: hidden files" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ ".hidden", "visible", ".bashrc" };

    // With match_period=true, * shouldn't match leading dot
    var result = try cpu.matchNames(&names, "*", .{ .match_period = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 1), result.total_matches);
}

test "cpu: hidden files explicit match" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ ".hidden", "visible", ".bashrc" };

    // Explicit dot pattern should match hidden files
    var result = try cpu.matchNames(&names, ".*", .{ .match_period = true }, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

// ----------------------------------------------------------------------------
// Metal GPU Tests (macOS only)
// ----------------------------------------------------------------------------

test "metal: shader compilation" {
    if (!build_options.is_macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    const matcher = gpu.metal.MetalMatcher.init(allocator) catch |err| {
        std.debug.print("Metal init failed: {}\n", .{err});
        return err;
    };
    defer matcher.deinit();

    // If we get here, shader compiled successfully
}

test "metal: simple pattern match" {
    if (!build_options.is_macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    const matcher = gpu.metal.MetalMatcher.init(allocator) catch |err| {
        std.debug.print("Metal init failed: {}\n", .{err});
        return err;
    };
    defer matcher.deinit();

    const names = [_][]const u8{ "file.txt", "file.doc", "other.txt" };

    var result = try matcher.matchNames(&names, "*.txt", .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "metal: matches cpu results" {
    if (!build_options.is_macos) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    const matcher = gpu.metal.MetalMatcher.init(allocator) catch |err| {
        std.debug.print("Metal init failed: {}\n", .{err});
        return err;
    };
    defer matcher.deinit();

    const test_cases = [_]struct {
        names: []const []const u8,
        pattern: []const u8,
        options: MatchOptions,
    }{
        .{ .names = &[_][]const u8{ "a.txt", "b.txt", "c.doc" }, .pattern = "*.txt", .options = .{} },
        .{ .names = &[_][]const u8{ "Hello.txt", "hello.txt" }, .pattern = "hello.txt", .options = .{ .case_insensitive = true } },
        .{ .names = &[_][]const u8{ "file1", "file2", "file3" }, .pattern = "file?", .options = .{} },
    };

    for (test_cases) |tc| {
        var cpu_result = try cpu.matchNames(tc.names, tc.pattern, tc.options, allocator);
        defer cpu_result.deinit();

        var metal_result = try matcher.matchNames(tc.names, tc.pattern, tc.options, allocator);
        defer metal_result.deinit();

        if (cpu_result.total_matches != metal_result.total_matches) {
            std.debug.print("\nMismatch for pattern '{s}':\n", .{tc.pattern});
            std.debug.print("  CPU: {d}, Metal: {d}\n", .{ cpu_result.total_matches, metal_result.total_matches });
            return error.MatchCountMismatch;
        }
    }
}

// ----------------------------------------------------------------------------
// Vulkan GPU Tests
// ----------------------------------------------------------------------------

test "vulkan: shader compilation" {
    const allocator = std.testing.allocator;

    const matcher = gpu.vulkan.VulkanMatcher.init(allocator) catch |err| {
        std.debug.print("Vulkan init failed: {}\n", .{err});
        return err;
    };
    defer matcher.deinit();

    // If we get here, shader loaded successfully
}

test "vulkan: simple pattern match" {
    const allocator = std.testing.allocator;

    const matcher = gpu.vulkan.VulkanMatcher.init(allocator) catch |err| {
        std.debug.print("Vulkan init failed: {}\n", .{err});
        return err;
    };
    defer matcher.deinit();

    const names = [_][]const u8{ "file.txt", "file.doc", "other.txt" };

    var result = try matcher.matchNames(&names, "*.txt", .{}, allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u64, 2), result.total_matches);
}

test "vulkan: matches cpu results" {
    const allocator = std.testing.allocator;

    const matcher = gpu.vulkan.VulkanMatcher.init(allocator) catch |err| {
        std.debug.print("Vulkan init failed: {}\n", .{err});
        return err;
    };
    defer matcher.deinit();

    const test_cases = [_]struct {
        names: []const []const u8,
        pattern: []const u8,
        options: MatchOptions,
    }{
        .{ .names = &[_][]const u8{ "a.txt", "b.txt", "c.doc" }, .pattern = "*.txt", .options = .{} },
        .{ .names = &[_][]const u8{ "Hello.txt", "hello.txt" }, .pattern = "hello.txt", .options = .{ .case_insensitive = true } },
        .{ .names = &[_][]const u8{ "file1", "file2", "file3" }, .pattern = "file?", .options = .{} },
    };

    for (test_cases) |tc| {
        var cpu_result = try cpu.matchNames(tc.names, tc.pattern, tc.options, allocator);
        defer cpu_result.deinit();

        var vulkan_result = try matcher.matchNames(tc.names, tc.pattern, tc.options, allocator);
        defer vulkan_result.deinit();

        if (cpu_result.total_matches != vulkan_result.total_matches) {
            std.debug.print("\nMismatch for pattern '{s}':\n", .{tc.pattern});
            std.debug.print("  CPU: {d}, Vulkan: {d}\n", .{ cpu_result.total_matches, vulkan_result.total_matches });
            return error.MatchCountMismatch;
        }
    }
}
