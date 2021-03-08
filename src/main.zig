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
    return switch (alignment) {
        1 => alignedAllocator1.alloc(allocator, size),
        2 => alignedAllocator2.alloc(allocator, size),
        else => undefined,
    };
}

const AlignedAllocator = struct {
    alignment: u29,

    const allocType = u8;
    const exact = std.mem.Allocator.Exact.at_least;

    fn alloc(comptime self: AlignedAllocator,
             allocator: *std.mem.Allocator,
             size: usize) std.mem.Allocator.Error![]align(1) u8 {
        return allocator.allocAdvanced(allocType, self.alignment, size, exact);
    }
};

const alignedAllocator1 = comptime AlignedAllocator { .alignment = 1 << 0, };
const alignedAllocator2 = comptime AlignedAllocator { .alignment = 1 << 1, };

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
