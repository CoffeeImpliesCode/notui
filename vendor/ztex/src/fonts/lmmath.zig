//! Latin Modern Math (latinmodern-math.otf) — embedded fallback font.
//! 733,736 bytes, split across lmmath/part0..part4.zig so each source
//! file stays under the 1 MiB VCS new-file snapshot limit.
const part0 = @import("lmmath/part0.zig");
const part1 = @import("lmmath/part1.zig");
const part2 = @import("lmmath/part2.zig");
const part3 = @import("lmmath/part3.zig");
const part4 = @import("lmmath/part4.zig");
pub const lmmath_otf = part0.bytes ++ part1.bytes ++ part2.bytes ++ part3.bytes ++ part4.bytes; // ziglint-ignore: Z024
