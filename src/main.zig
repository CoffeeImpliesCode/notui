const std = @import("std");
const notui = @import("notui");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    try std.Io.File.stdout().writeStreamingAll(io, "notui " ++ notui.version ++ "\n");
}
