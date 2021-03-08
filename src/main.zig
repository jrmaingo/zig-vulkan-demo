const std = @import("std");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("vulkan/vulkan.h");
});

// TODO actually use allocationScope
fn vkAllocate(pUserData: ?*c_void,
              size: usize,
              alignment: usize,
              allocationScope: c.VkSystemAllocationScope) callconv(.C) ?*c_void {
    if (pUserData) |justUserData| {
        var allocator = @ptrCast(*std.mem.Allocator, @alignCast(8, justUserData));
        const truncatedAlignment = @truncate(u29, alignment);
        // TODO hack to get around comptime alignment for now
        // https://github.com/ziglang/zig/issues/7172
        const actualAlignment:u29 = 8;
        std.debug.assert(truncatedAlignment <= 8);
        if (allocator.allocAdvanced(u8, actualAlignment, size, std.mem.Allocator.Exact.at_least)) |res| {
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
