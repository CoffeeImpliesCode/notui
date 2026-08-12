//! component module root — the base-ui presentation layer
//! (baseui-contract.md §6).
//!
//! Components import only the primitives (buffer, style, color, width);
//! an app composes them against any Buffer (a region's cur, a test
//! buffer, a standalone render).

const std = @import("std");

pub const Component = @import("component.zig").Component;
pub const Spinner = @import("spinner.zig").Spinner;
pub const Text = @import("text.zig").Text;
pub const AnimatedText = @import("animated_text.zig").AnimatedText;
pub const Progress = @import("progress.zig").Progress;

test {
    std.testing.refAllDecls(@This());
}
