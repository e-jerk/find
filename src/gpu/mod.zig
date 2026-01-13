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

// Configuration
pub const BATCH_SIZE: usize = 64 * 1024; // 64K filenames per batch
pub const MAX_GPU_BUFFER_SIZE: usize = 64 * 1024 * 1024; // 64MB max buffer
pub const MIN_GPU_SIZE: usize = 1024; // Minimum 1024 filenames for GPU
pub const MAX_NAME_LEN: u32 = 4096; // Maximum filename length
pub const MAX_PATTERN_LEN: u32 = 1024; // Maximum pattern length

pub const EMBEDDED_METAL_SHADER = if (build_options.is_macos) @import("metal_shader").EMBEDDED_METAL_SHADER else "";

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
