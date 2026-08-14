const std = @import("std");
const builtin = @import("builtin");
const modules = @import("modules.zig");
const reg_lower = @import("reg_lower.zig");

/// Tracy profiler implementation selection (see build.zig); the library
/// module must export this so the vendored tracy module can tell enabled
/// from disabled (the exe root does the same in main.zig).
pub const tracy_impl = @import("tracy_impl");

// pub const aro = @import("aro.zig");
// pub const fehler = @import("fehler");
// pub const xml2 = @import("xml2");
// pub const zio = @import("zio");

/// Typed Index
pub fn Index(comptime T: type, comptime I: type) type {
    return struct {
        pub const Target = T;
        pub const IndexType = I;
        const Self = @This();
        index: IndexType,

        pub const @"null": Self = .{ .index = std.math.maxInt(I) };

        pub fn get(self: Self, arr: []const T) ?*const T {
            return if (std.meta.eql(self, Self.null)) null else &arr[self.index];
        }

        pub fn getMut(self: Self, arr: []T) ?*T {
            return if (std.meta.eql(self, Self.null)) null else &arr[self.index];
        }

        pub fn fromInt(int: anytype) Self {
            return .{ .index = @intCast(int) };
        }

        pub fn offset(self: Self, offs: I) Self {
            return .{ .index = self.index + offs };
        }
    };
}

pub const Error = error{
    Unimplemented,
    UnexpectedToken,
    OutOfMemory,
    Unbound,
    /// An import or export would claim an existing or reserved name.
    NameConflict,
    UninitializedBinding,
    WriteFailed,
    StackOverflow,
    Assertion,
    TypeMismatch,
    Unsupported,
    Denied,
    Exhausted,
    ArityMismatch,
    /// A differentiation parameter selector does not name a formal argument.
    InvalidSelector,
    MalformedAst,
    InvalidCode,
    StackUnderflow,
    WouldBlock,
    /// Module load cycle: a module (transitively) loads itself (A→B→A).
    CircularLoad,
    /// A user `(raise X)` unwound: the raised payload lives in
    /// Fiber.raised / Process.raised; the error VALUE's anyerror payload
    /// is this tag for host compat.
    Raised,
    /// Terminal exit (05-io-system §4.4; the `exit`/`quit` intrinsics are a
    /// later IO tranche — the enum member exists so try/catch EXCLUDES it:
    /// exit is terminal, never catchable).
    Exit,
} || Expr.Error;

pub const EvalContext = @import("EvalContext.zig");
pub const Func = fn (ctx: *EvalContext, ns: Value, obj: Value, args: []const Value) Error!Value;
pub const FuncPtr = *const Func;
pub const Sym = *[]const u8;

pub const Token = @import("Token.zig");
pub const TokenKind = Token.Kind;
pub const TokenIndex = Token.Index;
pub const Cursor = Token.Cursor;
pub const lex = Token.lex;

pub const Ast = @import("Ast.zig");
pub const AstNode = Ast.Node;
pub const AstNodeRef = Ast.NodeRef;

pub const data = @import("data.zig");
pub const Type = data.Type;
pub const HashMapNamespace = data.HashMapNamespace;
pub const Namespace = data.Namespace;
pub const SmallNamespace = data.SmallNamespace;

pub const Value = @import("value.zig").Value;
pub const ErrorValue = Value;

pub const Runtime = @import("Runtime.zig");
pub const builtins = @import("builtin.zig");

pub const Store = @import("Store.zig");
pub const Object = Store.Object;
pub const ErrorObject = Store.ErrorObject;
pub const SourceUnit = @import("SourceUnit.zig");
pub const Code = @import("code.zig");
pub const Primitive = @import("primitive.zig");
pub const PrimitiveId = Primitive.PrimitiveId;
pub const autodiff_tree = @import("autodiff/tree.zig");
pub const autodiff_space = @import("autodiff/space.zig");
pub const autodiff_rules = @import("autodiff/rules.zig");
pub const autodiff_forward = @import("autodiff/forward.zig");
pub const autodiff_tensor = @import("autodiff/tensor.zig");
pub const autodiff_linearize = @import("autodiff/linearize.zig");
pub const autodiff_transpose = @import("autodiff/transpose.zig");
pub const autodiff_symbolic = @import("autodiff/symbolic.zig");
pub const Expr = @import("expr.zig");
pub const EvalHeap = @import("EvalHeap.zig");
pub const Evaluator = @import("evaluator.zig");
pub const EvalModel = @import("EvalModel.zig");
pub const EvalResidual = @import("EvalResidual.zig");
pub const EvalDomain = @import("eval_domain.zig");

pub const Reader = @import("Reader.zig");

pub const intrinsics = @import("intrinsics/root.zig");
pub const regvm = @import("regvm.zig");
pub const scheduler = @import("scheduler.zig");

const expectEqual = std.testing.expectEqual;

test "cross-query namespace persistence (REPL pattern)" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();

    // Simulate REPL-style sequential submissions.
    // Each call to evalString creates a fresh AST and evaluates against the same root_ns,
    // exactly as Query.submit() does.
    _ = try runtime.evalString("(defn (test x) x)");

    // The binding from the previous evalString should be visible.
    try expectEqual(Value.i64(42), runtime.evalString("(test 42)"));
    try expectEqual(Value.i64(99), runtime.evalString("(test 99)"));

    // Also test def + lookup
    _ = try runtime.evalString("(def my-val 7)");
    try expectEqual(Value.i64(7), runtime.evalString("my-val"));

    // Chained defn
    _ = try runtime.evalString("(defn (add1 x) (+ x 1.0))");
    try expectEqual(Value.f64(6.0), runtime.evalString("(add1 5.0)"));
}

test "full integration test" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();

    // ---- literals ---- //
    try expectEqual(Value.i64(42), runtime.evalString("42"));
    try expectEqual(Value.f64(3.14), runtime.evalString("3.14"));
    try expectEqual(Value.true, runtime.evalString("#t"));
    try expectEqual(Value.false, runtime.evalString("#f"));
    try expectEqual(Value.nil, runtime.evalString("nil"));

    // ---- arithmetic via method dispatch ---- //
    try expectEqual(Value.f64(3.0), runtime.evalString("(+ 1.0 2.0)"));
    try expectEqual(Value.f64(1.0), runtime.evalString("(- 3.0 2.0)"));
    try expectEqual(Value.f64(6.0), runtime.evalString("(* 2.0 3.0)"));
    try expectEqual(Value.f64(2.0), runtime.evalString("(/ 6.0 3.0)"));
    try expectEqual(Value.f64(7.0), runtime.evalString("(+ (* 2.0 3.0) 1.0)"));

    // ---- comparison ---- //
    try expectEqual(Value.true, runtime.evalString("(= 3.0 3.0)"));
    try expectEqual(Value.false, runtime.evalString("(= 3.0 4.0)"));
    try expectEqual(Value.true, runtime.evalString("(!= 3.0 4.0)"));
    try expectEqual(Value.false, runtime.evalString("(!= 3.0 3.0)"));
    try expectEqual(Value.true, runtime.evalString("(> 3.0 2.0)"));
    try expectEqual(Value.false, runtime.evalString("(> 2.0 3.0)"));
    try expectEqual(Value.true, runtime.evalString("(< 2.0 3.0)"));
    try expectEqual(Value.true, runtime.evalString("(>= 3.0 3.0)"));
    try expectEqual(Value.true, runtime.evalString("(<= 3.0 3.0)"));

    // ---- boolean logic ---- //
    try expectEqual(Value.true, runtime.evalString("(@bool.not #f)"));
    try expectEqual(Value.false, runtime.evalString("(@bool.not #t)"));
    try expectEqual(Value.true, runtime.evalString("(@bool.and #t #t)"));
    try expectEqual(Value.false, runtime.evalString("(@bool.and #t #f)"));
    try expectEqual(Value.true, runtime.evalString("(@bool.or #f #t)"));
    try expectEqual(Value.false, runtime.evalString("(@bool.or #f #f)"));

    // ---- if ---- //
    try expectEqual(Value.i64(1), runtime.evalString("(if #t 1 2)"));
    try expectEqual(Value.i64(2), runtime.evalString("(if #f 1 2)"));
    try expectEqual(Value.true, runtime.evalString("(if (= 3.0 3.0) #t #f)"));
    try expectEqual(Value.i64(42), runtime.evalString("(if (= 2.0 3.0) 0 42)"));

    // ---- cons / list ---- //
    try expectEqual(Value.i64(1), runtime.evalString("(@fst (@cons 1 2))"));
    try expectEqual(Value.i64(2), runtime.evalString("(@rst (@cons 1 2))"));

    // ---- type introspection ---- //
    try expectEqual(Value.true, runtime.evalString("(@is-instance-of? @Bool #t)"));
    try expectEqual(Value.true, runtime.evalString("(@is-instance-of? @f64 1.0)"));
    try expectEqual(Value.false, runtime.evalString("(@is-instance-of? @Bool 1)"));

    // ---- math functions ---- //
    try expectEqual(Value.true, runtime.evalString("(approx? @f64.pi 3.14159 0.001)"));
    try expectEqual(Value.f64(0.0), runtime.evalString("(@f64.sin 0.0)"));
    try expectEqual(Value.f64(1.0), runtime.evalString("(@f64.cos 0.0)"));
    try expectEqual(Value.true, runtime.evalString("(@f64.approx? (@f64.sin @f64.pi) 0.0 0.0000000001)"));

    // ---- numeric identities (method dispatch) ---- //
    const pythag_identity = "(approx? (+ (pow (sin 0.5) 2.0) (pow (cos 0.5) 2.0)) 1.0 0.0000001)";
    const cosh_identity = "(approx? (- (pow (cosh 0.5) 2.0) (pow (sinh 0.5) 2.0)) 1.0 0.0000001)";
    try expectEqual(Value.true, runtime.evalString(pythag_identity));
    try expectEqual(Value.true, runtime.evalString(cosh_identity));
    try expectEqual(Value.true, runtime.evalString("(approx? (exp 0.0) 1.0 0.0000001)"));
    try expectEqual(Value.true, runtime.evalString("(approx? (log 1.0) 0.0 0.0000001)"));
    try expectEqual(Value.f64(2.0), runtime.evalString("(sqrt 4.0)"));
    try expectEqual(Value.f64(3.0), runtime.evalString("(floor 3.7)"));
    try expectEqual(Value.f64(4.0), runtime.evalString("(ceil 3.7)"));
    try expectEqual(Value.f64(4.0), runtime.evalString("(round 3.7)"));
    try expectEqual(Value.f64(3.0), runtime.evalString("(trunc 3.7)"));
    try expectEqual(Value.f64(2.0), runtime.evalString("(min 2.0 5.0)"));
    try expectEqual(Value.f64(5.0), runtime.evalString("(max 2.0 5.0)"));
    try expectEqual(Value.f64(1.0), runtime.evalString("(sign 3.0)"));
    try expectEqual(Value.f64(0.0), runtime.evalString("(sign 0.0)"));
    try expectEqual(Value.true, runtime.evalString("(approx? (atan2 1.0 1.0) (/ @f64.pi 4.0) 0.0000001)"));
    try expectEqual(Value.true, runtime.evalString("(approx? (atan 1.0) (/ @f64.pi 4.0) 0.0000001)"));
    try expectEqual(Value.true, runtime.evalString("(approx? (asin 1.0) (/ @f64.tau 4.0) 0.0000001)"));
    try expectEqual(Value.true, runtime.evalString("(approx? (acos 0.0) (/ @f64.tau 4.0) 0.0000001)"));
    try expectEqual(Value.f64(3.0), runtime.evalString("(abs (- 0.0 3.0))"));
    try expectEqual(Value.true, runtime.evalString("(approx? (tan (/ @f64.pi 4.0)) 1.0 0.0001)"));

    // ---- complex identities (c64 via @ intrinsics) ---- //
    try expectEqual(Value.true, runtime.evalString("(approx? (@c64.abs (@c64.cart 3.0 4.0)) 5.0 0.0001)"));
    try expectEqual(Value.true, runtime.evalString("(approx? (@c64.norm (@c64.cart 3.0 4.0)) 25.0 0.0001)"));

    // ---- complex literals ---- //
    try expectEqual(Value.true, runtime.evalString("(@is-instance-of? @c64 1+2i)"));
    try expectEqual(Value.f64(1.0), runtime.evalString("(@c64.re 1+2i)"));
    try expectEqual(Value.f64(2.0), runtime.evalString("(@c64.im 1+2i)"));
    try expectEqual(Value.f64(3.0), runtime.evalString("(@c64.re 3.0-4.5i)"));
    try expectEqual(Value.f64(-4.5), runtime.evalString("(@c64.im 3.0-4.5i)"));
    try expectEqual(Value.f64(0.0), runtime.evalString("(@c64.re 5i)"));
    try expectEqual(Value.f64(5.0), runtime.evalString("(@c64.im 5i)"));
    try expectEqual(Value.true, runtime.evalString("(approx? (@c64.abs 3+4i) 5.0 0.0001)"));
    try expectEqual(Value.true, runtime.evalString("(approx? (@c64.abs 0-5i) 5.0 0.0001)"));
    try expectEqual(Value.f64(4.0), runtime.evalString("(@c64.re (+ 1+2i 3+2i))"));
    try expectEqual(Value.f64(4.0), runtime.evalString("(@c64.im (+ 1+2i 3+2i))"));

    // ---- complex literal edge cases ---- //
    try expectEqual(Value.i64(-1), runtime.evalString("-1"));
    try expectEqual(Value.f64(-1.5), runtime.evalString("-1.5"));
    try expectEqual(Value.f64(-1.0), runtime.evalString("(@c64.re -1+2i)"));
    try expectEqual(Value.f64(2.0), runtime.evalString("(@c64.im -1+2i)"));
    try expectEqual(Value.f64(0.0), runtime.evalString("(@c64.re -5i)"));
    try expectEqual(Value.f64(-5.0), runtime.evalString("(@c64.im -5i)"));
    try expectEqual(Value.true, runtime.evalString("(approx? (@c64.abs -3+4i) 5.0 0.0001)"));
    try expectEqual(Value.i64(5), runtime.evalString("+5"));
    try expectEqual(Value.f64(1e7), runtime.evalString("1e7"));
    try expectEqual(Value.f64(2.5e3), runtime.evalString("2.5e3"));
    try expectEqual(Value.f64(1e-3), runtime.evalString("1e-3"));
    try expectEqual(Value.f64(1e7), runtime.evalString("(@c64.re 1e7+4e-3i)"));
    try expectEqual(Value.f64(4e-3), runtime.evalString("(@c64.im 1e7+4e-3i)"));
    try expectEqual(Value.f64(0.0), runtime.evalString("(@c64.re 0.0-3.0e7i)"));
    try expectEqual(Value.f64(-3.0e7), runtime.evalString("(@c64.im 0.0-3.0e7i)"));

    // ---- nested control flow ---- //
    try expectEqual(Value.i64(3), runtime.evalString("(if (= 1.0 1.0) (if (= 2.0 2.0) 3 4) 5)"));

    // ---- string evaluation ---- //
    try expectEqual(Value.true, runtime.evalString("(@is-instance-of? @String \"hi\")"));
    try expectEqual(Value.true, runtime.evalString("(@is-instance-of? @String \"\")"));
    try expectEqual(Value.true, runtime.evalString("(@is-instance-of? @String \"hello\\nworld\")"));
    try expectEqual(Value.true, runtime.evalString("(@is-instance-of? @String \"tab\\there\")"));
    try expectEqual(Value.true, runtime.evalString("(@is-instance-of? @String \"quote\\\"here\")"));
    try expectEqual(Value.true, runtime.evalString("(@is-instance-of? @String \"back\\\\slash\")"));

    // ---- type introspection via is-core-type? ---- //
    try expectEqual(Value.true, runtime.evalString("(@is-core-type? @Bool)"));
    try expectEqual(Value.true, runtime.evalString("(@is-core-type? @f64)"));
    try expectEqual(Value.false, runtime.evalString("(@is-core-type? 42)"));

    // ---- error values ---- //
    try expectEqual(Value.true, runtime.evalString("(@is-instance-of? @Bool (@bool.not #f))"));
}

test "case expression" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();

    // basic match
    try expectEqual(Value.i64(100), runtime.evalString("(case 2 ((1 2 3) 100))"));
    // fall through to else
    try expectEqual(Value.i64(200), runtime.evalString("(case 99 ((1 2 3) 100) (else 200))"));
    // multiple clauses, match second
    const case_float_match = "(case 15.0 ((1.0 2.0) 10.0) ((10.0 15.0 20.0) 20.0) (else 999.0))";
    try expectEqual(Value.f64(20.0), runtime.evalString(case_float_match));
    // no match, no else -> null
    try expectEqual(Value.nil, runtime.evalString("(case 42 ((1 2 3) 100))"));
    // complex matching
    try expectEqual(Value.true, runtime.evalString("(case 3+4i ((1+2i 3+4i) #t) (else #f))"));
    // nested case
    try expectEqual(Value.i64(10), runtime.evalString("(case 1 ((1) (case 2 ((2) 10) (else 20))) (else 30))"));
    // single key clause
    try expectEqual(Value.i64(42), runtime.evalString("(case 7 ((7) 42) (else 0))"));
    // computed key (expression as key)
    try expectEqual(Value.i64(100), runtime.evalString("(case 5 ((1 (+ 2 3) 7) 100) (else 0))"));
}

test "keyword literals" {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();

    // Keywords are self-evaluating
    try expectEqual(Value.true, runtime.evalString("(Keyword? :foo)"));
    try expectEqual(Value.false, runtime.evalString("(Keyword? 42)"));
    try expectEqual(Value.false, runtime.evalString("(Keyword? \"hi\")"));
    try expectEqual(Value.true, runtime.evalString("(Keyword? :hello-world)"));
}

comptime {
    if (builtin.is_test) {
        std.testing.refAllDecls(@This());
        std.testing.refAllDecls(modules);
        std.testing.refAllDecls(reg_lower);
    }
}
