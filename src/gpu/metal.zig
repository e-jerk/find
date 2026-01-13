const std = @import("std");
const mtl = @import("zig-metal");
const mod = @import("mod.zig");

const MatchConfig = mod.MatchConfig;
const MatchResult = mod.MatchResult;
const MatchOptions = mod.MatchOptions;
const BatchMatchResult = mod.BatchMatchResult;
const EMBEDDED_METAL_SHADER = mod.EMBEDDED_METAL_SHADER;
const MAX_GPU_BUFFER_SIZE = mod.MAX_GPU_BUFFER_SIZE;

// Access low-level Metal device methods for memory queries
const DeviceMixin = mtl.gen.MTLDeviceProtocolMixin(mtl.gen.MTLDevice, "MTLDevice");

pub const MetalMatcher = struct {
    device: mtl.MTLDevice,
    command_queue: mtl.MTLCommandQueue,
    pipeline: mtl.MTLComputePipelineState,
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

        const func_name = mtl.NSString.stringWithUTF8String("match_names");
        var func = library.newFunctionWithName(func_name) orelse return error.FunctionNotFound;
        defer func.release();

        var pipeline = device.newComputePipelineStateWithFunctionError(func, null) orelse return error.PipelineCreationFailed;

        // Query actual hardware attributes from Metal API
        const max_threads = pipeline.maxTotalThreadsPerThreadgroup();
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
            .pipeline = pipeline,
            .allocator = allocator,
            .threads_per_group = threads_to_use,
            .capabilities = capabilities,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.pipeline.release();
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

        encoder.setComputePipelineState(self.pipeline);
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
};
