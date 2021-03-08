const std = @import("std");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

pub fn main() anyerror!void {
    var err = c.SDL_Init(c.SDL_INIT_EVERYTHING);
    std.log.info("All your codebase are belong to us.", .{});
    c.SDL_Quit();
}
