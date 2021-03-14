const std = @import("std");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("vulkan/vulkan.h");
});

const VkAllocator = struct {
    allocator: *std.mem.Allocator,
    // maps addr to len
    len_map: LenMap,

    const allocType = u8;
    const exact = std.mem.Allocator.Exact.at_least;
    const LenMap = std.AutoHashMap([*]u8, usize);

    fn init(allocator: *std.mem.Allocator) VkAllocator {
        return VkAllocator{
            .allocator = allocator,
            .len_map = LenMap.init(allocator),
        };
    }

    // TODO hack to get around comptime alignment for now
    // https://github.com/ziglang/zig/issues/7172
    fn allocAligned(self: *VkAllocator, alignment: u29, size: usize) std.mem.Allocator.Error![]align(1) u8 {
        std.debug.assert(size != 0);
        comptime var i = 0;
        while (i < 29) : (i += 1) {
            if (alignment == (1 << i)) {
                var res = try self.allocator.allocAdvanced(allocType, 1 << i, size, exact);
                errdefer self.allocator.free(res);

                // store addr->len mapping on successful allocation
                try self.len_map.put(res.ptr, size);

                return res;
            }
        }
        unreachable;
    }

    fn reallocAligned(self: *VkAllocator, original: [*]u8, alignment: u29, size: usize) std.mem.Allocator.Error![]align(1) u8 {
        std.debug.assert(size != 0);
        const len = self.len_map.get(original).?;
        const old_alignment = @typeInfo(@TypeOf(original)).Pointer.alignment;
        std.debug.assert(old_alignment >= alignment);
        var sizedOrignal = original[0..len];
        comptime var i = 0;
        while (i < 29) : (i += 1) {
            if (alignment == (1 << i)) {
                var res = try self.allocator.reallocAdvanced(sizedOrignal, 1 << i, size, exact);
                errdefer self.allocator.free(res);

                // update addr->len mapping on successful reallocation
                try self.len_map.put(res.ptr, size);

                return res;
            }
        }
        unreachable;
    }

    fn free(self: *VkAllocator, memory: [*]u8) void {
        const len = self.len_map.get(memory).?;
        var sizedMemory = memory[0..len];
        self.allocator.free(sizedMemory);
        _ = self.len_map.remove(memory);
    }
};

// TODO actually use allocationScope
fn vkAllocate(pUserData: ?*c_void, size: usize, alignment: usize, allocationScope: c.VkSystemAllocationScope) callconv(.C) ?*c_void {
    if (size == 0) {
        return null;
    }

    var allocator = @ptrCast(*VkAllocator, @alignCast(8, pUserData.?));
    if (allocator.allocAligned(@truncate(u29, alignment), size)) |res| {
        return @as(*c_void, res.ptr);
    } else |err| {
        std.log.err("alloc error {}", .{err});
        return null;
    }
}

fn vkReallocate(pUserData: ?*c_void, pOriginal: ?*c_void, size: usize, alignment: usize, allocationScope: c.VkSystemAllocationScope) callconv(.C) ?*c_void {
    if (size == 0) {
        vkFree(pUserData, pOriginal);
        return null;
    }

    if (pOriginal) |justOriginal| {
        var allocator = @ptrCast(*VkAllocator, @alignCast(8, pUserData.?));
        if (allocator.reallocAligned(@ptrCast([*]u8, justOriginal), @truncate(u29, alignment), size)) |res| {
            return @as(*c_void, res.ptr);
        } else |err| {
            std.log.err("alloc error {}", .{err});
            return null;
        }
    } else {
        return vkAllocate(pUserData, size, alignment, allocationScope);
    }
}

fn vkFree(pUserData: ?*c_void, pMemory: ?*c_void) callconv(.C) void {
    const justMemory = pMemory orelse return;
    var allocator = @ptrCast(*VkAllocator, @alignCast(8, pUserData.?));
    allocator.free(@ptrCast([*]u8, justMemory));
}

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var vkAllocator = VkAllocator.init(&arena.allocator);

    const vkAllocationCallbacks = c.VkAllocationCallbacks{
        .pUserData = &vkAllocator,
        .pfnAllocation = vkAllocate,
        .pfnReallocation = vkReallocate,
        .pfnFree = vkFree,
        .pfnInternalAllocation = null,
        .pfnInternalFree = null,
    };

    //    var vkInstance = c.VkInstance {};
    //    const res = c.vkCreateInstance(createInfo, vkAllocator, vkInstance);
    //    defer c.vkDestroyInstance(vkInstance, vkAllocator);
    //    if (res != 0) {
    //        std.log.error("init failed!", .{});
    //    }

    std.log.info("done", .{});
}
