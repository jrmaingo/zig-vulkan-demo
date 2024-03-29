const std = @import("std");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("vulkan/vulkan.h");
});

const VkAllocator = struct {
    allocator: *std.mem.Allocator,
    // maps addr to len
    len_map: LenMap,
    tracing: bool = false,

    const allocType = u8;
    const exact = std.mem.Allocator.Exact.at_least;
    const LenMap = std.AutoHashMap([*]u8, AllocData);

    const AllocData = struct {
        size: usize,
        alignment: u29,
    };

    fn init(allocator: *std.mem.Allocator) VkAllocator {
        return VkAllocator{
            .allocator = allocator,
            .len_map = LenMap.init(allocator),
        };
    }

    fn deinit(self: *VkAllocator) void {
        self.len_map.deinit();
    }

    fn getCallbacks(self: *VkAllocator) c.VkAllocationCallbacks {
        return c.VkAllocationCallbacks{
            .pUserData = self,
            .pfnAllocation = vkAllocate,
            .pfnReallocation = vkReallocate,
            .pfnFree = vkFree,
            .pfnInternalAllocation = null,
            .pfnInternalFree = null,
        };
    }

    // TODO hack to get around comptime alignment for now
    // https://github.com/ziglang/zig/issues/7172
    fn allocAligned(self: *VkAllocator, alignment: u29, size: usize) std.mem.Allocator.Error![]align(1) u8 {
        std.debug.assert(size != 0);
        comptime var i = 0;
        inline while (i < 29) : (i += 1) {
            // std.log.info("alloc i: {}", .{i});
            if (alignment == (1 << i)) {
                var res = try self.allocator.allocAdvanced(allocType, 1 << i, size, exact);
                errdefer self.allocator.free(res);

                // store addr->len mapping on successful allocation
                try self.len_map.put(res.ptr, .{ .size = size, .alignment = alignment });
                if (self.tracing) {
                    std.log.err("alloc {} at {}", .{ size, res.ptr });
                }

                return res;
            }
        }
        unreachable;
    }

    fn reallocAligned(self: *VkAllocator, original: [*]u8, alignment: u29, size: usize) std.mem.Allocator.Error![]align(1) u8 {
        std.debug.assert(size != 0);
        const allocData = self.len_map.get(original).?;
        std.debug.assert(allocData.alignment >= alignment);
        var sizedOrignal = original[0..allocData.size];
        comptime var i = 0;
        inline while (i < 29) : (i += 1) {
            // std.log.info("realloc i: {}", .{i});
            if (alignment == (1 << i)) {
                var res = try self.allocator.reallocAdvanced(sizedOrignal, 1 << i, size, exact);
                errdefer self.allocator.free(res);

                // update addr->len mapping on successful reallocation
                try self.len_map.put(res.ptr, .{ .size = size, .alignment = alignment });
                if (self.tracing) {
                    std.log.err("realloc {} at {}", .{ size, res.ptr });
                }

                return res;
            }
        }
        unreachable;
    }

    fn free(self: *VkAllocator, memory: [*]u8) void {
        if (self.tracing) {
            std.log.err("freeing {}, capacity {}", .{ memory, self.len_map.capacity() });
        }
        const allocData = self.len_map.get(memory).?;
        if (self.tracing) {
            std.log.err("with len {}", .{allocData.size});
        }
        var sizedMemory = memory[0..allocData.size];
        self.allocator.free(sizedMemory);
        // removing causes issues that lead to OOM/overflow due to stdlib bug
        // https://github.com/ziglang/zig/pull/7472
        //_ = self.len_map.remove(memory);
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

// workaround for now, remove later when @TypeOf works for global functions
// (this is taken from the code generated by translate-c)
pub inline fn VK_VERSION_MAJOR(version: anytype) u32 {
    return (@import("std").meta.cast(u32, version)) >> 22;
}
pub inline fn VK_VERSION_MINOR(version: anytype) u32 {
    return ((@import("std").meta.cast(u32, version)) >> 12) & 0x3ff;
}
pub inline fn VK_VERSION_PATCH(version: anytype) u32 {
    return (@import("std").meta.cast(u32, version)) & 0xfff;
}

fn vkPrintVersion() void {
    var version: u32 = 0;
    var res = c.vkEnumerateInstanceVersion(&version);
    if (res != c.VkResult.VK_SUCCESS) {
        std.log.err("enumerate instance version error {}", .{res});
    } else {
        std.log.info("version: {}.{}.{}", .{ VK_VERSION_MAJOR(version), VK_VERSION_MINOR(version), VK_VERSION_PATCH(version) });
    }
}

const MyError = error{
    UnknownSDL,
    UnknownVk,
};

fn vkCheck(result: c.VkResult, msg: []const u8) anyerror!void {
    if (result != c.VkResult.VK_SUCCESS) {
        std.log.err("{}: {}", .{ msg, result });
        return MyError.UnknownVk;
    }
}

fn vkInit(vkAllocator: *VkAllocator) anyerror!c.VkInstance {
    const vkApplicationInfo = c.VkApplicationInfo{
        .sType = c.VkStructureType.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pNext = null,
        // .flags = 0,
        .pApplicationName = "Demo",
        .applicationVersion = 1,
        .pEngineName = null,
        .engineVersion = 0,
        .apiVersion = c.VK_MAKE_VERSION(1, 2, 0),
    };

    const c_str_lit = [*:0]const u8;
    const debugUtilsName = @as(c_str_lit, c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME);
    const extensionNames = [_]c_str_lit{debugUtilsName};

    const vkInstanceCreateInfo = c.VkInstanceCreateInfo{
        .sType = c.VkStructureType.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .pApplicationInfo = &vkApplicationInfo,
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = extensionNames.len,
        .ppEnabledExtensionNames = &extensionNames,
    };

    const vkAllocationCallbacks = vkAllocator.getCallbacks();
    var vkInstance: c.VkInstance = undefined;
    const res = c.vkCreateInstance(&vkInstanceCreateInfo, &vkAllocationCallbacks, &vkInstance);
    try vkCheck(res, "init failed!");
    return vkInstance;
}

fn vkMessengerCallback(messageSeverity: c.VkDebugUtilsMessageSeverityFlagBitsEXT, messageType: c.VkDebugUtilsMessageTypeFlagsEXT, pCallbackData: ?*const c.VkDebugUtilsMessengerCallbackDataEXT, pUserData: ?*c_void) callconv(.C) c.VkBool32 {
    if (pCallbackData == null) {
        std.log.err("no data to log", .{});
        return c.VK_FALSE;
    }

    const message = pCallbackData.?.pMessage;
    if (message == null) {
        std.log.err("empty message", .{});
        return c.VK_FALSE;
    }

    std.log.warn("[{}] [{}] {}", .{ messageSeverity, messageType, message });
    return c.VK_FALSE;
}

fn vkLogInit(vkInstance: *c.VkInstance, vkAllocator: *VkAllocator) anyerror!c.VkDebugUtilsMessengerEXT {
    const procAddr = c.vkGetInstanceProcAddr(vkInstance.*, "vkCreateDebugUtilsMessengerEXT");
    if (procAddr == null) {
        return MyError.UnknownVk;
    }
    const createMessenger = @ptrCast(c.PFN_vkCreateDebugUtilsMessengerEXT, procAddr).?;

    const messageSeverity = @enumToInt(c.VkDebugUtilsMessageSeverityFlagBitsEXT.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) | @enumToInt(c.VkDebugUtilsMessageSeverityFlagBitsEXT.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT);
    const messageType = @enumToInt(c.VkDebugUtilsMessageTypeFlagBitsEXT.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT) | @enumToInt(c.VkDebugUtilsMessageTypeFlagBitsEXT.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT) | @enumToInt(c.VkDebugUtilsMessageTypeFlagBitsEXT.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT);
    const createInfo = c.VkDebugUtilsMessengerCreateInfoEXT{
        .sType = c.VkStructureType.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        .pNext = null,
        .flags = 0,
        .messageSeverity = messageSeverity,
        .messageType = messageType,
        .pfnUserCallback = vkMessengerCallback,
        .pUserData = null,
    };

    const vkAllocationCallbacks = vkAllocator.getCallbacks();
    var messenger: c.VkDebugUtilsMessengerEXT = null;
    const res = createMessenger(vkInstance.*, &createInfo, &vkAllocationCallbacks, &messenger);
    try vkCheck(res, "failed to create debug messenger");
    return messenger;
}

pub fn main() anyerror!void {
    var arenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arenaAllocator.deinit();

    var engine = try VulkanEngine.create(&arenaAllocator.allocator);
    defer engine.cleanup();

    return engine.run();
}

const VulkanEngine = struct {
    window: *c.SDL_Window,
    vkAllocator: VkAllocator,
    vkInstance: c.VkInstance,
    vkMessenger: c.VkDebugUtilsMessengerEXT,

    fn create(allocator: *std.mem.Allocator) anyerror!VulkanEngine {
        var res_int = c.SDL_Init(c.SDL_INIT_VIDEO);
        if (res_int != 0) {
            return MyError.UnknownSDL;
        }
        var window = c.SDL_CreateWindow("vulkan-zig-demo", c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED, 1280, 720, c.SDL_WINDOW_VULKAN);
        if (window == null) {
            return MyError.UnknownSDL;
        }
        errdefer c.SDL_DestroyWindow(window);

        vkPrintVersion();

        var vkAllocator = VkAllocator.init(allocator);
        errdefer vkAllocator.deinit();

        const vkAllocationCallbacks = vkAllocator.getCallbacks();

        var vkInstance = try vkInit(&vkAllocator);
        errdefer c.vkDestroyInstance(vkInstance, &vkAllocationCallbacks);

        var vkMessenger = try vkLogInit(&vkInstance, &vkAllocator);
        errdefer {
            const procAddr = c.vkGetInstanceProcAddr(vkInstance, "vkDestroyDebugUtilsMessengerEXT");
            const destroyMessenger = @ptrCast(c.PFN_vkDestroyDebugUtilsMessengerEXT, procAddr).?;
            destroyMessenger(vkInstance, vkMessenger, &vkAllocationCallbacks);
        }

        return VulkanEngine{
            .window = window.?,
            .vkAllocator = vkAllocator,
            .vkInstance = vkInstance,
            .vkMessenger = vkMessenger,
        };
    }

    fn cleanup(self: *VulkanEngine) void {
        c.SDL_DestroyWindow(self.window);

        const vkAllocationCallbacks = self.vkAllocator.getCallbacks();

        const procAddr = c.vkGetInstanceProcAddr(self.vkInstance, "vkDestroyDebugUtilsMessengerEXT");
        const destroyMessenger = @ptrCast(c.PFN_vkDestroyDebugUtilsMessengerEXT, procAddr).?;
        destroyMessenger(self.vkInstance, self.vkMessenger, &vkAllocationCallbacks);

        c.vkDestroyInstance(self.vkInstance, &vkAllocationCallbacks);

        self.vkAllocator.deinit();
    }

    fn draw() void {
        // TODO
    }

    fn run(self: *VulkanEngine) anyerror!void {
        while (true) {
            var event: c.SDL_Event = undefined;
            if (c.SDL_PollEvent(&event) == 1) {
                switch (event.type) {
                    c.SDL_QUIT => return,
                    else => {
                        // std.log.info("unhandled event type {}", .{event.type});
                        continue;
                    },
                }
            }

            draw();
        }
    }
};

test "allocate, realloc and free" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var vkAllocator = VkAllocator.init(&arena.allocator);
    const userData = @as(?*c_void, &vkAllocator);

    var mem = vkAllocate(userData, @sizeOf(u32), 8, c.VkSystemAllocationScope.VK_SYSTEM_ALLOCATION_SCOPE_INSTANCE).?;

    mem = vkReallocate(userData, mem, @sizeOf(u64), 8, c.VkSystemAllocationScope.VK_SYSTEM_ALLOCATION_SCOPE_INSTANCE).?;

    vkFree(userData, mem);
}
