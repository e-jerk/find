const std = @import("std");
const gpu = @import("gpu");

// SIMD vector types for optimal performance
const Vec16 = @Vector(16, u8);
const Vec32 = @Vector(32, u8);

// Constants for vectorized operations
const UPPER_A_VEC16: Vec16 = @splat('A');
const UPPER_Z_VEC16: Vec16 = @splat('Z');
const CASE_DIFF_VEC16: Vec16 = @splat(32);
const SLASH_VEC32: Vec32 = @splat('/');

/// CPU-based glob pattern matching with SIMD optimization
/// Implements fnmatch-like behavior for -name/-iname/-path/-ipath
pub fn matchNames(
    names: []const []const u8,
    pattern: []const u8,
    options: gpu.MatchOptions,
    allocator: std.mem.Allocator,
) !gpu.BatchMatchResult {
    var matches: std.ArrayListUnmanaged(gpu.MatchResult) = .{};
    errdefer matches.deinit(allocator);

    // Pre-compute lowercase pattern if case insensitive
    var lower_pattern_buf: [1024]u8 = undefined;
    const search_pattern = if (options.case_insensitive and pattern.len <= 1024) blk: {
        toLowerSlice(pattern, lower_pattern_buf[0..pattern.len]);
        break :blk lower_pattern_buf[0..pattern.len];
    } else pattern;

    for (names, 0..) |name, i| {
        const match_str = if (options.match_path)
            name
        else
            basenameSIMD(name);

        if (globMatchSIMD(search_pattern, match_str, options)) {
            try matches.append(allocator, .{
                .name_idx = @intCast(i),
                .matched = 1,
            });
        }
    }

    const total = matches.items.len;
    return gpu.BatchMatchResult{
        .matches = try matches.toOwnedSlice(allocator),
        .total_matches = total,
        .allocator = allocator,
    };
}

/// SIMD-optimized basename finder (find last '/')
fn basenameSIMD(path: []const u8) []const u8 {
    if (path.len == 0) return path;

    var last_slash: usize = 0;
    var found_slash = false;
    var i: usize = 0;

    // Search 32 bytes at a time
    while (i + 32 <= path.len) {
        const chunk: Vec32 = path[i..][0..32].*;
        const slashes = chunk == SLASH_VEC32;

        if (@reduce(.Or, slashes)) {
            // Find the last slash in this chunk
            for (0..32) |j| {
                if (path[i + j] == '/') {
                    last_slash = i + j;
                    found_slash = true;
                }
            }
        }
        i += 32;
    }

    // Handle remaining bytes
    while (i < path.len) {
        if (path[i] == '/') {
            last_slash = i;
            found_slash = true;
        }
        i += 1;
    }

    if (found_slash) {
        return path[last_slash + 1 ..];
    }
    return path;
}

/// Vectorized lowercase conversion for Vec16
inline fn toLowerVec16(v: Vec16) Vec16 {
    const is_upper = (v >= UPPER_A_VEC16) & (v <= UPPER_Z_VEC16);
    return @select(u8, is_upper, v + CASE_DIFF_VEC16, v);
}

/// Scalar lowercase conversion
inline fn toLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Convert slice to lowercase using SIMD
inline fn toLowerSlice(src: []const u8, dst: []u8) void {
    var i: usize = 0;
    // Process 16 bytes at a time
    while (i + 16 <= src.len) {
        const vec: Vec16 = src[i..][0..16].*;
        const lower = toLowerVec16(vec);
        dst[i..][0..16].* = lower;
        i += 16;
    }
    // Handle remaining bytes
    while (i < src.len) {
        dst[i] = toLower(src[i]);
        i += 1;
    }
}

/// SIMD-optimized glob pattern matching (fnmatch-like)
/// Supports: * (any sequence), ? (any single char), [abc] (char class), [a-z] (range)
pub fn globMatchSIMD(pattern: []const u8, name: []const u8, options: gpu.MatchOptions) bool {
    return globMatchImpl(pattern, name, options.case_insensitive, options.match_period, 0);
}

fn globMatchImpl(pattern: []const u8, name: []const u8, case_insensitive: bool, match_period: bool, name_start: usize) bool {
    var pi: usize = 0; // pattern index
    var ni: usize = 0; // name index
    var star_pi: ?usize = null; // position of last * in pattern
    var star_ni: usize = 0; // position in name when * was seen

    // Handle leading period rule
    if (match_period and name.len > 0 and ni == name_start and name[ni] == '.') {
        if (pattern.len == 0 or pattern[0] != '.') {
            return false;
        }
    }

    while (ni < name.len) {
        if (pi < pattern.len) {
            const pc = pattern[pi];
            const nc = name[ni];

            if (pc == '*') {
                // Star matches zero or more characters
                star_pi = pi;
                star_ni = ni;
                pi += 1;
                continue;
            } else if (pc == '?') {
                // Question mark matches exactly one character
                // But not a leading period if match_period is set
                if (match_period and ni == name_start and nc == '.') {
                    if (star_pi) |sp| {
                        pi = sp + 1;
                        star_ni += 1;
                        ni = star_ni;
                        continue;
                    }
                    return false;
                }
                pi += 1;
                ni += 1;
                continue;
            } else if (pc == '[') {
                // Character class
                const class_result = matchCharClassSIMD(pattern[pi..], nc, case_insensitive);
                if (class_result.matched) {
                    pi += class_result.consumed;
                    ni += 1;
                    continue;
                } else if (class_result.consumed > 0) {
                    // Valid class but didn't match
                    if (star_pi) |sp| {
                        pi = sp + 1;
                        star_ni += 1;
                        ni = star_ni;
                        continue;
                    }
                    return false;
                }
                // Invalid class, treat [ as literal
                if (charMatchFast(pc, nc, case_insensitive)) {
                    pi += 1;
                    ni += 1;
                    continue;
                }
            } else {
                // Regular character match - fast path for common case
                if (charMatchFast(pc, nc, case_insensitive)) {
                    pi += 1;
                    ni += 1;
                    continue;
                }
            }
        }

        // No match - try backtracking to last *
        if (star_pi) |sp| {
            pi = sp + 1;
            star_ni += 1;
            ni = star_ni;
            continue;
        }

        return false;
    }

    // Skip trailing stars in pattern
    while (pi < pattern.len and pattern[pi] == '*') {
        pi += 1;
    }

    return pi == pattern.len;
}

const CharClassResult = struct {
    matched: bool,
    consumed: usize,
};

fn matchCharClassSIMD(pattern: []const u8, char: u8, case_insensitive: bool) CharClassResult {
    if (pattern.len < 2 or pattern[0] != '[') {
        return .{ .matched = false, .consumed = 0 };
    }

    var i: usize = 1;
    var negated = false;
    var matched = false;

    // Check for negation
    if (i < pattern.len and (pattern[i] == '!' or pattern[i] == '^')) {
        negated = true;
        i += 1;
    }

    // Special case: ] as first character in class
    if (i < pattern.len and pattern[i] == ']') {
        if (charMatchFast(']', char, case_insensitive)) {
            matched = true;
        }
        i += 1;
    }

    const test_c = if (case_insensitive) toLower(char) else char;

    // Match characters in class
    while (i < pattern.len and pattern[i] != ']') {
        // Handle range (e.g., a-z)
        if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
            const range_start = pattern[i];
            const range_end = pattern[i + 2];

            const rs = if (case_insensitive) toLower(range_start) else range_start;
            const re = if (case_insensitive) toLower(range_end) else range_end;

            if (test_c >= rs and test_c <= re) {
                matched = true;
            }
            i += 3;
        } else {
            const pc = if (case_insensitive) toLower(pattern[i]) else pattern[i];
            if (test_c == pc) {
                matched = true;
            }
            i += 1;
        }
    }

    // Check if we found closing ]
    if (i >= pattern.len) {
        // Unclosed class - invalid
        return .{ .matched = false, .consumed = 0 };
    }

    // Skip the closing ]
    i += 1;

    if (negated) matched = !matched;

    return .{ .matched = matched, .consumed = i };
}

/// Fast character comparison with case handling
inline fn charMatchFast(pattern_c: u8, name_c: u8, case_insensitive: bool) bool {
    if (case_insensitive) {
        return toLower(pattern_c) == toLower(name_c);
    }
    return pattern_c == name_c;
}

// Alias for backward compatibility
pub const globMatch = globMatchSIMD;

// Tests
test "glob match - exact" {
    try std.testing.expect(globMatchSIMD("hello", "hello", .{}));
    try std.testing.expect(!globMatchSIMD("hello", "world", .{}));
}

test "glob match - star" {
    try std.testing.expect(globMatchSIMD("*.txt", "file.txt", .{}));
    try std.testing.expect(globMatchSIMD("*.txt", ".txt", .{}));
    try std.testing.expect(!globMatchSIMD("*.txt", "file.doc", .{}));
    try std.testing.expect(globMatchSIMD("file*", "file.txt", .{}));
    try std.testing.expect(globMatchSIMD("*", "anything", .{}));
    try std.testing.expect(globMatchSIMD("a*b*c", "aXXbYYc", .{}));
}

test "glob match - question" {
    try std.testing.expect(globMatchSIMD("?.txt", "a.txt", .{}));
    try std.testing.expect(!globMatchSIMD("?.txt", "ab.txt", .{}));
    try std.testing.expect(globMatchSIMD("file.???", "file.txt", .{}));
}

test "glob match - character class" {
    try std.testing.expect(globMatchSIMD("[abc]", "a", .{}));
    try std.testing.expect(globMatchSIMD("[abc]", "b", .{}));
    try std.testing.expect(!globMatchSIMD("[abc]", "d", .{}));
    try std.testing.expect(globMatchSIMD("[a-z]", "m", .{}));
    try std.testing.expect(!globMatchSIMD("[a-z]", "M", .{}));
    try std.testing.expect(globMatchSIMD("[!abc]", "d", .{}));
    try std.testing.expect(!globMatchSIMD("[!abc]", "a", .{}));
}

test "glob match - case insensitive" {
    try std.testing.expect(globMatchSIMD("HELLO", "hello", .{ .case_insensitive = true }));
    try std.testing.expect(globMatchSIMD("*.TXT", "file.txt", .{ .case_insensitive = true }));
    try std.testing.expect(!globMatchSIMD("HELLO", "hello", .{ .case_insensitive = false }));
}

test "glob match - leading period" {
    try std.testing.expect(!globMatchSIMD("*", ".hidden", .{ .match_period = true }));
    try std.testing.expect(globMatchSIMD(".*", ".hidden", .{ .match_period = true }));
    try std.testing.expect(globMatchSIMD("*", ".hidden", .{ .match_period = false }));
}
