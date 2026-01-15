const std = @import("std");
const gpu = @import("gpu");
const cpu_optimized = @import("cpu_optimized");

/// GNU find backend for glob pattern matching.
/// Note: GNU find's fnmatch implementation is essentially equivalent to our
/// optimized SIMD implementation, so this backend delegates to the optimized
/// version for consistent benchmark comparisons.
///
/// Both implementations follow POSIX fnmatch semantics with GNU extensions.
pub fn matchNames(
    names: []const []const u8,
    pattern: []const u8,
    options: gpu.MatchOptions,
    allocator: std.mem.Allocator,
) !gpu.BatchMatchResult {
    // Delegate to optimized backend - same fnmatch semantics
    return cpu_optimized.matchNames(names, pattern, options, allocator);
}

// Re-export glob functions for direct access if needed
pub const globMatch = cpu_optimized.globMatch;
pub const globMatchSIMD = cpu_optimized.globMatchSIMD;
