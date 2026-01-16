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
            .max_threads_per_group = @intCast(max_threads),
            .max_buffer_size = @min(max_buffer_len, MAX_GPU_BUFFER_SIZE),
            .recommended_memory = recommended_memory,
            .is_discrete = is_high_perf,
            .device_type = if (is_high_perf) .discrete else .integrated,
        };

        const self = try allocator.create(Self);
        self.* = Self{
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

        const num_names: u32 = @intCast(names.len);

        // Calculate total size needed for names data
        var total_names_size: usize = 0;
        for (names) |name| {
            total_names_size += name.len;
        }

        // Prepare name offsets and lengths
        const name_offsets = try allocator.alloc(u32, names.len);
        defer allocator.free(name_offsets);
        const name_lengths = try allocator.alloc(u32, names.len);
        defer allocator.free(name_lengths);

        // Prepare packed names data
        const names_data = try allocator.alloc(u8, total_names_size);
        defer allocator.free(names_data);

        var offset: u32 = 0;
        for (names, 0..) |name, i| {
            name_offsets[i] = offset;
            name_lengths[i] = @intCast(name.len);
            @memcpy(names_data[offset..][0..name.len], name);
            offset += @intCast(name.len);
        }

        // Create config
        const config = MatchConfig{
            .num_names = num_names,
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
            const config_ptr: *MatchConfig = @ptrCast(@alignCast(ptr));
            config_ptr.* = config;
        }

        // Pattern buffer
        var pattern_buffer = self.device.newBufferWithLengthOptions(pattern.len, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer pattern_buffer.release();
        if (pattern_buffer.contents()) |ptr| {
            const pattern_ptr: [*]u8 = @ptrCast(ptr);
            @memcpy(pattern_ptr[0..pattern.len], pattern);
        }

        // Names data buffer
        var names_buffer = self.device.newBufferWithLengthOptions(names_data.len, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer names_buffer.release();
        if (names_buffer.contents()) |ptr| {
            const names_ptr: [*]u8 = @ptrCast(ptr);
            @memcpy(names_ptr[0..names_data.len], names_data);
        }

        // Name offsets buffer
        var offsets_buffer = self.device.newBufferWithLengthOptions(name_offsets.len * @sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer offsets_buffer.release();
        if (offsets_buffer.contents()) |ptr| {
            const offsets_ptr: [*]u32 = @ptrCast(@alignCast(ptr));
            @memcpy(offsets_ptr[0..name_offsets.len], name_offsets);
        }

        // Name lengths buffer
        var lengths_buffer = self.device.newBufferWithLengthOptions(name_lengths.len * @sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer lengths_buffer.release();
        if (lengths_buffer.contents()) |ptr| {
            const lengths_ptr: [*]u32 = @ptrCast(@alignCast(ptr));
            @memcpy(lengths_ptr[0..name_lengths.len], name_lengths);
        }

        // Results buffer
        const results_size = names.len * @sizeOf(MatchResult);
        var results_buffer = self.device.newBufferWithLengthOptions(results_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer results_buffer.release();

        // Match count buffer (atomic counter)
        var count_buffer = self.device.newBufferWithLengthOptions(@sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer count_buffer.release();
        if (count_buffer.contents()) |ptr| {
            const count_ptr: *u32 = @ptrCast(@alignCast(ptr));
            count_ptr.* = 0;
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
        const results_ptr: [*]MatchResult = @ptrCast(@alignCast(results_buffer.contents()));
        const count_ptr: *u32 = @ptrCast(@alignCast(count_buffer.contents()));
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

        const num_names: u32 = @intCast(names.len);

        // Calculate total size needed for names data
        var total_names_size: usize = 0;
        for (names) |name| {
            total_names_size += name.len;
        }

        // Prepare name offsets and lengths
        const name_offsets = try allocator.alloc(u32, names.len);
        defer allocator.free(name_offsets);
        const name_lengths = try allocator.alloc(u32, names.len);
        defer allocator.free(name_lengths);

        // Prepare packed names data
        const names_data = try allocator.alloc(u8, total_names_size);
        defer allocator.free(names_data);

        var offset: u32 = 0;
        for (names, 0..) |name, i| {
            name_offsets[i] = offset;
            name_lengths[i] = @intCast(name.len);
            @memcpy(names_data[offset..][0..name.len], name);
            offset += @intCast(name.len);
        }

        // Pack regex states for GPU (3 u32 words per state)
        const states_data = try allocator.alloc(u32, compiled.states.len * 3);
        defer allocator.free(states_data);
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
            .num_states = @intCast(compiled.states.len),
            .start_state = compiled.header.start_state,
            .header_flags = compiled.header.flags,
            .num_bitmaps = @intCast(compiled.bitmaps.len / 8),
            .flags = options.toFlags(),
        };

        // Create Metal buffers
        const config_buffer = self.device.newBufferWithLengthOptions(@sizeOf(RegexMatchConfig), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer config_buffer.release();
        if (config_buffer.contents()) |ptr| {
            const config_ptr: *RegexMatchConfig = @ptrCast(@alignCast(ptr));
            config_ptr.* = config;
        }

        // States buffer
        const states_buffer = self.device.newBufferWithLengthOptions(states_data.len * @sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer states_buffer.release();
        if (states_buffer.contents()) |ptr| {
            const states_ptr: [*]u32 = @ptrCast(@alignCast(ptr));
            @memcpy(states_ptr[0..states_data.len], states_data);
        }

        // Bitmaps buffer
        const bitmaps_size = if (compiled.bitmaps.len > 0) compiled.bitmaps.len * @sizeOf(u32) else @sizeOf(u32);
        const bitmaps_buffer = self.device.newBufferWithLengthOptions(bitmaps_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer bitmaps_buffer.release();
        if (compiled.bitmaps.len > 0) {
            if (bitmaps_buffer.contents()) |ptr| {
                const bitmaps_ptr: [*]u32 = @ptrCast(@alignCast(ptr));
                @memcpy(bitmaps_ptr[0..compiled.bitmaps.len], compiled.bitmaps);
            }
        }

        // Names data buffer
        const names_buffer = self.device.newBufferWithLengthOptions(if (names_data.len > 0) names_data.len else 1, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer names_buffer.release();
        if (names_data.len > 0) {
            if (names_buffer.contents()) |ptr| {
                const names_ptr: [*]u8 = @ptrCast(ptr);
                @memcpy(names_ptr[0..names_data.len], names_data);
            }
        }

        // Name offsets buffer
        const offsets_buffer = self.device.newBufferWithLengthOptions(name_offsets.len * @sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer offsets_buffer.release();
        if (offsets_buffer.contents()) |ptr| {
            const offsets_ptr: [*]u32 = @ptrCast(@alignCast(ptr));
            @memcpy(offsets_ptr[0..name_offsets.len], name_offsets);
        }

        // Name lengths buffer
        const lengths_buffer = self.device.newBufferWithLengthOptions(name_lengths.len * @sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer lengths_buffer.release();
        if (lengths_buffer.contents()) |ptr| {
            const lengths_ptr: [*]u32 = @ptrCast(@alignCast(ptr));
            @memcpy(lengths_ptr[0..name_lengths.len], name_lengths);
        }

        // Results buffer
        const results_size = names.len * @sizeOf(MatchResult);
        const results_buffer = self.device.newBufferWithLengthOptions(results_size, mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer results_buffer.release();

        // Match count buffer (atomic counter)
        const count_buffer = self.device.newBufferWithLengthOptions(@sizeOf(u32), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer count_buffer.release();
        if (count_buffer.contents()) |ptr| {
            const count_ptr: *u32 = @ptrCast(@alignCast(ptr));
            count_ptr.* = 0;
        }

        // Header buffer for regex_find function
        const header = RegexHeader{
            .num_states = @intCast(compiled.states.len),
            .start_state = compiled.header.start_state,
            .num_groups = compiled.header.num_groups,
            .flags = compiled.header.flags,
        };
        const header_buffer = self.device.newBufferWithLengthOptions(@sizeOf(RegexHeader), mtl.MTLResourceOptions.MTLResourceCPUCacheModeDefaultCache) orelse return error.BufferCreationFailed;
        defer header_buffer.release();
        if (header_buffer.contents()) |ptr| {
            const header_ptr: *RegexHeader = @ptrCast(@alignCast(ptr));
            header_ptr.* = header;
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
        const results_ptr: [*]MatchResult = @ptrCast(@alignCast(results_buffer.contents()));
        const count_ptr: *u32 = @ptrCast(@alignCast(count_buffer.contents()));
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
