const std = @import("std");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("vulkan/vulkan.h");
});

// TODO hack to get around comptime alignment for now
// https://github.com/ziglang/zig/issues/7172
fn allocAligned(allocator: *std.mem.Allocator,
                alignment: u29,
                size: usize) std.mem.Allocator.Error![]align(1) u8 {
    // TODO go up to 29
    return switch (alignment) {
        1 << 0 => alignedAllocators[0].alloc(allocator, size),
        1 << 1 => alignedAllocators[1].alloc(allocator, size),
        1 << 2 => alignedAllocators[2].alloc(allocator, size),
        1 << 3 => alignedAllocators[3].alloc(allocator, size),
        1 << 4 => alignedAllocators[4].alloc(allocator, size),
        1 << 5 => alignedAllocators[5].alloc(allocator, size),
        1 << 6 => alignedAllocators[6].alloc(allocator, size),
        1 << 7 => alignedAllocators[7].alloc(allocator, size),
        else => undefined,
    };
}

const AlignedAllocator = struct {
    alignment: u29,

    const allocType = u8;
    const exact = std.mem.Allocator.Exact.at_least;

    // implictly cast to alignment of 1 since we use one fn signature for all alloc calls
    fn alloc(comptime self: AlignedAllocator,
             allocator: *std.mem.Allocator,
             size: usize) std.mem.Allocator.Error![]align(1) u8 {
        return allocator.allocAdvanced(allocType, self.alignment, size, exact);
    }
};

// this generates structs for all possible alignment values
const alignedAllocators = init: {
    const count = 29;   // since alignment is u29
    var values: [count]AlignedAllocator = undefined;
    for (values) |*value, i| {
        value.* = AlignedAllocator { .alignment = 1 << i };
    }
    break :init values;
};

// TODO actually use allocationScope
fn vkAllocate(pUserData: ?*c_void,
              size: usize,
              alignment: usize,
              allocationScope: c.VkSystemAllocationScope) callconv(.C) ?*c_void {
    if (pUserData) |justUserData| {
        var allocator = @ptrCast(*std.mem.Allocator, @alignCast(8, justUserData));
        if (allocAligned(allocator, @truncate(u29, alignment), size)) |res| {
            return @as(*c_void, &res[0]);
        } else |err| {
            std.log.err("alloc error {}", .{err});
            return null;
        }
    } else {
        return null;
    }
}

pub fn main() anyerror!void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var allocator = &arena.allocator;

    // TODO rest of allocator
    const vkAllocationCallbacks = c.VkAllocationCallbacks {
        .pUserData = allocator,
        .pfnAllocation = vkAllocate,
        .pfnReallocation = undefined,
        .pfnFree = undefined,
        .pfnInternalAllocation = undefined,
        .pfnInternalFree = undefined,
    };

//    var vkInstance = c.VkInstance {};
//    const res = c.vkCreateInstance(createInfo, vkAllocator, vkInstance);
//    defer c.vkDestroyInstance(vkInstance, vkAllocator);
//    if (res != 0) {
//        std.log.error("init failed!", .{});
//    }

    std.log.info("done", .{});
}
