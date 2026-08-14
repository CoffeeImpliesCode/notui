//! component module root — the base-ui presentation layer.
//!
//! Components import only the primitives (buffer, style, color, width);
//! an app composes them against any Buffer (a region's cur, a test
//! buffer, a standalone render).

const std = @import("std");

pub const Component = @import("component.zig").Component;
pub const Clock = @import("component.zig").Clock;
pub const Spinner = @import("spinner.zig").Spinner;
pub const Text = @import("text.zig").Text;
pub const AnimatedText = @import("animated_text.zig").AnimatedText;
pub const Progress = @import("progress.zig").Progress;
pub const StatusBar = @import("status_bar.zig").StatusBar;
pub const Gauge = @import("gauge.zig").Gauge;
pub const Suggestions = @import("suggestions.zig").Suggestions;

test {
    std.testing.refAllDecls(@This());
}
