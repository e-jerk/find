const std = @import("std");
const mtl = @import("zig-metal");
const mod = @import("mod.zig");
const regex_compiler = @import("regex_compiler.zig");
const regex_lib = @import("regex");

const MatchConfig = mod.MatchConfig;
const MatchResult = mod.MatchResult;
const MatchOptions = mod.MatchOptions;
const BatchMatchResult = mod.BatchMatchResult;
const RegexMatchConfig = mod.RegexMatchConfig;
const RegexState = mod.RegexState;
const RegexHeader = mod.RegexHeader;
const EMBEDDED_METAL_SHADER = mod.EMBEDDED_METAL_SHADER;
const MAX_GPU_BUFFER_SIZE = mod.MAX_GPU_BUFFER_SIZE;

// Access low-level Metal device methods for memory queries
const DeviceMixin = mtl.gen.MTLDeviceProtocolMixin(mtl.gen.MTLDevice, "MTLDevice");

pub const MetalMatcher = struct {
    device: mtl.MTLDevice,
    command_queue: mtl.MTLCommandQueue,
    glob_pipeline: mtl.MTLComputePipelineState,
    regex_pipeline: mtl.MTLComputePipelineState,
    allocator: std.mem.Allocator,
    threads_per_group: usize,
    capabilities: mod.GpuCapabilities,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const device = mtl.createSystemDefaultDevice() orelse return error.NoMetalDevice;
        errdefer device.release();

        const command_queue = device.newCommandQueue() orelse return error.NoCommandQueue;
        errdefer command_queue.release();

        const source_ns = mtl.NSString.stringWithUTF8String(EMBEDDED_METAL_SHADER.ptr);
        var library = device.newLibraryWithSourceOptionsError(source_ns, null, null) orelse return error.ShaderCompileFailed;
        defer library.release();

        // Create glob matching pipeline
        const glob_func_name = mtl.NSString.stringWithUTF8String("match_names");
        var glob_func = library.newFunctionWithName(glob_func_name) orelse return error.FunctionNotFound;
        defer glob_func.release();
        const glob_pipeline = device.newComputePipelineStateWithFunctionError(glob_func, null) orelse return error.PipelineCreationFailed;

        // Create regex matching pipeline
        const regex_func_name = mtl.NSString.stringWithUTF8String("regex_match_names");
        var regex_func = library.newFunctionWithName(regex_func_name) orelse return error.FunctionNotFound;
        defer regex_func.release();
        const regex_pipeline = device.newComputePipelineStateWithFunctionError(regex_func, null) orelse return error.PipelineCreationFailed;

        // Query actual hardware attributes from Metal API
        const max_threads = glob_pipeline.maxTotalThreadsPerThreadgroup();
        const threads_to_use: usize = @min(256, max_threads);

        // Query actual memory from Metal API (deterministic, not inferred)
        const recommended_memory = DeviceMixin.recommendedMaxWorkingSetSize(device.ptr);
        const max_buffer_len = DeviceMixin.maxBufferLength(device.ptr);
        const has_unified = DeviceMixin.hasUnifiedMemory(device.ptr) != 0;

        // Apple Silicon with unified memory is high-performance
        const is_high_perf = has_unified and max_threads >= 1024;

        const capabilities = mod.GpuCapabilities{
            // safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)
            .max_threads_per_group = @intCast(max_threads),
            .max_buffer_size = @min(max_buffer_len, MAX_GPU_BUFFER_SIZE),
            .recommended_memory = recommended_memory,
            .is_discrete = is_high_perf,
            .device_type = if (is_high_perf) .discrete else .integrated,
        };

        const self = try safe.Box(Self).init(allocator, undefined);
        self[0] = Self{
            .device = device,
            .command_queue = command_queue,
            .glob_pipeline = glob_pipeline,
            .regex_pipeline = regex_pipeline,
            .allocator = allocator,
            .threads_per_group = threads_to_use,
            .capabilities = capabilities,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.regex_pipeline.release();
        self.glob_pipeline.release();
        self.command_queue.release();
        self.device.release();
        self.allocator.destroy(self);
    }

    // safe-transpile: function uses raw slice parameter — consider safe.String
    pub fn matchNames(
        self: *Self,
        names: []const []const u8,
        pattern: []const u8,
        options: MatchOptions,
        allocator: std.mem.Allocator,
    ) !BatchMatchResult {
        if (names.len == 0) {
            return BatchMatchResult{
                .matches = &[_]MatchResult{},
                .total_matches = 0,
                .allocator = allocator,
            };
        }

        // safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)
        const num_names: u32 = @intCast(names.len);

        // Calculate total size needed for names data
        var total_names_size: usize = 0;
        for (names) |name| {
            total_names_size += name.len;
        }

        // Prepare name offsets and lengths
        const name_offsets = try allocator.alloc(u32, names.len);
        // safe-transpile: free removed (memory owned by safe type);
        const name_lengths = try allocator.alloc(u32, names.len);
        // safe-transpile: free removed (memory owned by safe type);

        // Prepare packed names data
        const names_data = try allocator.alloc(u8, total_names_size);
        // safe-transpile: free removed (memory owned by safe type);

        var offset: u32 = 0;
        // safe-transpile: for with index access requires manual review
        for (names, 0..) |name, i| {
            name_offsets[i] = offset;
            // safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)
            name_lengths[i] = @intCast(name.len);
            safe.SimdUtils.copy(names_data[offset..][0..name.len], name);
            // safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)
            offset += @intCast(name.len);
        }

        // Create config
        const config = MatchConfig{
            .num_names = num_names,
            // safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)
            .pattern_len = @intCast(pattern.len),
            .flags = options.toFlags(),
            .max_name_len = mod.MAX_NAME_LEN,
            .names_offset = 0,
            .names_lengths_offset = 0,
        };

        // Create Metal buffers using the correct API pattern
        // Config buffer
        var config_buffer = self.device.newBufferWithLengthOptions(@sizeOf(MatchConfig), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer config_buffer.release();
        if (config_buffer.contents()) |ptr| {
            const config_ptr: *MatchConfig = // safe-transpile: @ptrCast requires manual review — add @alignCast if alignment is guaranteed
                @ptrCast(@alignCast(ptr));
            config_ptr[0] = config;
        }

        // Pattern buffer
        var pattern_buffer = self.device.newBufferWithLengthOptions(pattern.len, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer pattern_buffer.release();
        if (pattern_buffer.contents()) |ptr| {
            const pattern_ptr: [*]u8 = // safe-transpile: @ptrCast requires manual review — add @alignCast if alignment is guaranteed
                @ptrCast(ptr);
            safe.SimdUtils.copy(pattern_ptr[0..pattern.len], pattern);
        }

        // Names data buffer
        var names_buffer = self.device.newBufferWithLengthOptions(names_data.len, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer names_buffer.release();
        if (names_buffer.contents()) |ptr| {
            const names_ptr: [*]u8 = // safe-transpile: @ptrCast requires manual review — add @alignCast if alignment is guaranteed
                @ptrCast(ptr);
            safe.SimdUtils.copy(names_ptr[0..names_data.len], names_data);
        }

        // Name offsets buffer
        var offsets_buffer = self.device.newBufferWithLengthOptions(name_offsets.len * @sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer offsets_buffer.release();
        if (offsets_buffer.contents()) |ptr| {
            const offsets_ptr: [*]u32 = // safe-transpile: @ptrCast requires manual review — add @alignCast if alignment is guaranteed
                @ptrCast(@alignCast(ptr));
            safe.SimdUtils.copy(offsets_ptr[0..name_offsets.len], name_offsets);
        }

        // Name lengths buffer
        var lengths_buffer = self.device.newBufferWithLengthOptions(name_lengths.len * @sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer lengths_buffer.release();
        if (lengths_buffer.contents()) |ptr| {
            const lengths_ptr: [*]u32 = // safe-transpile: @ptrCast requires manual review — add @alignCast if alignment is guaranteed
                @ptrCast(@alignCast(ptr));
            safe.SimdUtils.copy(lengths_ptr[0..name_lengths.len], name_lengths);
        }

        // Results buffer
        const results_size = names.len * @sizeOf(MatchResult);
        var results_buffer = self.device.newBufferWithLengthOptions(results_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer results_buffer.release();

        // Match count buffer (atomic counter)
        var count_buffer = self.device.newBufferWithLengthOptions(@sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer count_buffer.release();
        if (count_buffer.contents()) |ptr| {
            const count_ptr: *u32 = // safe-transpile: @ptrCast requires manual review — add @alignCast if alignment is guaranteed
                @ptrCast(@alignCast(ptr));
            count_ptr[0] = 0;
        }

        // Create command buffer and encoder
        var command_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        var encoder = command_buffer.computeCommandEncoder() orelse return error.EncoderFailed;

        encoder.setComputePipelineState(self.glob_pipeline);
        encoder.setBufferOffsetAtIndex(config_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(pattern_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(names_buffer, 0, 2);
        encoder.setBufferOffsetAtIndex(offsets_buffer, 0, 3);
        encoder.setBufferOffsetAtIndex(lengths_buffer, 0, 4);
        encoder.setBufferOffsetAtIndex(results_buffer, 0, 5);
        encoder.setBufferOffsetAtIndex(count_buffer, 0, 6);

        // Dispatch one thread per filename
        const grid_size = mtl.MTLSize{ .width = names.len, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = self.threads_per_group, .height = 1, .depth = 1 };

        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);

        encoder.endEncoding();
        command_buffer.commit();
        command_buffer.waitUntilCompleted();

        // Read results
        const results_ptr: [*]MatchResult = // safe-transpile: @ptrCast requires manual review — add @alignCast if alignment is guaranteed
            @ptrCast(@alignCast(results_buffer.contents()));
        const count_ptr: *u32 = // safe-transpile: @ptrCast requires manual review — add @alignCast if alignment is guaranteed
            @ptrCast(@alignCast(count_buffer.contents()));
        const total_matches = count_ptr.*;

        // Copy matching results
        const matches = try allocator.alloc(MatchResult, total_matches);
        var match_idx: usize = 0;
        for (0..names.len) |i| {
            if (results_ptr[i].matched != 0) {
                matches[match_idx] = results_ptr[i];
                match_idx += 1;
            }
        }

        return BatchMatchResult{
            .matches = matches,
            .total_matches = total_matches,
            .allocator = allocator,
        };
    }

    /// Match filenames against a regex pattern using GPU Thompson NFA
    // safe-transpile: function uses raw slice parameter — consider safe.String
    pub fn matchNamesRegex(
        self: *Self,
        names: []const []const u8,
        pattern: []const u8,
        options: MatchOptions,
        allocator: std.mem.Allocator,
    ) !BatchMatchResult {
        if (names.len == 0) {
            return BatchMatchResult{
                .matches = &[_]MatchResult{},
                .total_matches = 0,
                .allocator = allocator,
            };
        }

        // Compile regex for GPU execution
        var compiled = try regex_compiler.compileForGpu(pattern, .{
            .case_insensitive = options.case_insensitive,
        }, allocator);
        defer compiled.deinit();

        // safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)
        const num_names: u32 = @intCast(names.len);

        // Calculate total size needed for names data
        var total_names_size: usize = 0;
        for (names) |name| {
            total_names_size += name.len;
        }

        // Prepare name offsets and lengths
        const name_offsets = try allocator.alloc(u32, names.len);
        // safe-transpile: free removed (memory owned by safe type);
        const name_lengths = try allocator.alloc(u32, names.len);
        // safe-transpile: free removed (memory owned by safe type);

        // Prepare packed names data
        const names_data = try allocator.alloc(u8, total_names_size);
        // safe-transpile: free removed (memory owned by safe type);

        var offset: u32 = 0;
        // safe-transpile: for with index access requires manual review
        for (names, 0..) |name, i| {
            name_offsets[i] = offset;
            // safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)
            name_lengths[i] = @intCast(name.len);
            safe.SimdUtils.copy(names_data[offset..][0..name.len], name);
            // safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)
            offset += @intCast(name.len);
        }

        // Pack regex states for GPU (3 u32 words per state)
        const states_data = try allocator.alloc(u32, compiled.states.len * 3);
        // safe-transpile: free removed (memory owned by safe type);
        // safe-transpile: for with index access requires manual review
        for (compiled.states, 0..) |state, i| {
            const base = i * 3;
            // Word 0: [type:8][flags:8][out:16]
            states_data[base] = @as(u32, state.type) |
                (@as(u32, state.flags) << 8) |
                (@as(u32, state.out) << 16);
            // Word 1: [out2:16][literal:8][group_idx:8]
            states_data[base + 1] = @as(u32, state.out2) |
                (@as(u32, state.literal_char) << 16) |
                (@as(u32, state.group_idx) << 24);
            // Word 2: [bitmap_offset:32]
            states_data[base + 2] = state.bitmap_offset;
        }

        // Create config
        const config = RegexMatchConfig{
            .num_names = num_names,
            // safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)
            .num_states = @intCast(compiled.states.len),
            .start_state = compiled.header.start_state,
            .header_flags = compiled.header.flags,
            // safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)
            .num_bitmaps = @intCast(compiled.bitmaps.len / 8),
            .flags = options.toFlags(),
        };

        // Create Metal buffers
        const config_buffer = self.device.newBufferWithLengthOptions(@sizeOf(RegexMatchConfig), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer config_buffer.release();
        if (config_buffer.contents()) |ptr| {
            const config_ptr: *RegexMatchConfig = // safe-transpile: @ptrCast requires manual review — add @alignCast if alignment is guaranteed
                @ptrCast(@alignCast(ptr));
            config_ptr[0] = config;
        }

        // States buffer
        const states_buffer = self.device.newBufferWithLengthOptions(states_data.len * @sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer states_buffer.release();
        if (states_buffer.contents()) |ptr| {
            const states_ptr: [*]u32 = // safe-transpile: @ptrCast requires manual review — add @alignCast if alignment is guaranteed
                @ptrCast(@alignCast(ptr));
            safe.SimdUtils.copy(states_ptr[0..states_data.len], states_data);
        }

        // Bitmaps buffer
        const bitmaps_size = if (compiled.bitmaps.len > 0) compiled.bitmaps.len * @sizeOf(u32) else @sizeOf(u32);
        const bitmaps_buffer = self.device.newBufferWithLengthOptions(bitmaps_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer bitmaps_buffer.release();
        if (compiled.bitmaps.len > 0) {
            if (bitmaps_buffer.contents()) |ptr| {
                const bitmaps_ptr: [*]u32 = // safe-transpile: @ptrCast requires manual review — add @alignCast if alignment is guaranteed
                    @ptrCast(@alignCast(ptr));
                safe.SimdUtils.copy(bitmaps_ptr[0..compiled.bitmaps.len], compiled.bitmaps);
            }
        }

        // Names data buffer
        const names_buffer = self.device.newBufferWithLengthOptions(if (names_data.len > 0) names_data.len else 1, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer names_buffer.release();
        if (names_data.len > 0) {
            if (names_buffer.contents()) |ptr| {
                const names_ptr: [*]u8 = // safe-transpile: @ptrCast requires manual review — add @alignCast if alignment is guaranteed
                    @ptrCast(ptr);
                safe.SimdUtils.copy(names_ptr[0..names_data.len], names_data);
            }
        }

        // Name offsets buffer
        const offsets_buffer = self.device.newBufferWithLengthOptions(name_offsets.len * @sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer offsets_buffer.release();
        if (offsets_buffer.contents()) |ptr| {
            const offsets_ptr: [*]u32 = // safe-transpile: @ptrCast requires manual review — add @alignCast if alignment is guaranteed
                @ptrCast(@alignCast(ptr));
            safe.SimdUtils.copy(offsets_ptr[0..name_offsets.len], name_offsets);
        }

        // Name lengths buffer
        const lengths_buffer = self.device.newBufferWithLengthOptions(name_lengths.len * @sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer lengths_buffer.release();
        if (lengths_buffer.contents()) |ptr| {
            const lengths_ptr: [*]u32 = // safe-transpile: @ptrCast requires manual review — add @alignCast if alignment is guaranteed
                @ptrCast(@alignCast(ptr));
            safe.SimdUtils.copy(lengths_ptr[0..name_lengths.len], name_lengths);
        }

        // Results buffer
        const results_size = names.len * @sizeOf(MatchResult);
        const results_buffer = self.device.newBufferWithLengthOptions(results_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer results_buffer.release();

        // Match count buffer (atomic counter)
        const count_buffer = self.device.newBufferWithLengthOptions(@sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer count_buffer.release();
        if (count_buffer.contents()) |ptr| {
            const count_ptr: *u32 = // safe-transpile: @ptrCast requires manual review — add @alignCast if alignment is guaranteed
                @ptrCast(@alignCast(ptr));
            count_ptr[0] = 0;
        }

        // Header buffer for regex_find function
        const header = RegexHeader{
            // safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)
            .num_states = @intCast(compiled.states.len),
            .start_state = compiled.header.start_state,
            .num_groups = compiled.header.num_groups,
            .flags = compiled.header.flags,
        };
        const header_buffer = self.device.newBufferWithLengthOptions(@sizeOf(RegexHeader), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer header_buffer.release();
        if (header_buffer.contents()) |ptr| {
            const header_ptr: *RegexHeader = // safe-transpile: @ptrCast requires manual review — add @alignCast if alignment is guaranteed
                @ptrCast(@alignCast(ptr));
            header_ptr[0] = header;
        }

        // Create command buffer and encoder
        const command_buffer = self.command_queue.commandBuffer() orelse return error.CommandBufferFailed;
        const encoder = command_buffer.computeCommandEncoder() orelse return error.EncoderFailed;

        encoder.setComputePipelineState(self.regex_pipeline);
        encoder.setBufferOffsetAtIndex(config_buffer, 0, 0);
        encoder.setBufferOffsetAtIndex(states_buffer, 0, 1);
        encoder.setBufferOffsetAtIndex(bitmaps_buffer, 0, 2);
        encoder.setBufferOffsetAtIndex(names_buffer, 0, 3);
        encoder.setBufferOffsetAtIndex(offsets_buffer, 0, 4);
        encoder.setBufferOffsetAtIndex(lengths_buffer, 0, 5);
        encoder.setBufferOffsetAtIndex(results_buffer, 0, 6);
        encoder.setBufferOffsetAtIndex(count_buffer, 0, 7);
        encoder.setBufferOffsetAtIndex(header_buffer, 0, 8);

        // Dispatch one thread per filename
        const grid_size = mtl.MTLSize{ .width = names.len, .height = 1, .depth = 1 };
        const threadgroup_size = mtl.MTLSize{ .width = self.threads_per_group, .height = 1, .depth = 1 };

        encoder.dispatchThreadsThreadsPerThreadgroup(grid_size, threadgroup_size);

        encoder.endEncoding();
        command_buffer.commit();
        command_buffer.waitUntilCompleted();

        // Read results
        const results_ptr: [*]MatchResult = // safe-transpile: @ptrCast requires manual review — add @alignCast if alignment is guaranteed
            @ptrCast(@alignCast(results_buffer.contents()));
        const count_ptr: *u32 = // safe-transpile: @ptrCast requires manual review — add @alignCast if alignment is guaranteed
            @ptrCast(@alignCast(count_buffer.contents()));
        const total_matches = count_ptr.*;

        // Copy matching results
        const matches = try allocator.alloc(MatchResult, total_matches);
        var match_idx: usize = 0;
        for (0..names.len) |i| {
            if (results_ptr[i].matched != 0) {
                matches[match_idx] = results_ptr[i];
                match_idx += 1;
            }
        }

        return BatchMatchResult{
            .matches = matches,
            .total_matches = total_matches,
            .allocator = allocator,
        };
    }
};
