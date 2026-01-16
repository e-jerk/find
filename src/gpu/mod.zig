const std = @import("std");
const build_options = @import("build_options");

// Import e_jerk_gpu library for GPU detection and auto-selection
pub const e_jerk_gpu = @import("e_jerk_gpu");

// Re-export library types for use across gfind
pub const GpuCapabilities = e_jerk_gpu.GpuCapabilities;
pub const AutoSelector = e_jerk_gpu.AutoSelector;
pub const AutoSelectConfig = e_jerk_gpu.AutoSelectConfig;
pub const WorkloadInfo = e_jerk_gpu.WorkloadInfo;
pub const SelectionResult = e_jerk_gpu.SelectionResult;

pub const metal = if (build_options.is_macos) @import("metal.zig") else struct {
    pub const MetalMatcher = void;
};
pub const vulkan = @import("vulkan.zig");
pub const regex_compiler = @import("regex_compiler.zig");
pub const regex = @import("regex");

// Configuration
pub const BATCH_SIZE: usize = 64 * 1024; // 64K filenames per batch
pub const MAX_GPU_BUFFER_SIZE: usize = 64 * 1024 * 1024; // 64MB max buffer
pub const MIN_GPU_SIZE: usize = 1024; // Minimum 1024 filenames for GPU
pub const MAX_NAME_LEN: u32 = 4096; // Maximum filename length
pub const MAX_PATTERN_LEN: u32 = 1024; // Maximum pattern length

// Regex constants
pub const MAX_REGEX_STATES: usize = 256;
pub const BITMAP_WORDS_PER_CLASS: u32 = 8;

pub const EMBEDDED_METAL_SHADER = if (build_options.is_macos) @import("metal_shader").EMBEDDED_METAL_SHADER else "";
pub const EMBEDDED_SPIRV_REGEX = @import("spirv_regex").EMBEDDED_SPIRV_REGEX;

// Match flags
pub const MatchFlags = struct {
    pub const CASE_INSENSITIVE: u32 = 1;
    pub const MATCH_PATH: u32 = 2; // Match full path instead of basename
    pub const PERIOD: u32 = 4; // Leading period must be matched explicitly
};

// Match configuration (must match shader struct layout)
pub const MatchConfig = extern struct {
    num_names: u32,
    pattern_len: u32,
    flags: u32,
    max_name_len: u32,
    names_offset: u32,
    names_lengths_offset: u32,
    _pad1: u32 = 0,
    _pad2: u32 = 0,
};

// Result for each filename (must match shader struct layout)
pub const MatchResult = extern struct {
    name_idx: u32,
    matched: u32,
    _pad1: u32 = 0,
    _pad2: u32 = 0,
};

// Match options
pub const MatchOptions = struct {
    case_insensitive: bool = false,
    match_path: bool = false, // If false, match basename only
    match_period: bool = true, // Leading period must be matched explicitly

    pub fn toFlags(self: MatchOptions) u32 {
        var flags: u32 = 0;
        if (self.case_insensitive) flags |= MatchFlags.CASE_INSENSITIVE;
        if (self.match_path) flags |= MatchFlags.MATCH_PATH;
        if (self.match_period) flags |= MatchFlags.PERIOD;
        return flags;
    }
};

// Match result from GPU
pub const BatchMatchResult = struct {
    matches: []MatchResult,
    total_matches: u64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *BatchMatchResult) void {
        self.allocator.free(self.matches);
    }
};

// Use library's Backend enum
pub const Backend = e_jerk_gpu.Backend;

pub fn detectBestBackend() Backend {
    if (build_options.is_macos) return .metal;
    return .vulkan;
}

pub fn shouldUseGpu(num_names: usize) bool {
    return num_names >= MIN_GPU_SIZE;
}

pub fn formatBytes(bytes: usize) struct { value: f64, unit: []const u8 } {
    if (bytes >= 1024 * 1024 * 1024) return .{ .value = @as(f64, @floatFromInt(bytes)) / (1024 * 1024 * 1024), .unit = "GB" };
    if (bytes >= 1024 * 1024) return .{ .value = @as(f64, @floatFromInt(bytes)) / (1024 * 1024), .unit = "MB" };
    if (bytes >= 1024) return .{ .value = @as(f64, @floatFromInt(bytes)) / 1024, .unit = "KB" };
    return .{ .value = @as(f64, @floatFromInt(bytes)), .unit = "B" };
}

// ============================================================================
// Regex Types for GPU (Thompson NFA)
// ============================================================================

/// State types for Thompson NFA (must match shader)
pub const RegexStateType = enum(u8) {
    literal = 0,
    char_class = 1,
    dot = 2,
    split = 3,
    match_state = 4,
    group_start = 5,
    group_end = 6,
    word_boundary = 7,
    not_word_boundary = 8,
    line_start = 9,
    line_end = 10,
    any = 11,
};

/// GPU regex state (packed for efficient GPU transfer)
/// Layout: [type:8][flags:8][out:16] [out2:16][literal:8][group_idx:8] [bitmap_offset:32]
pub const RegexState = extern struct {
    type: u8,
    flags: u8,
    out: u16,
    out2: u16,
    literal_char: u8,
    group_idx: u8,
    bitmap_offset: u32,

    pub const FLAG_CASE_INSENSITIVE: u8 = 1;
    pub const FLAG_NEGATED: u8 = 2;
};

/// Regex header with metadata
pub const RegexHeader = extern struct {
    num_states: u32,
    start_state: u32,
    num_groups: u32,
    flags: u32,

    pub const FLAG_ANCHORED_START: u32 = 1;
    pub const FLAG_ANCHORED_END: u32 = 2;
    pub const FLAG_CASE_INSENSITIVE: u32 = 4;
};

/// Configuration for regex matching on GPU
pub const RegexMatchConfig = extern struct {
    num_names: u32,
    num_states: u32,
    start_state: u32,
    header_flags: u32,
    num_bitmaps: u32,
    flags: u32,
    _pad1: u32 = 0,
    _pad2: u32 = 0,
};
