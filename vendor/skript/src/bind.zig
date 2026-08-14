const std = @import("std");
const Allocator = std.mem.Allocator;
const root = @import("root.zig");
const Runtime = @import("Runtime.zig");
const Code = @import("code.zig");
const SourceUnit = @import("SourceUnit.zig");
const Reader = @import("Reader.zig");
const Store = @import("Store.zig");
const Primitive = @import("primitive.zig");
const modules = @import("intrinsics/modules.zig");
const EvalContext = root.EvalContext;
const Value = root.Value;
const Error = root.Error;
const Sym = root.Sym;
const b = root.builtins;
const Object = root.Object;

const TypeSet = u64;
const ts_unknown = std.math.maxInt(TypeSet);
// Direct builtin calls reserve a nonzero base register and one result register.
const max_use_group: usize = std.math.maxInt(u8) - 2;

const Origin = struct {
    source: SourceUnit.Ref = .{},
    index: u32 = Code.invalid_index,
};

const Form = struct {
    value: Value,
    origin: Origin,
};

const Expr = struct {
    value: Code.ValueId = .invalid,
    types: TypeSet = 0,
    terminated: bool = false,
};

const TypeFact = struct {
    binding: Code.BindingId,
    types: TypeSet,
};
const PredicateFact = struct {
    binding: Code.BindingId,
    then_types: TypeSet,
    else_types: TypeSet,
};
const CaseEqual = struct {
    expr: Expr,
    key_types: TypeSet,
    proven: bool,
};

const Local = struct {
    name: Sym,
    binding: Code.BindingId,
    types: TypeSet,
    namespace_depth: u16 = 0,
    /// False when the binding's cell holds a state its register copy does not
    /// represent: a letrec prebind cell still carrying the uninitialized
    /// marker while initializers run, a loop step binding, or a handler
    /// parameter. Such names keep a namespace lookup on every read.
    lexical: bool = true,
};

const Function = struct {
    parent: ?*Function,
    id: Code.FunctionId,
    block: Code.BlockId,
    locals: std.ArrayList(Local) = .empty,
    dynamic: std.ArrayList(Sym) = .empty,
    facts: std.ArrayList(TypeFact) = .empty,
    self_name: ?Sym = null,
    source_indexes: bool,
    namespace_depth: u16 = 0,
    top: bool = false,
};

const Live = struct {
    block: Code.BlockId,
    value: Code.ValueId,
    types: TypeSet,
};

const Referral = struct {
    public: Sym,
    local: Sym,
};

const UseSpec = struct {
    module_name: []const u8,
    alias: Sym,
    referrals: []const Referral,
    origin: Origin,
};

const ExportSpec = union(enum) {
    local: struct { source: Sym, external: Sym, origin: Origin },
    from: struct { alias: Sym, public: Sym, external: Sym, origin: Origin },

    fn external(self: ExportSpec) Sym {
        return switch (self) {
            .local => |spec| spec.external,
            .from => |spec| spec.external,
        };
    }

    fn origin(self: ExportSpec) Origin {
        return switch (self) {
            .local => |spec| spec.origin,
            .from => |spec| spec.origin,
        };
    }
};
const LetBindingSpec = struct {
    name: Sym,
    initializer: Form,
    origin: Origin,
    source: SourceUnit.Ref,
};
const DoBindingSpec = struct {
    name: Sym,
    initializer: Form,
    step: ?Form,
    origin: Origin,
    source: SourceUnit.Ref,
};

const ParameterList = struct {
    forms: []Form,
    has_rest: bool,
};
fn contextError(context: ?*EvalContext, err: Error) Error {
    if (context) |active| {
        try active.check();
    }
    return err;
}

const Binder = struct {
    rt: *Runtime,
    ns: Value,
    module_path: ?[]const u8,
    scratch: Allocator,
    builder: Code.Builder,
    opts: Runtime.CompilerOpts,
    context: ?*EvalContext = null,
    depth: u32 = 0,
    body_depth: u32 = 0,

    /// Bindings this unit reads through a register (`.local_read`) rather than
    /// a namespace lookup. `saw_eval` demotes all of them before lowering:
    /// `eval` runs against the live frame namespace, so it can rebind a let
    /// cell behind a cached register.
    lexical_reads: std.ArrayList(Code.BindingId) = .empty,
    saw_eval: bool = false,

    fn check(self: *const Binder) Error!void {
        if (self.context) |context| try context.check();
    }

    fn chargeWork(self: *const Binder, count: usize) Error!void {
        if (self.context) |context| {
            try context.chargeWork(@intCast(count), 1, .binder);
        }
    }

    fn checkDepth(self: *const Binder) Error!void {
        const context = self.context orelse return;
        const budget = context.budget() orelse return;
        try budget.checkDepth(self.depth, .binder);
    }
    fn retained(self: *const Binder) bool {
        return self.rt.source_retention != .none;
    }

    fn keepRef(self: *const Binder, source: SourceUnit.Ref) SourceUnit.Ref {
        return if (self.retained()) source else .{};
    }

    fn emit(self: *Binder, function: *Function, operation: Code.Operation, origin: Origin) Error!Code.ValueId {
        try self.check();
        const result = try self.builder.addNode(
            function.id,
            function.block,
            operation,
            if (function.source_indexes) origin.source else .{},
        );
        if (function.source_indexes and origin.index != Code.invalid_index) {
            const node = self.builder.lastNodeId() orelse return error.InvalidCode;
            try self.builder.setNodeSourceIndex(node, origin.index);
        }
        return result;
    }

    fn literal(self: *Binder, function: *Function, value: Value, origin: Origin) Error!Expr {
        return .{
            .value = try self.emit(function, .{ .literal = value }, origin),
            .types = typeSet(value),
        };
    }

    fn compile(self: *Binder, function: *Function, form: Form, tail: bool) Error!Expr {
        try self.check();
        if (self.depth >= 1024) return error.StackOverflow;
        self.depth += 1;
        defer self.depth -= 1;
        try self.checkDepth();
        try self.chargeWork(1);

        if (form.value.typ == b.type_symbol) return self.compileSymbol(function, form);
        if (form.value.typ != b.type_cons) return self.literal(function, form.value, form.origin);
        return self.compileList(function, form, tail);
    }
    fn factTypes(self: *Binder, function: *Function, binding: Code.BindingId) ?TypeSet {
        if (!self.opts.type_narrowing) return null;
        var index = function.facts.items.len;
        while (index > 0) {
            index -= 1;
            const fact = function.facts.items[index];
            if (fact.binding == binding) return fact.types;
        }
        return null;
    }

    fn compileSymbol(self: *Binder, function: *Function, form: Form) Error!Expr {
        const symbol = form.value.obj.toPtr(Sym);
        try self.chargeWork(symbol.*.len);
        if (symbol.*.len > 0 and symbol.*[0] == '@') {
            const name = symbol.*[1..];
            if (self.rt.intrinsics.get(name) orelse self.rt.constants.get(name)) |value| {
                return self.literal(function, value, form.origin);
            }
            const global = try self.builder.addGlobal(symbol, self.keepRef(form.origin.source));
            return .{
                .value = try self.emit(function, .{ .global_read = global }, form.origin),
                .types = ts_unknown,
            };
        }
        if (try self.resolveLocal(function, symbol)) |binding| {
            return .{
                .value = try self.emit(function, .{ .local_read = binding }, form.origin),
                .types = self.bindingTypes(function, binding),
            };
        }
        const global = try self.cellForName(function, symbol, form.origin);
        const global_info = self.builder.globals.items[@intFromEnum(global)];
        return .{
            .value = try self.emit(function, .{ .global_read = global }, form.origin),
            .types = if (global_info.binding == .invalid)
                ts_unknown
            else
                self.bindingTypes(function, global_info.binding),
        };
    }

    fn compileList(self: *Binder, function: *Function, form: Form, tail: bool) Error!Expr {
        const cell = form.value.obj.toRef().deref([2]Value);
        const head_origin = try self.childOrigin(form.origin, 1, cell[0], form.value);
        const args_index = if (form.origin.index == Code.invalid_index)
            Code.invalid_index
        else
            try addIndex(form.origin.index, 1 + try self.dfsSize(cell[0]));
        const args = try self.forms(cell[1], .{ .source = form.origin.source, .index = args_index });

        if (cell[0].typ == b.type_symbol) {
            const name = cell[0].obj.toPtr(Sym).*;
            if (std.mem.eql(u8, name, "quote")) return self.compileQuote(function, form, args);
            if (std.mem.eql(u8, name, "begin")) return self.compileBody(function, args, tail);
            if (std.mem.eql(u8, name, "and")) return self.compileAndOr(function, form, args, tail, true);
            if (std.mem.eql(u8, name, "or")) return self.compileAndOr(function, form, args, tail, false);
            if (std.mem.eql(u8, name, "if")) return self.compileIf(function, form, args, tail);
            if (std.mem.eql(u8, name, "when")) return self.compileWhen(function, form, args, tail, false);
            if (std.mem.eql(u8, name, "unless")) return self.compileWhen(function, form, args, tail, true);
            if (std.mem.eql(u8, name, "cond")) return self.compileCond(function, args, tail, null);
            if (std.mem.eql(u8, name, "case")) return self.compileCase(function, form, args, tail);
            if (std.mem.eql(u8, name, "set!")) return self.compileSetBang(function, args);
            if (std.mem.eql(u8, name, "do")) return self.compileDo(function, form, args, tail);
            if (std.mem.eql(u8, name, "eval")) return self.compileEval(function, form, args, tail);
            if (std.mem.eql(u8, name, "let")) return self.compileLet(function, form, args, tail, false);
            if (std.mem.eql(u8, name, "letrec") or std.mem.eql(u8, name, "letrec*")) {
                return self.compileLet(function, form, args, tail, true);
            }
            if (std.mem.eql(u8, name, "fn")) return self.compileFn(function, form, args, null);
            if (std.mem.eql(u8, name, "def")) return self.compileDef(function, form, args);
            if (std.mem.eql(u8, name, "defn")) return self.compileDefn(function, form, args);
            if (std.mem.eql(u8, name, "export")) return self.compileExport(function, form, args);
            if (std.mem.eql(u8, name, "use")) return error.MalformedAst;
            if (std.mem.eql(u8, name, "raise")) return self.compileRaise(function, args);
            if (std.mem.eql(u8, name, "try")) return self.compileTry(function, form, args, tail);
            if (std.mem.eql(u8, name, "guard")) return self.compileGuard(function, form, args, tail);
        }
        return self.compileCall(function, form, .{ .value = cell[0], .origin = head_origin }, args, tail);
    }

    fn compileQuote(self: *Binder, function: *Function, form: Form, args: []const Form) Error!Expr {
        if (args.len != 1) return error.ArityMismatch;
        return .{
            .value = try self.emit(function, .{ .quote = args[0].value }, form.origin),
            .types = typeSet(args[0].value),
        };
    }

    fn compileBody(self: *Binder, function: *Function, forms_: []const Form, tail: bool) Error!Expr {
        if (forms_.len == 0) return self.literal(function, .nil, .{});
        const root_body = function.top and self.body_depth == 0;
        self.body_depth += 1;
        defer self.body_depth -= 1;
        var root_definitions: std.StringHashMapUnmanaged(void) = .empty;
        var import_destinations: std.StringHashMapUnmanaged(void) = .empty;
        var definitions_scanned = false;
        var result: Expr = .{};
        var i: usize = 0;
        while (i < forms_.len) {
            try self.chargeWork(1);
            if (root_body and isUseForm(forms_[i].value)) {
                var end = i + 1;
                while (end < forms_.len and isUseForm(forms_[end].value)) : (end += 1) {
                    try self.chargeWork(1);
                }
                if (!definitions_scanned) {
                    root_definitions = try self.rootDefinitions(forms_);
                    definitions_scanned = true;
                }
                result = try self.compileUseRun(
                    function,
                    forms_[i..end],
                    &root_definitions,
                    &import_destinations,
                );
                i = end;
            } else {
                result = try self.compile(function, forms_[i], tail and i + 1 == forms_.len);
                i += 1;
            }
            if (result.terminated) return result;
        }
        return result;
    }

    fn compileIf(self: *Binder, function: *Function, form: Form, args: []const Form, tail: bool) Error!Expr {
        if (args.len != 2 and args.len != 3) return error.ArityMismatch;
        const condition = try self.compile(function, args[0], false);
        if (condition.terminated) return condition;
        const narrowing = try self.predicateFact(function, args[0]);
        const fact_base = function.facts.items.len;
        const branch_block = function.block;
        const then_block = try self.builder.addBlock(function.id);
        const else_block = try self.builder.addBlock(function.id);
        try self.builder.setTerminator(branch_block, .{ .branch = .{
            .condition = condition.value,
            .then_edge = .{ .target = then_block },
            .else_edge = .{ .target = else_block },
        } });

        var live: std.ArrayList(Live) = .empty;
        function.block = then_block;
        if (narrowing) |fact| try self.pushFact(function, fact.binding, fact.then_types);
        const then_value = try self.compile(function, args[1], tail);
        if (narrowing) |fact| popFact(function, fact.binding);
        function.facts.shrinkRetainingCapacity(fact_base);
        if (!then_value.terminated) {
            try live.append(self.scratch, .{
                .block = function.block,
                .value = then_value.value,
                .types = then_value.types,
            });
        }

        function.block = else_block;
        if (narrowing) |fact| try self.pushFact(function, fact.binding, fact.else_types);
        const else_value = if (args.len == 3)
            try self.compile(function, args[2], tail)
        else
            try self.literal(function, .nil, form.origin);
        if (narrowing) |fact| popFact(function, fact.binding);
        function.facts.shrinkRetainingCapacity(fact_base);
        if (!else_value.terminated) {
            try live.append(self.scratch, .{
                .block = function.block,
                .value = else_value.value,
                .types = else_value.types,
            });
        }
        return self.join(function, live.items);
    }
    fn compileAndOr(
        self: *Binder,
        function: *Function,
        form: Form,
        args: []const Form,
        tail: bool,
        is_and: bool,
    ) Error!Expr {
        if (args.len == 0) return self.literal(function, if (is_and) .true else .false, form.origin);

        var live: std.ArrayList(Live) = .empty;
        for (args, 0..) |operand, index| {
            const last = index + 1 == args.len;
            const value = try self.compile(function, operand, tail and last);
            if (value.terminated) return self.join(function, live.items);
            if (last) {
                try live.append(self.scratch, .{
                    .block = function.block,
                    .value = value.value,
                    .types = value.types,
                });
                break;
            }

            const selected = try self.builder.addBlock(function.id);
            const next = try self.builder.addBlock(function.id);
            try self.builder.setTerminator(function.block, .{ .branch = .{
                .condition = value.value,
                .then_edge = .{ .target = if (is_and) next else selected },
                .else_edge = .{ .target = if (is_and) selected else next },
            } });
            try live.append(self.scratch, .{
                .block = selected,
                .value = value.value,
                .types = value.types,
            });
            function.block = next;
        }
        return self.join(function, live.items);
    }

    fn compileWhen(
        self: *Binder,
        function: *Function,
        form: Form,
        args: []const Form,
        tail: bool,
        invert: bool,
    ) Error!Expr {
        if (args.len == 0) return error.ArityMismatch;
        const condition = try self.compile(function, args[0], false);
        if (condition.terminated) return condition;
        if (args.len == 1) return self.literal(function, .nil, form.origin);

        const branch_block = function.block;
        const body_block = try self.builder.addBlock(function.id);
        const nil_block = try self.builder.addBlock(function.id);
        try self.builder.setTerminator(branch_block, .{ .branch = .{
            .condition = condition.value,
            .then_edge = .{ .target = if (invert) nil_block else body_block },
            .else_edge = .{ .target = if (invert) body_block else nil_block },
        } });

        var live: std.ArrayList(Live) = .empty;
        function.block = body_block;
        const body = try self.compileBody(function, args[1..], tail);
        if (!body.terminated) {
            try live.append(self.scratch, .{
                .block = function.block,
                .value = body.value,
                .types = body.types,
            });
        }
        function.block = nil_block;
        const nil_value = try self.literal(function, .nil, form.origin);
        try live.append(self.scratch, .{ .block = function.block, .value = nil_value.value, .types = nil_value.types });
        return self.join(function, live.items);
    }
    fn compileCond(
        self: *Binder,
        function: *Function,
        clauses: []const Form,
        tail: bool,
        raise_value: ?Code.ValueId,
    ) Error!Expr {
        var live: std.ArrayList(Live) = .empty;
        for (clauses, 0..) |clause, clause_index| {
            try self.chargeWork(1);
            if (clause.value.typ != b.type_cons) return error.Unimplemented;
            const children = try self.forms(clause.value, shifted(clause.origin, 1));
            if (children.len == 0) return error.Unimplemented;
            const is_else = isSymbol(children[0].value, "else");
            if (is_else and clause_index + 1 != clauses.len) return error.Unimplemented;
            if (is_else) {
                if (children.len < 2) return error.Unimplemented;
                const value = try self.compileBody(function, children[1..], tail);
                if (!value.terminated) {
                    try live.append(self.scratch, .{
                        .block = function.block,
                        .value = value.value,
                        .types = value.types,
                    });
                }
                return self.join(function, live.items);
            }

            const condition = try self.compile(function, children[0], false);
            if (condition.terminated) return self.join(function, live.items);
            const test_block = function.block;
            const body_block = try self.builder.addBlock(function.id);
            const next_block = try self.builder.addBlock(function.id);
            try self.builder.setTerminator(test_block, .{ .branch = .{
                .condition = condition.value,
                .then_edge = .{ .target = body_block },
                .else_edge = .{ .target = next_block },
            } });
            function.block = body_block;
            const value = if (children.len == 1) condition else try self.compileBody(function, children[1..], tail);
            if (!value.terminated) {
                try live.append(self.scratch, .{
                    .block = function.block,
                    .value = value.value,
                    .types = value.types,
                });
            }
            function.block = next_block;
        }
        if (raise_value) |exception| {
            try self.builder.setTerminator(function.block, .{ .raise = exception });
        } else {
            const value = try self.literal(function, .nil, .{});
            try live.append(self.scratch, .{ .block = function.block, .value = value.value, .types = value.types });
        }
        return self.join(function, live.items);
    }
    fn compileCase(self: *Binder, function: *Function, form: Form, args: []const Form, tail: bool) Error!Expr {
        if (args.len == 0) return error.ArityMismatch;
        const discriminant = try self.compile(function, args[0], false);
        if (discriminant.terminated) return discriminant;
        const discriminant_binding = if (self.opts.type_narrowing and args[0].value.typ == b.type_symbol)
            try self.factBinding(function, args[0].value.obj.toPtr(Sym))
        else
            null;
        var live: std.ArrayList(Live) = .empty;
        var has_else = false;

        for (args[1..], 0..) |clause, clause_index| {
            if (clause.value.typ != b.type_cons) return error.MalformedAst;
            const parts = try self.forms(clause.value, shifted(clause.origin, 1));
            if (parts.len < 2) return error.MalformedAst;
            if (isSymbol(parts[0].value, "else")) {
                if (clause_index + 1 != args.len - 1) return error.MalformedAst;
                has_else = true;
                const body = try self.compileBody(function, parts[1..], tail);
                if (!body.terminated) try live.append(self.scratch, .{
                    .block = function.block,
                    .value = body.value,
                    .types = body.types,
                });
                break;
            }
            if (parts[0].value.typ != b.type_cons) return error.MalformedAst;
            const keys = try self.forms(parts[0].value, shifted(parts[0].origin, 1));
            if (keys.len == 0) return error.MalformedAst;
            const body_block = try self.builder.addBlock(function.id);
            var clause_key_types: TypeSet = 0;
            var all_equalities_proven = true;
            for (keys) |key| {
                const equal = try self.compileCaseEqual(function, discriminant, key, form.origin);
                clause_key_types |= equal.key_types;
                all_equalities_proven = all_equalities_proven and equal.proven;
                if (equal.expr.terminated) return self.join(function, live.items);
                const test_block = function.block;
                const next_block = try self.builder.addBlock(function.id);
                try self.builder.setTerminator(test_block, .{ .branch = .{
                    .condition = equal.expr.value,
                    .then_edge = .{ .target = body_block },
                    .else_edge = .{ .target = next_block },
                } });
                function.block = next_block;
            }
            const next_clause = function.block;
            const body_fact_base = function.facts.items.len;
            function.block = body_block;
            if (self.opts.type_narrowing and discriminant_binding != null and all_equalities_proven) {
                try self.pushFact(function, discriminant_binding.?, clause_key_types);
            }
            const body = try self.compileBody(function, parts[1..], tail);
            if (self.opts.type_narrowing and discriminant_binding != null and all_equalities_proven) {
                popFact(function, discriminant_binding.?);
            }
            function.facts.shrinkRetainingCapacity(body_fact_base);
            if (!body.terminated) try live.append(self.scratch, .{
                .block = function.block,
                .value = body.value,
                .types = body.types,
            });
            function.block = next_clause;
        }
        if (!has_else) {
            const value = try self.literal(function, .nil, form.origin);
            try live.append(self.scratch, .{
                .block = function.block,
                .value = value.value,
                .types = value.types,
            });
        }
        return self.join(function, live.items);
    }

    fn compileCaseEqual(
        self: *Binder,
        function: *Function,
        discriminant: Expr,
        key: Form,
        origin: Origin,
    ) Error!CaseEqual {
        const equal_sym = try self.rt.store.getsym("=");
        const callee = try self.compileSymbol(function, .{ .value = .symbol(equal_sym), .origin = origin });
        const key_value = try self.compile(function, key, false);
        if (key_value.terminated) return .{
            .expr = key_value,
            .key_types = key_value.types,
            .proven = false,
        };
        const expected = try self.canonicalArithmetic(function, equal_sym);
        if (self.opts.case_eq_specialize) {
            if (expected) |canonical| {
                return .{
                    .expr = .{
                        .value = try self.emit(function, .{ .arithmetic = .{
                            .op = .equal,
                            .left = discriminant.value,
                            .right = key_value.value,
                            .callee = callee.value,
                            .expected_callee = canonical,
                            .left_types = discriminant.types,
                            .right_types = key_value.types,
                        } }, origin),
                        .types = typeBit(b.type_bool),
                    },
                    .key_types = key_value.types,
                    .proven = true,
                };
            }
        }
        const expr = if (expected != null)
            try self.pureDynamicCall(
                function,
                callee.value,
                &.{ discriminant.value, key_value.value },
                false,
                .invalid,
                origin,
            )
        else
            try self.dynamicCall(
                function,
                callee.value,
                &.{ discriminant.value, key_value.value },
                false,
                .invalid,
                origin,
            );
        return .{
            .expr = expr,
            .key_types = key_value.types,
            .proven = expected != null,
        };
    }

    fn compileLet(
        self: *Binder,
        function: *Function,
        form: Form,
        args: []const Form,
        tail: bool,
        prebind: bool,
    ) Error!Expr {
        if (args.len < 2) return error.ArityMismatch;
        if (!args[0].value.isNil() and args[0].value.typ != b.type_cons) return error.ArityMismatch;
        const bindings = try self.forms(args[0].value, shifted(args[0].origin, 1));
        if (bindings.len > std.math.maxInt(u16)) return error.Unsupported;

        const specs = try self.scratch.alloc(LetBindingSpec, bindings.len);
        for (bindings, 0..) |binding_form, index| {
            try self.chargeWork(1);
            if (binding_form.value.typ != b.type_cons) return error.MalformedAst;
            const pair = try self.forms(binding_form.value, shifted(binding_form.origin, 1));
            if (pair.len != 2 or pair[0].value.typ != b.type_symbol) return error.MalformedAst;
            const name = pair[0].value.obj.toPtr(Sym);
            if (Runtime.isQualified(name) or Runtime.isSealedName(name)) return error.MalformedAst;
            specs[index] = .{
                .name = name,
                .initializer = pair[1],
                .origin = binding_form.origin,
                .source = self.keepRef(pair[0].origin.source),
            };
        }

        _ = try self.emit(function, .{ .ns_push = @intCast(bindings.len) }, form.origin);
        const local_base = function.locals.items.len;
        const dynamic_base = function.dynamic.items.len;
        const fact_base = function.facts.items.len;
        const depth_base = function.namespace_depth;
        if (depth_base == std.math.maxInt(u16)) return error.StackOverflow;
        function.namespace_depth += 1;
        defer {
            function.locals.shrinkRetainingCapacity(local_base);
            function.dynamic.shrinkRetainingCapacity(dynamic_base);
            function.facts.shrinkRetainingCapacity(fact_base);
            function.namespace_depth = depth_base;
        }

        if (prebind) {
            const local_bindings = try self.scratch.alloc(Code.BindingId, specs.len);
            const cells = try self.scratch.alloc(Code.GlobalCellId, specs.len);
            const uninitialized = try self.literal(function, Runtime.uninitialized_binding_marker, form.origin);
            for (specs, 0..) |spec, index| {
                const binding = try self.builder.addBinding(function.id, spec.name, .let, spec.source);
                local_bindings[index] = binding;
                self.builder.bindings.items[@intFromEnum(binding)].value = uninitialized.value;
                cells[index] = try self.builder.addLocalCell(binding, spec.source);
                try function.locals.append(self.scratch, .{
                    .name = spec.name,
                    .binding = binding,
                    .types = ts_unknown,
                    .namespace_depth = function.namespace_depth,
                    // A prebind cell reads as the uninitialized marker until
                    // its own initializer runs, and `Code.Binding.value` is
                    // reassigned to the final value as that happens. A
                    // register read would answer with the finished value
                    // instead of raising on the marker.
                    .lexical = false,
                });
            }
            for (specs, cells) |spec, cell| {
                _ = try self.emit(function, .{ .global_write = .{
                    .cell = cell,
                    .value = uninitialized.value,
                } }, spec.origin);
            }
            for (specs, local_bindings, cells) |spec, binding, cell| {
                const value = try self.compile(function, spec.initializer, false);
                if (value.terminated) return value;
                self.builder.bindings.items[@intFromEnum(binding)].value = value.value;
                _ = try self.emit(function, .{ .global_write = .{
                    .cell = cell,
                    .value = value.value,
                } }, spec.origin);
            }
        } else {
            for (specs) |spec| {
                const value = try self.compile(function, spec.initializer, false);
                if (value.terminated) return value;
                const binding = try self.builder.addBinding(function.id, spec.name, .let, spec.source);
                self.builder.bindings.items[@intFromEnum(binding)].value = value.value;
                try self.noteLexicalRead(binding);
                const cell = try self.builder.addLocalCell(binding, spec.source);
                _ = try self.emit(function, .{ .global_write = .{
                    .cell = cell,
                    .value = value.value,
                } }, spec.origin);
                try function.locals.append(self.scratch, .{
                    .name = spec.name,
                    .binding = binding,
                    .types = if (self.opts.let_binding_types) value.types else ts_unknown,
                    .namespace_depth = function.namespace_depth,
                });
            }
        }

        const body = try self.compileBody(function, args[1..], tail);
        if (!body.terminated) _ = try self.emit(function, .ns_pop, form.origin);
        return body;
    }

    fn compileFn(self: *Binder, parent: *Function, form: Form, args: []const Form, name: ?Sym) Error!Expr {
        if (args.len < 2) return error.ArityMismatch;
        return self.makeFunction(parent, form, args[0].value, args[1..], name, null, form.value);
    }

    fn definitionName(self: *Binder, value: Value) Error!Sym {
        if (value.typ == b.type_symbol) return value.obj.toPtr(Sym);
        if (value.isNil()) {
            const name = try self.rt.store.getsym("nil");
            return name;
        }
        if (value.typ == b.type_bool) {
            const name = try self.rt.store.getsym(if (value.obj.toBool()) "true" else "false");
            return name;
        }
        return error.MalformedAst;
    }
    fn compileDef(self: *Binder, function: *Function, form: Form, args: []const Form) Error!Expr {
        if (args.len != 2) return error.ArityMismatch;
        const name = try self.definitionName(args[0].value);
        if (Runtime.isQualified(name) or Runtime.isSealedName(name)) return error.MalformedAst;
        const value = try self.compile(function, args[1], false);
        if (value.terminated) return value;
        try self.defineName(function, name, value.value, form.origin);
        return value;
    }

    fn compileSetBang(self: *Binder, function: *Function, args: []const Form) Error!Expr {
        if (args.len != 2) return error.ArityMismatch;
        if (args[0].value.typ != b.type_symbol) return error.Unimplemented;
        const name = args[0].value.obj.toPtr(Sym);
        if (Runtime.isSealedName(name)) return error.MalformedAst;
        const cell = try self.cellForName(function, name, args[0].origin);
        const value = try self.compile(function, args[1], false);
        if (value.terminated) return value;

        if (try self.factBinding(function, name)) |binding| {
            const binding_index = @intFromEnum(binding);
            if (binding_index >= self.builder.bindings.items.len) return error.InvalidCode;
            const definition = &self.builder.bindings.items[binding_index];
            definition.mutable = true;
            const owner_index = @intFromEnum(definition.function);
            if (owner_index >= self.builder.functions.items.len) return error.InvalidCode;
            self.builder.functions.items[owner_index].allows_ad = false;
            invalidateBinding(function, binding);
        }
        const function_index = @intFromEnum(function.id);
        if (function_index >= self.builder.functions.items.len) return error.InvalidCode;
        self.builder.functions.items[function_index].allows_ad = false;

        // The cell this write lands on is the authoritative statement that the
        // name can change, whatever the fact table happens to resolve to.
        const cell_binding = self.builder.globals.items[@intFromEnum(cell)].binding;
        if (cell_binding != .invalid) self.demoteBinding(cell_binding);

        _ = try self.emit(function, .{ .global_write = .{
            .cell = cell,
            .value = value.value,
            .assign_existing = true,
        } }, args[0].origin);
        return value;
    }

    fn compileDo(
        self: *Binder,
        function: *Function,
        form: Form,
        args: []const Form,
        tail: bool,
    ) Error!Expr {
        if (args.len < 2) return error.ArityMismatch;
        if (!args[0].value.isNil() and args[0].value.typ != b.type_cons) return error.MalformedAst;
        if (args[1].value.typ != b.type_cons) return error.MalformedAst;

        const binding_forms = try self.forms(args[0].value, shifted(args[0].origin, 1));
        if (binding_forms.len > std.math.maxInt(u16)) return error.Unsupported;
        const test_forms = try self.forms(args[1].value, shifted(args[1].origin, 1));
        if (test_forms.len == 0) return error.MalformedAst;

        const specs = try self.scratch.alloc(DoBindingSpec, binding_forms.len);
        var has_mutating_step = false;
        for (binding_forms, 0..) |binding_form, index| {
            try self.chargeWork(1);
            if (binding_form.value.typ != b.type_cons) return error.MalformedAst;
            const parts = try self.forms(binding_form.value, shifted(binding_form.origin, 1));
            if (parts.len != 2 and parts.len != 3) return error.MalformedAst;
            if (parts[0].value.typ != b.type_symbol) return error.Unimplemented;
            const name = parts[0].value.obj.toPtr(Sym);
            if (Runtime.isQualified(name) or Runtime.isSealedName(name)) return error.MalformedAst;
            if (parts.len == 3) has_mutating_step = true;
            specs[index] = .{
                .name = name,
                .initializer = parts[1],
                .step = if (parts.len == 3) parts[2] else null,
                .origin = binding_form.origin,
                .source = self.keepRef(parts[0].origin.source),
            };
        }

        if (has_mutating_step) {
            const function_index = @intFromEnum(function.id);
            if (function_index >= self.builder.functions.items.len) return error.InvalidCode;
            self.builder.functions.items[function_index].allows_ad = false;
        }
        _ = try self.emit(function, .{ .ns_push = @intCast(binding_forms.len) }, form.origin);
        const local_base = function.locals.items.len;
        const dynamic_base = function.dynamic.items.len;
        const fact_base = function.facts.items.len;
        const depth_base = function.namespace_depth;
        if (depth_base == std.math.maxInt(u16)) return error.StackOverflow;
        function.namespace_depth += 1;
        defer {
            function.locals.shrinkRetainingCapacity(local_base);
            function.dynamic.shrinkRetainingCapacity(dynamic_base);
            function.facts.shrinkRetainingCapacity(fact_base);
            function.namespace_depth = depth_base;
        }

        const bindings = try self.scratch.alloc(Code.BindingId, specs.len);
        const cells = try self.scratch.alloc(Code.GlobalCellId, specs.len);
        for (specs, 0..) |spec, index| {
            const initial = try self.compile(function, spec.initializer, false);
            if (initial.terminated) return initial;
            const binding = try self.builder.addBinding(function.id, spec.name, .let, spec.source);
            self.builder.bindings.items[@intFromEnum(binding)].mutable = true;
            self.builder.bindings.items[@intFromEnum(binding)].value = initial.value;
            const cell = try self.builder.addLocalCell(binding, spec.source);
            _ = try self.emit(function, .{ .global_write = .{
                .cell = cell,
                .value = initial.value,
            } }, spec.origin);
            try function.locals.append(self.scratch, .{
                .name = spec.name,
                .binding = binding,
                .types = ts_unknown,
                .namespace_depth = function.namespace_depth,
                // The step form rewrites this cell every iteration.
                .lexical = false,
            });
            bindings[index] = binding;
            cells[index] = cell;
        }

        const loop = try self.builder.addBlock(function.id);
        const iterate = try self.builder.addBlock(function.id);
        const done = try self.builder.addBlock(function.id);
        try self.builder.setTerminator(function.block, .{ .jump = .{ .target = loop } });

        function.block = loop;
        const test_value = try self.compile(function, test_forms[0], false);
        if (test_value.terminated) return test_value;
        const narrowing = try self.predicateFact(function, test_forms[0]);
        try self.builder.setTerminator(function.block, .{ .branch = .{
            .condition = test_value.value,
            .then_edge = .{ .target = done },
            .else_edge = .{ .target = iterate },
        } });

        function.block = iterate;
        if (narrowing) |fact| try self.pushFact(function, fact.binding, fact.then_types);
        const body = try self.compileBody(function, args[2..], false);
        var iteration_terminated = body.terminated;
        if (!iteration_terminated) {
            const step_values = try self.scratch.alloc(Code.ValueId, specs.len);
            const has_step = try self.scratch.alloc(bool, specs.len);
            for (specs, 0..) |spec, index| {
                const step = spec.step orelse {
                    has_step[index] = false;
                    continue;
                };
                const value = try self.compile(function, step, false);
                if (value.terminated) {
                    iteration_terminated = true;
                    break;
                }
                has_step[index] = true;
                step_values[index] = value.value;
            }
            if (!iteration_terminated) {
                for (specs, bindings, cells, has_step, step_values) |spec, binding, cell, present, value| {
                    if (!present) continue;
                    _ = try self.emit(function, .{ .global_write = .{
                        .cell = cell,
                        .value = value,
                        .assign_existing = true,
                    } }, spec.step.?.origin);
                    invalidateBinding(function, binding);
                }
                try self.builder.setTerminator(function.block, .{ .jump = .{ .target = loop } });
            }
        }
        function.facts.shrinkRetainingCapacity(fact_base);

        function.block = done;
        if (narrowing) |fact| try self.pushFact(function, fact.binding, fact.then_types);
        const result = try self.compileBody(function, test_forms[1..], tail);
        if (narrowing) |fact| popFact(function, fact.binding);
        if (!result.terminated) _ = try self.emit(function, .ns_pop, form.origin);
        return result;
    }

    fn compileEval(
        self: *Binder,
        function: *Function,
        form: Form,
        args: []const Form,
        tail: bool,
    ) Error!Expr {
        if (args.len != 1 and args.len != 2) return error.ArityMismatch;
        const datum = try self.compile(function, args[0], false);
        if (datum.terminated) return datum;
        var values: [2]Code.ValueId = .{ datum.value, .invalid };
        if (args.len == 2) {
            const ns = try self.compile(function, args[1], false);
            if (ns.terminated) return ns;
            values[1] = ns.value;
        }
        const evaluator = self.rt.intrinsics.get("eval") orelse return error.Unbound;
        // eval compiles at run time against the live frame namespace and can
        // rebind any name in it, including let cells this unit is caching.
        self.saw_eval = true;
        const callee = try self.literal(function, evaluator, form.origin);
        return self.dynamicCall(function, callee.value, values[0..args.len], tail, .invalid, form.origin);
    }

    fn compileDefn(self: *Binder, function: *Function, form: Form, args: []const Form) Error!Expr {
        if (args.len < 2 or args[0].value.typ != b.type_cons) return error.ArityMismatch;
        const signature_cell = args[0].value.obj.toRef().deref([2]Value);
        if (signature_cell[0].typ != b.type_symbol) return error.MalformedAst;
        const name = signature_cell[0].obj.toPtr(Sym);
        if (Runtime.isQualified(name) or Runtime.isSealedName(name)) return error.MalformedAst;
        const arglist = signature_cell[1];
        const source_args = form.value.obj.toRef().deref([2]Value)[1];
        if (source_args.typ != b.type_cons) return error.MalformedAst;
        const source_args_cell = source_args.obj.toRef().deref([2]Value);
        const source_value = if (self.retained())
            try self.syntheticFn(arglist, source_args_cell[1], form.value)
        else
            Value.nil;
        const closure = try self.makeFunction(function, form, arglist, args[1..], name, name, source_value);
        try self.defineName(function, name, closure.value, form.origin);
        return closure;
    }

    fn defineName(
        self: *Binder,
        function: *Function,
        name: Sym,
        value: Code.ValueId,
        origin: Origin,
    ) Error!void {
        if (Runtime.isSealedName(name)) return error.MalformedAst;
        var cell: ?Code.GlobalCellId = null;
        var binding: ?Code.BindingId = null;
        if (function.namespace_depth != 0) {
            var index = function.locals.items.len;
            while (index > 0) {
                index -= 1;
                const local = function.locals.items[index];
                if (local.namespace_depth == function.namespace_depth and sameSym(local.name, name)) {
                    binding = local.binding;
                    break;
                }
            }
            if (binding == null) {
                const created = try self.builder.addBinding(
                    function.id,
                    name,
                    .definition,
                    self.keepRef(origin.source),
                );
                self.builder.bindings.items[@intFromEnum(created)].value = value;
                try function.locals.append(self.scratch, .{
                    .name = name,
                    .binding = created,
                    .types = ts_unknown,
                    .namespace_depth = function.namespace_depth,
                });
                binding = created;
                try self.noteLexicalRead(created);
            }
            const binding_id = binding orelse unreachable;
            cell = try self.builder.addLocalCell(binding_id, self.keepRef(origin.source));
        }
        const target = cell orelse try self.cellForName(function, name, origin);
        const target_info = self.builder.globals.items[@intFromEnum(target)];
        if (target_info.binding != .invalid) {
            invalidateBinding(function, target_info.binding);
            // A def landing on a let/definition cell rebinds the name, so any
            // register copy taken for it is stale. `dynamic` already shields
            // this function's later reads, but an enclosing frame's reads and
            // every read a nested `eval` performs still go through the cell.
            self.demoteBinding(target_info.binding);
        }
        _ = try self.emit(function, .{ .global_write = .{ .cell = target, .value = value } }, origin);
        try function.dynamic.append(self.scratch, name);
    }

    fn cellForName(self: *Binder, function: *Function, name: Sym, origin: Origin) Error!Code.GlobalCellId {
        var scope: ?*Function = function;
        while (scope) |current| : (scope = current.parent) {
            var index = current.locals.items.len;
            while (index > 0) {
                index -= 1;
                const local = current.locals.items[index];
                if (!sameSym(local.name, name)) continue;
                const kind = self.builder.bindings.items[@intFromEnum(local.binding)].kind;
                if (kind == .let or kind == .definition) {
                    return self.builder.addLocalCell(local.binding, self.keepRef(origin.source));
                }
                return self.builder.addGlobal(name, self.keepRef(origin.source));
            }
        }
        return self.builder.addGlobal(name, self.keepRef(origin.source));
    }

    /// Record a binding this unit may read through a register, so `saw_eval`
    /// can demote it once the whole unit is bound.
    fn noteLexicalRead(self: *Binder, binding: Code.BindingId) Error!void {
        if (!self.opts.let_binding_registers) return;
        try self.lexical_reads.append(self.scratch, binding);
    }

    /// Send every read of a let/definition binding back to a namespace lookup.
    /// `Code.Binding.mutable` is the lowerer's switch for exactly this: a
    /// mutable `.local_read` emits a lookup instead of a register copy.
    fn demoteBinding(self: *Binder, binding: Code.BindingId) void {
        const index = @intFromEnum(binding);
        if (index >= self.builder.bindings.items.len) return;
        const definition = &self.builder.bindings.items[index];
        switch (definition.kind) {
            .let, .definition => {},
            else => return,
        }
        definition.mutable = true;
        const owner = @intFromEnum(definition.function);
        if (owner >= self.builder.functions.items.len) return;
        self.builder.functions.items[owner].allows_ad = false;
    }

    /// `eval` can rebind any name in the live frame namespace, so no register
    /// copy of a let/definition cell survives it.
    fn demoteLexicalReads(self: *Binder) void {
        for (self.lexical_reads.items) |binding| self.demoteBinding(binding);
    }

    fn functionParameters(self: *Binder, arglist: Value, origin: Origin) Error!ParameterList {
        if (arglist.typ == b.type_symbol) {
            const parameter_forms = try self.scratch.alloc(Form, 1);
            parameter_forms[0] = .{ .value = arglist, .origin = origin };
            return .{ .forms = parameter_forms, .has_rest = true };
        }
        if (arglist.isNil()) return .{ .forms = &.{}, .has_rest = false };
        if (arglist.typ != b.type_cons) return error.MalformedAst;

        var form_list: std.ArrayList(Form) = .empty;
        var rest = arglist;
        var index = origin.index;
        var count: usize = 0;
        while (rest.typ == b.type_cons) {
            try self.chargeWork(1);
            if (count >= 1_048_576) return error.StackOverflow;
            count += 1;
            const cell = rest.obj.toRef().deref([2]Value);
            var source = Reader.sourceRef(rest);
            if (cell[0].typ == b.type_cons) {
                const direct = Reader.sourceRef(cell[0]);
                if (direct.unit != null) source = direct;
            }
            if (source.unit == null) source = origin.source;
            try form_list.append(self.scratch, .{
                .value = cell[0],
                .origin = .{ .source = source, .index = index },
            });
            if (index != Code.invalid_index) index = try addIndex(index, try self.dfsSize(cell[0]));
            rest = cell[1];
        }
        if (rest.isNil()) return .{ .forms = try form_list.toOwnedSlice(self.scratch), .has_rest = false };
        if (rest.typ != b.type_symbol) return error.MalformedAst;
        if (count >= 1_048_576) return error.StackOverflow;
        var source = Reader.sourceRef(rest);
        if (source.unit == null) source = origin.source;
        try form_list.append(self.scratch, .{
            .value = rest,
            .origin = .{ .source = source, .index = index },
        });
        return .{ .forms = try form_list.toOwnedSlice(self.scratch), .has_rest = true };
    }

    fn makeFunction(
        self: *Binder,
        parent: *Function,
        form: Form,
        arglist: Value,
        outer_bodies: []const Form,
        name: ?Sym,
        self_name: ?Sym,
        supplied_source: Value,
    ) Error!Expr {
        const source_ref = self.keepRef(form.origin.source);
        const function_id = try self.builder.addFunction(name, source_ref);
        const entry = try self.builder.addBlock(function_id);
        const indexes = self.retained();
        var function: Function = .{
            .parent = parent,
            .id = function_id,
            .block = entry,
            .self_name = self_name,
            .source_indexes = indexes,
        };

        const arg_origin: Origin = .{
            .source = source_ref,
            .index = if (indexes) 3 else Code.invalid_index,
        };
        const parameter_list = try self.functionParameters(arglist, arg_origin);
        self.builder.functions.items[@intFromEnum(function_id)].has_rest = parameter_list.has_rest;
        for (parameter_list.forms) |parameter| {
            if (parameter.value.typ != b.type_symbol) return error.MalformedAst;
            const symbol = parameter.value.obj.toPtr(Sym);
            if (Runtime.isQualified(symbol) or Runtime.isSealedName(symbol)) return error.MalformedAst;
            if (hasLocal(&function, symbol)) return error.MalformedAst;
            const binding = try self.builder.addBinding(
                function_id,
                symbol,
                .parameter,
                self.keepRef(parameter.origin.source),
            );
            const value = try self.builder.addValue(function_id);
            self.builder.bindings.items[@intFromEnum(binding)].value = value;
            try self.builder.addParameter(function_id, binding);
            try function.locals.append(self.scratch, .{ .name = symbol, .binding = binding, .types = ts_unknown });
        }

        var bodies = try self.scratch.alloc(Form, outer_bodies.len);
        const body_start = if (indexes) try addIndex(2, try self.dfsSize(arglist)) else Code.invalid_index;
        var cursor = body_start;
        for (outer_bodies, 0..) |body, i| {
            bodies[i] = .{ .value = body.value, .origin = .{ .source = body.origin.source, .index = cursor } };
            if (cursor != Code.invalid_index) cursor = try addIndex(cursor, try self.dfsSize(body.value));
        }
        const body = try self.compileBody(&function, bodies, true);
        if (!body.terminated) {
            const values = try self.builder.addOperands(&.{body.value});
            try self.builder.setTerminator(function.block, .{ .return_values = values });
        }

        const info = &self.builder.functions.items[@intFromEnum(function_id)];
        info.result_count = 1;
        info.has_rest = parameter_list.has_rest;
        if (self.retained()) {
            info.source_value = if (!supplied_source.isNil()) supplied_source else form.value;
            info.arglist = arglist;
            info.body = try self.bodyValue(outer_bodies);
        }

        const captures = try self.captureOperands(parent, function_id);
        return .{
            .value = try self.emit(
                parent,
                .{ .make_closure = .{ .function = function_id, .captures = captures } },
                form.origin,
            ),
            .types = typeBit(b.type_closure),
        };
    }

    fn compileRaise(self: *Binder, function: *Function, args: []const Form) Error!Expr {
        if (args.len != 1) return error.ArityMismatch;
        const value = try self.compile(function, args[0], false);
        if (value.terminated) return value;
        try self.builder.setTerminator(function.block, .{ .raise = value.value });
        return .{ .terminated = true };
    }

    fn compileTry(self: *Binder, function: *Function, form: Form, args: []const Form, tail: bool) Error!Expr {
        if (args.len < 2) return error.ArityMismatch;
        const handler_form = args[args.len - 1];
        const catch_parts = if (isHead(handler_form.value, "catch"))
            try self.listChildren(handler_form)
        else
            null;
        if (catch_parts) |parts| {
            if (parts.len < 3 or parts[1].value.typ != b.type_symbol) return error.MalformedAst;
            const name = parts[1].value.obj.toPtr(Sym);
            if (Runtime.isQualified(name) or Runtime.isSealedName(name)) return error.MalformedAst;
        }
        const handler_value = if (catch_parts == null) blk: {
            const value = try self.compile(function, handler_form, false);
            if (value.terminated) return value;
            break :blk value;
        } else null;

        const protected = try self.builder.addBlock(function.id);
        try self.builder.setTerminator(function.block, .{ .jump = .{ .target = protected } });
        function.block = protected;
        const landing = try self.builder.addBlock(function.id);
        const exception = try self.builder.addBlockParam(landing, function.id);
        const handler_id = try self.builder.addHandler(function.id, protected, landing, exception);
        _ = try self.emit(function, .{ .try_begin = handler_id }, form.origin);
        const normal = try self.compileBody(function, args[0 .. args.len - 1], false);
        var live: std.ArrayList(Live) = .empty;
        if (!normal.terminated) {
            _ = try self.emit(function, .try_end, form.origin);
            try live.append(self.scratch, .{ .block = function.block, .value = normal.value, .types = normal.types });
        }

        function.block = landing;
        if (catch_parts) |parts| {
            const base = function.locals.items.len;
            const dynamic_base = function.dynamic.items.len;
            const fact_base = function.facts.items.len;
            const depth_base = function.namespace_depth;
            if (depth_base == std.math.maxInt(u16)) return error.StackOverflow;
            function.namespace_depth += 1;
            defer function.namespace_depth = depth_base;
            defer function.facts.shrinkRetainingCapacity(fact_base);
            defer function.dynamic.shrinkRetainingCapacity(dynamic_base);
            defer function.locals.shrinkRetainingCapacity(base);
            const name = parts[1].value.obj.toPtr(Sym);
            _ = try self.emit(function, .{ .ns_push = 1 }, form.origin);
            const binding = try self.builder.addBinding(
                function.id,
                name,
                .let,
                self.keepRef(parts[1].origin.source),
            );
            self.builder.bindings.items[@intFromEnum(binding)].value = exception;
            const cell = try self.builder.addLocalCell(binding, self.keepRef(parts[1].origin.source));
            _ = try self.emit(function, .{ .global_write = .{ .cell = cell, .value = exception } }, parts[1].origin);
            try function.locals.append(self.scratch, .{
                .name = name,
                .binding = binding,
                .types = ts_unknown,
                .namespace_depth = function.namespace_depth,
                // A handler parameter is the landing block's own value; the
                // cell stays the authority for it.
                .lexical = false,
            });
            const handled = try self.compileBody(function, parts[2..], tail);
            if (!handled.terminated) {
                _ = try self.emit(function, .ns_pop, form.origin);
                try live.append(self.scratch, .{
                    .block = function.block,
                    .value = handled.value,
                    .types = handled.types,
                });
            }
        } else {
            const handler = handler_value orelse unreachable;
            const handled = try self.dynamicCall(
                function,
                handler.value,
                &.{exception},
                tail,
                .invalid,
                handler_form.origin,
            );
            if (!handled.terminated) {
                try live.append(self.scratch, .{
                    .block = function.block,
                    .value = handled.value,
                    .types = handled.types,
                });
            }
        }
        return self.join(function, live.items);
    }

    fn compileGuard(self: *Binder, function: *Function, form: Form, args: []const Form, tail: bool) Error!Expr {
        if (args.len < 2 or args[0].value.typ != b.type_cons) return error.ArityMismatch;
        const spec = try self.forms(args[0].value, shifted(args[0].origin, 1));
        if (spec.len == 0 or spec[0].value.typ != b.type_symbol) return error.MalformedAst;
        const name = spec[0].value.obj.toPtr(Sym);
        if (Runtime.isQualified(name) or Runtime.isSealedName(name)) return error.MalformedAst;
        const protected = try self.builder.addBlock(function.id);
        try self.builder.setTerminator(function.block, .{ .jump = .{ .target = protected } });
        function.block = protected;
        const landing = try self.builder.addBlock(function.id);
        const exception = try self.builder.addBlockParam(landing, function.id);
        const handler_id = try self.builder.addHandler(function.id, protected, landing, exception);
        _ = try self.emit(function, .{ .try_begin = handler_id }, form.origin);
        const normal = try self.compileBody(function, args[1..], false);
        var live: std.ArrayList(Live) = .empty;
        if (!normal.terminated) {
            _ = try self.emit(function, .try_end, form.origin);
            try live.append(self.scratch, .{ .block = function.block, .value = normal.value, .types = normal.types });
        }
        function.block = landing;
        const base = function.locals.items.len;
        const dynamic_base = function.dynamic.items.len;
        const fact_base = function.facts.items.len;
        const depth_base = function.namespace_depth;
        if (depth_base == std.math.maxInt(u16)) return error.StackOverflow;
        function.namespace_depth += 1;
        defer function.namespace_depth = depth_base;
        defer function.facts.shrinkRetainingCapacity(fact_base);
        defer function.dynamic.shrinkRetainingCapacity(dynamic_base);
        defer function.locals.shrinkRetainingCapacity(base);
        _ = try self.emit(function, .{ .ns_push = 1 }, form.origin);
        const binding = try self.builder.addBinding(function.id, name, .let, self.keepRef(spec[0].origin.source));
        self.builder.bindings.items[@intFromEnum(binding)].value = exception;
        const cell = try self.builder.addLocalCell(binding, self.keepRef(spec[0].origin.source));
        _ = try self.emit(function, .{ .global_write = .{ .cell = cell, .value = exception } }, spec[0].origin);
        try function.locals.append(self.scratch, .{
            .name = name,
            .binding = binding,
            .types = ts_unknown,
            .namespace_depth = function.namespace_depth,
            .lexical = false,
        });
        const handled = try self.compileCond(function, spec[1..], tail, exception);
        if (!handled.terminated) {
            _ = try self.emit(function, .ns_pop, form.origin);
            try live.append(self.scratch, .{
                .block = function.block,
                .value = handled.value,
                .types = handled.types,
            });
        }
        return self.join(function, live.items);
    }

    fn compileCall(
        self: *Binder,
        function: *Function,
        form: Form,
        head: Form,
        args: []const Form,
        tail: bool,
    ) Error!Expr {
        if (head.value.typ == b.type_symbol) {
            const symbol = head.value.obj.toPtr(Sym);
            if (symbol.*.len > 0 and symbol.*[0] == '@') {
                return self.compileAtCall(function, form, symbol.*[1..], args, tail);
            }
        }
        const callee = try self.compile(function, head, false);
        if (callee.terminated) return callee;
        var values = try self.scratch.alloc(Code.ValueId, args.len);
        var types = try self.scratch.alloc(TypeSet, args.len);
        for (args, 0..) |arg, i| {
            const value = try self.compile(function, arg, false);
            if (value.terminated) return value;
            values[i] = value.value;
            types[i] = value.types;
        }

        if (head.value.typ == b.type_symbol and args.len == 2) {
            const symbol = head.value.obj.toPtr(Sym);
            if (arithOp(symbol.*)) |operation| {
                if (try self.canonicalArithmetic(function, symbol)) |expected| {
                    return .{
                        .value = try self.emit(function, .{ .arithmetic = .{
                            .op = operation,
                            .left = values[0],
                            .right = values[1],
                            .callee = callee.value,
                            .expected_callee = expected,
                            .left_types = types[0],
                            .right_types = types[1],
                        } }, form.origin),
                        .types = arithmeticTypes(operation, types[0], types[1]),
                    };
                }
            }
        }

        var pure_call = false;
        if (head.value.typ == b.type_symbol and args.len == 1) {
            const symbol = head.value.obj.toPtr(Sym);
            if (typePredicateTypes(symbol.*) != null) {
                pure_call = try self.canonicalPredicate(function, symbol);
            }
        }
        var self_target = Code.FunctionId.invalid;
        const current_function = self.builder.functions.items[@intFromEnum(function.id)];
        const self_arity_matches = if (current_function.has_rest)
            args.len >= current_function.parameter_count - 1
        else
            args.len == current_function.parameter_count;
        if (function.self_name != null and
            head.value.typ == b.type_symbol and
            self_arity_matches and
            sameSym(function.self_name.?, head.value.obj.toPtr(Sym)) and
            !hasLexicalName(function, function.self_name.?))
        {
            self_target = function.id;
        }
        const result = if (pure_call)
            try self.pureDynamicCall(function, callee.value, values, tail, self_target, form.origin)
        else
            try self.dynamicCall(function, callee.value, values, tail, self_target, form.origin);
        if (!result.terminated and head.value.typ == b.type_symbol) {
            const symbol = head.value.obj.toPtr(Sym);
            if (numericConstructorTag(symbol.*)) |tag| {
                if (try self.canonicalConstructor(function, symbol, tag)) {
                    return .{ .value = result.value, .types = typeBit(tag) };
                }
            }
        }
        return result;
    }

    fn compileAtCall(
        self: *Binder,
        function: *Function,
        form: Form,
        name: []const u8,
        args: []const Form,
        tail: bool,
    ) Error!Expr {
        const spec = self.rt.intrinsics.registryVersion().find(name);
        const callee_value = self.rt.intrinsics.get(name) orelse self.rt.constants.get(name);
        if (spec) |registered| {
            if (self.rt.intrinsics.indexForPrimitiveId(registered.id) != null) {
                var values = try self.scratch.alloc(Code.ValueId, args.len);
                for (args, 0..) |arg, i| {
                    const value = try self.compile(function, arg, false);
                    if (value.terminated) return value;
                    values[i] = value.value;
                }
                if (tail) {
                    const value = callee_value orelse return error.InvalidCode;
                    const callee = try self.literal(function, value, form.origin);
                    return self.dynamicCall(function, callee.value, values, true, .invalid, form.origin);
                }
                const result = try self.emit(function, .{ .primitive_call = .{
                    .primitive = registered.id,
                    .args = try self.builder.addOperands(values),
                    .result_count = 1,
                } }, form.origin);
                if (primitiveInvalidatesFacts(registered)) self.invalidateAllFacts(function);
                return .{
                    .value = result,
                    .types = ts_unknown,
                };
            }
        }
        const callee = if (callee_value) |value|
            try self.literal(function, value, form.origin)
        else
            try self.compileSymbol(function, .{
                .value = form.value.obj.toRef().deref([2]Value)[0],
                .origin = form.origin,
            });
        var values = try self.scratch.alloc(Code.ValueId, args.len);
        for (args, 0..) |arg, i| {
            const value = try self.compile(function, arg, false);
            if (value.terminated) return value;
            values[i] = value.value;
        }
        const result = try self.dynamicCall(function, callee.value, values, tail, .invalid, form.origin);
        if (!result.terminated and spec == null) {
            if (numericConstructorTag(name)) |tag| {
                if (callee_value) |value| {
                    if (sameValue(value, .typeValue(tag))) {
                        return .{ .value = result.value, .types = typeBit(tag) };
                    }
                }
            }
        }
        return result;
    }

    fn dynamicCall(
        self: *Binder,
        function: *Function,
        callee: Code.ValueId,
        args: []const Code.ValueId,
        tail: bool,
        self_target: Code.FunctionId,
        origin: Origin,
    ) Error!Expr {
        return self.dynamicCallImpl(function, callee, args, tail, self_target, origin, true);
    }

    fn pureDynamicCall(
        self: *Binder,
        function: *Function,
        callee: Code.ValueId,
        args: []const Code.ValueId,
        tail: bool,
        self_target: Code.FunctionId,
        origin: Origin,
    ) Error!Expr {
        return self.dynamicCallImpl(function, callee, args, tail, self_target, origin, false);
    }

    fn dynamicCallImpl(
        self: *Binder,
        function: *Function,
        callee: Code.ValueId,
        args: []const Code.ValueId,
        tail: bool,
        self_target: Code.FunctionId,
        origin: Origin,
        invalidate: bool,
    ) Error!Expr {
        if (invalidate and !tail) self.invalidateAllFacts(function);
        const range = try self.builder.addOperands(args);
        const result_count = self.builder.functions.items[@intFromEnum(function.id)].result_count;
        if (tail) {
            var count = function.namespace_depth;
            while (count > 0) : (count -= 1) _ = try self.emit(function, .ns_pop, origin);
            try self.builder.setTerminator(function.block, .{ .tail_call = .{
                .callee = callee,
                .args = range,
                .result_count = result_count,
                .self_target = self_target,
            } });
            return .{ .terminated = true };
        }
        return .{
            .value = try self.emit(function, .{ .dynamic_call = .{
                .callee = callee,
                .args = range,
                .result_count = 1,
                .self_target = self_target,
            } }, origin),
        };
    }

    fn join(self: *Binder, function: *Function, live: []const Live) Error!Expr {
        if (live.len == 0) return .{ .terminated = true };
        const block = try self.builder.addBlock(function.id);
        const parameter = try self.builder.addBlockParam(block, function.id);
        var types: TypeSet = 0;
        for (live) |item| {
            const args = try self.builder.addOperands(&.{item.value});
            try self.builder.setTerminator(item.block, .{ .jump = .{ .target = block, .args = args } });
            types |= item.types;
        }
        function.block = block;
        return .{ .value = parameter, .types = if (self.opts.type_joins) types else ts_unknown };
    }
    fn invalidateAllFacts(self: *Binder, function: *Function) void {
        for (function.facts.items) |*fact| fact.types = ts_unknown;
        var current: ?*Function = function;
        while (current) |candidate| : (current = candidate.parent) {
            for (candidate.locals.items) |*local| {
                const kind = self.builder.bindings.items[@intFromEnum(local.binding)].kind;
                if (kind == .let or kind == .definition) local.types = ts_unknown;
            }
        }
    }

    fn primitiveInvalidatesFacts(spec: *const Primitive.Spec) bool {
        if (spec.effects.state_write or spec.effects.unknown) return true;
        return switch (spec.callbacks) {
            .none => false,
            else => true,
        };
    }

    fn bindingTypes(self: *Binder, function: *Function, binding: Code.BindingId) TypeSet {
        var current: ?*Function = function;
        while (current) |candidate| {
            for (candidate.locals.items) |local| {
                if (local.binding == binding) {
                    return if (self.factTypes(function, binding)) |fact| local.types & fact else local.types;
                }
            }
            current = candidate.parent;
        }
        return if (self.factTypes(function, binding)) |fact| ts_unknown & fact else ts_unknown;
    }

    fn pushFact(self: *Binder, function: *Function, binding: Code.BindingId, types: TypeSet) Error!void {
        if (!self.opts.type_narrowing) return;
        var index = function.facts.items.len;
        while (index > 0) {
            index -= 1;
            const fact = function.facts.items[index];
            if (fact.binding == binding) {
                try function.facts.append(self.scratch, .{
                    .binding = binding,
                    .types = fact.types & types,
                });
                return;
            }
        }
        try function.facts.append(self.scratch, .{ .binding = binding, .types = types });
    }

    fn popFact(function: *Function, binding: Code.BindingId) void {
        var index = function.facts.items.len;
        while (index > 0) {
            index -= 1;
            if (function.facts.items[index].binding == binding) {
                _ = function.facts.orderedRemove(index);
                return;
            }
        }
    }

    fn invalidateFacts(function: *Function, binding: Code.BindingId) void {
        for (function.facts.items) |*fact| {
            if (fact.binding == binding) fact.types = ts_unknown;
        }
    }

    fn localCellBinding(self: *Binder, function: *Function, symbol: Sym) ?Code.BindingId {
        var current: ?*Function = function;
        while (current) |candidate| {
            var index = candidate.locals.items.len;
            while (index > 0) {
                index -= 1;
                const local = candidate.locals.items[index];
                if (!sameSym(local.name, symbol)) continue;
                const kind = self.builder.bindings.items[@intFromEnum(local.binding)].kind;
                if (kind == .let or kind == .definition) return local.binding;
            }
            current = candidate.parent;
        }
        return null;
    }

    fn invalidateBinding(function: *Function, binding: Code.BindingId) void {
        invalidateFacts(function, binding);
        var current: ?*Function = function;
        while (current) |candidate| : (current = candidate.parent) {
            for (candidate.locals.items) |*local| {
                if (local.binding == binding) local.types = ts_unknown;
            }
        }
    }
    fn factBinding(self: *Binder, function: *Function, symbol: Sym) Error!?Code.BindingId {
        if (symbol.*.len > 0 and symbol.*[0] == '@') return null;
        if (try self.resolveLocal(function, symbol)) |binding| return binding;
        return self.localCellBinding(function, symbol);
    }

    fn canonicalConstructor(self: *Binder, function: *Function, symbol: Sym, tag: Store.Object) Error!bool {
        if (hasLexicalName(function, symbol)) return false;
        if (self.rt.prelude_ns.isNil()) return false;
        const expected = Value.typeValue(tag);
        const canonical = self.rt.constants.get(symbol.*) orelse return false;
        if (!sameValue(canonical, expected)) return false;
        const current = self.rt.readDependency(self.ns, symbol) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Exhausted => return error.Exhausted,
            else => return false,
        };
        const prelude = self.rt.readDependency(self.rt.prelude_ns, symbol) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Exhausted => return error.Exhausted,
            else => return false,
        };
        return sameValue(current.value, expected) and sameValue(prelude.value, expected);
    }

    fn canonicalArithmetic(self: *Binder, function: *Function, symbol: Sym) Error!?Value {
        if (hasLexicalName(function, symbol)) return null;
        if (self.rt.prelude_ns.isNil()) return null;
        const current = self.rt.readDependency(self.ns, symbol) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Exhausted => return error.Exhausted,
            else => return null,
        };
        const canonical = self.rt.readDependency(self.rt.prelude_ns, symbol) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Exhausted => return error.Exhausted,
            else => return null,
        };
        if (!sameValue(current.value, canonical.value)) return null;
        if (canonical.value.typ != b.type_method) return null;
        const method = canonical.value.obj.toRef().deref(root.data.Method);
        if (!method.locked or method.id == 0) return null;
        return canonical.value;
    }

    fn canonicalPredicate(self: *Binder, function: *Function, symbol: Sym) Error!bool {
        if (hasLexicalName(function, symbol)) return false;
        var scope: ?*Function = function;
        while (scope) |current| : (scope = current.parent) {
            if (current.self_name) |self_name| {
                if (sameSym(self_name, symbol)) return false;
            }
        }
        if (self.rt.prelude_ns.isNil()) return false;
        const current = self.rt.readDependency(self.ns, symbol) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Exhausted => return error.Exhausted,
            else => return false,
        };
        const canonical = self.rt.readDependency(self.rt.prelude_ns, symbol) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Exhausted => return error.Exhausted,
            else => return false,
        };
        return sameValue(current.value, canonical.value);
    }
    fn predicateFact(self: *Binder, function: *Function, form: Form) Error!?PredicateFact {
        if (!self.opts.type_narrowing) return null;
        if (form.value.typ != b.type_cons) return null;
        const cell = form.value.obj.toRef().deref([2]Value);
        if (cell[0].typ != b.type_symbol) return null;
        const head = cell[0].obj.toPtr(Sym);
        const tested = typePredicateTypes(head.*) orelse return null;
        if (function.self_name) |self_name| {
            if (sameSym(self_name, head)) return null;
        }
        if (!try self.canonicalPredicate(function, head)) return null;
        if (cell[1].typ != b.type_cons) return null;
        const arg_cell = cell[1].obj.toRef().deref([2]Value);
        if (arg_cell[0].typ != b.type_symbol or arg_cell[1].typ != b.type_nil) return null;
        const argument = arg_cell[0].obj.toPtr(Sym);
        const binding = (try self.factBinding(function, argument)) orelse return null;
        return .{
            .binding = binding,
            .then_types = tested,
            .else_types = ts_unknown ^ tested,
        };
    }

    fn resolveLocal(self: *Binder, function: *Function, symbol: Sym) Error!?Code.BindingId {
        for (function.dynamic.items) |dynamic| if (sameSym(dynamic, symbol)) return null;
        var i = function.locals.items.len;
        while (i > 0) {
            i -= 1;
            const local = function.locals.items[i];
            if (!sameSym(local.name, symbol)) continue;
            const kind = self.builder.bindings.items[@intFromEnum(local.binding)].kind;
            // A let/definition cell stays in the namespace frame, so it must be
            // read by name whenever anything can observe or rebind that cell.
            // This function's own binding is the one case where nothing can:
            // `compileLet` writes the cell from the value already in a
            // register, and every writer that could change it later (set!,
            // def, eval) marks the binding mutable, which sends the read back
            // to a lookup. Locals the binder marked non-lexical keep reading
            // the cell because their register does not hold the cell's state.
            if (kind == .let or kind == .definition) {
                if (!self.opts.let_binding_registers) return null;
                if (local.lexical) return local.binding;
                return null;
            }
            return local.binding;
        }
        const parent = function.parent orelse return null;
        const binding = (try self.resolveLocal(parent, symbol)) orelse return null;
        const kind = self.builder.bindings.items[@intFromEnum(binding)].kind;
        switch (kind) {
            .parameter, .capture, .handler => try self.ensureCapture(function, binding),
            .let, .definition => return null,
        }
        return binding;
    }

    fn ensureCapture(self: *Binder, function: *Function, binding: Code.BindingId) Error!void {
        const info = self.builder.functions.items[@intFromEnum(function.id)];
        const start: usize = info.capture_start;
        const end = start + info.capture_count;
        for (self.builder.captures.items[start..end]) |existing| if (existing == binding) return;
        _ = try self.builder.addCapture(function.id, binding);
    }

    fn captureOperands(self: *Binder, parent: *Function, function_id: Code.FunctionId) Error!Code.OperandRange {
        const info = self.builder.functions.items[@intFromEnum(function_id)];
        const start: usize = info.capture_start;
        const end = start + info.capture_count;
        var values = try self.scratch.alloc(Code.ValueId, info.capture_count);
        for (self.builder.captures.items[start..end], 0..) |binding, i| {
            values[i] = try self.bindingValue(parent, binding);
        }
        return self.builder.addOperands(values);
    }

    fn bindingValue(self: *Binder, function: *Function, binding: Code.BindingId) Error!Code.ValueId {
        const definition = self.builder.bindings.items[@intFromEnum(binding)];
        if (definition.function == function.id) return definition.value;
        const info = self.builder.functions.items[@intFromEnum(function.id)];
        const start: usize = info.capture_start;
        const end = start + info.capture_count;
        for (self.builder.captures.items[start..end], 0..) |captured, i| {
            if (captured == binding) return self.builder.capture_values.items[start + i];
        }
        return error.InvalidCode;
    }

    fn compileExport(self: *Binder, function: *Function, form: Form, names: []const Form) Error!Expr {
        if (!function.top or self.body_depth != 1 or self.depth != 1 or
            function.namespace_depth != 0 or self.module_path == null)
        {
            return error.MalformedAst;
        }
        if (names.len == 0) return error.ArityMismatch;

        var specs: std.ArrayList(ExportSpec) = .empty;
        for (names) |name| try self.collectExport(name, &specs);
        const values = try self.scratch.alloc(Code.ValueId, specs.items.len);
        for (specs.items, 0..) |spec, index| {
            const plan = switch (spec) {
                .local => |local| try self.valueList(&.{
                    .symbol(local.source),
                    .symbol(local.external),
                }),
                .from => |imported| try self.valueList(&.{
                    .symbol(imported.alias),
                    .symbol(imported.public),
                    .symbol(imported.external),
                }),
            };
            values[index] = (try self.literal(function, plan, spec.origin())).value;
        }
        const primitive = self.rt.intrinsics.registryVersion().find("module-export") orelse
            return error.Unbound;
        if (self.rt.intrinsics.indexForPrimitiveId(primitive.id) == null) return error.Unsupported;
        const result = try self.emit(function, .{ .primitive_call = .{
            .primitive = primitive.id,
            .args = try self.builder.addOperands(values),
            .result_count = 1,
        } }, form.origin);
        self.invalidateAllFacts(function);
        return .{ .value = result, .types = typeBit(b.type_nil) };
    }

    fn collectExport(self: *Binder, form: Form, out: *std.ArrayList(ExportSpec)) Error!void {
        if (form.value.typ == b.type_symbol) {
            const symbol = try self.exportSymbol(form);
            return self.appendExport(out, .{ .local = .{
                .source = symbol,
                .external = symbol,
                .origin = form.origin,
            } });
        }
        const parts = try self.listChildren(form) orelse return error.MalformedAst;
        if (parts.len == 3 and isSymbol(parts[0].value, "rename")) {
            return self.appendExport(out, .{ .local = .{
                .source = try self.exportSymbol(parts[1]),
                .external = try self.exportSymbol(parts[2]),
                .origin = form.origin,
            } });
        }
        if (parts.len < 3 or !isSymbol(parts[0].value, "from")) return error.MalformedAst;
        const alias = try self.exportSymbol(parts[1]);
        for (parts[2..]) |source| {
            const public, const external = if (source.value.typ == b.type_symbol) blk: {
                const symbol = try self.exportSymbol(source);
                break :blk .{ symbol, symbol };
            } else blk: {
                const pair = try self.listChildren(source) orelse return error.MalformedAst;
                if (pair.len != 2) return error.MalformedAst;
                break :blk .{ try self.exportSymbol(pair[0]), try self.exportSymbol(pair[1]) };
            };
            try self.appendExport(out, .{ .from = .{
                .alias = alias,
                .public = public,
                .external = external,
                .origin = source.origin,
            } });
        }
    }

    fn exportSymbol(self: *Binder, form: Form) Error!Sym {
        if (form.value.typ != b.type_symbol) return error.MalformedAst;
        const symbol = form.value.obj.toPtr(Sym);
        if (!validLocalName(symbol)) return error.MalformedAst;
        try self.chargeWork(symbol.*.len);
        return symbol;
    }

    fn appendExport(self: *Binder, out: *std.ArrayList(ExportSpec), spec: ExportSpec) Error!void {
        if (out.items.len >= max_use_group) return error.MalformedAst;
        for (out.items) |existing| {
            try self.chargeWork(1);
            if (sameSym(existing.external(), spec.external())) return error.NameConflict;
        }
        try out.append(self.scratch, spec);
    }

    fn rootDefinitions(self: *Binder, forms_: []const Form) Error!std.StringHashMapUnmanaged(void) {
        var names: std.StringHashMapUnmanaged(void) = .empty;
        for (forms_) |form| {
            try self.chargeWork(1);
            const is_def = isHead(form.value, "def");
            const is_defn = isHead(form.value, "defn");
            if (!is_def and !is_defn) continue;
            const args = form.value.obj.toRef().deref([2]Value)[1];
            if (args.typ != b.type_cons) continue;
            const target = args.obj.toRef().deref([2]Value)[0];
            if (is_def) {
                if (target.typ != b.type_symbol and !target.isNil() and target.typ != b.type_bool) continue;
                const symbol = try self.definitionName(target);
                try self.chargeWork(symbol.*.len);
                try names.put(self.scratch, symbol.*, {});
            } else if (target.typ == b.type_cons) {
                const candidate = target.obj.toRef().deref([2]Value)[0];
                if (candidate.typ == b.type_symbol) {
                    const symbol = candidate.obj.toPtr(Sym);
                    try self.chargeWork(symbol.*.len);
                    try names.put(self.scratch, symbol.*, {});
                }
            }
        }
        return names;
    }

    fn compileUseRun(
        self: *Binder,
        function: *Function,
        forms_: []const Form,
        root_definitions: *const std.StringHashMapUnmanaged(void),
        destinations: *std.StringHashMapUnmanaged(void),
    ) Error!Expr {
        var specs: std.ArrayList(UseSpec) = .empty;
        for (forms_) |form| try self.collectUse(form, &specs, destinations, root_definitions);
        if (specs.items.len == 0) return error.MalformedAst;

        const args = try self.scratch.alloc(Code.ValueId, specs.items.len);
        for (specs.items, 0..) |spec, index| {
            const canonical = try modules.resolveModuleCanonical(self.rt, self.module_path, spec.module_name);
            const path = try self.makeString(canonical);
            var referrals: Value = .nil;
            var remaining = spec.referrals.len;
            while (remaining > 0) {
                try self.chargeWork(1);
                remaining -= 1;
                const referral = spec.referrals[remaining];
                const pair = try self.valueList(&.{ .symbol(referral.public), .symbol(referral.local) });
                referrals = try self.cons(pair, referrals);
            }
            const plan = try self.valueList(&.{ path, .symbol(spec.alias), referrals });
            args[index] = (try self.literal(function, plan, spec.origin)).value;
        }
        const primitive = self.rt.intrinsics.registryVersion().find("use-multi") orelse return error.Unbound;
        if (self.rt.intrinsics.indexForPrimitiveId(primitive.id) == null) return error.Unsupported;
        const result = try self.emit(function, .{ .primitive_call = .{
            .primitive = primitive.id,
            .args = try self.builder.addOperands(args),
            .result_count = 1,
        } }, forms_[0].origin);
        self.invalidateAllFacts(function);
        return .{ .value = result, .types = typeBit(b.type_nil) };
    }

    fn collectUse(
        self: *Binder,
        form: Form,
        out: *std.ArrayList(UseSpec),
        destinations: *std.StringHashMapUnmanaged(void),
        root_definitions: *const std.StringHashMapUnmanaged(void),
    ) Error!void {
        const children = try self.listChildren(form) orelse return error.MalformedAst;
        if (children.len < 2) return error.MalformedAst;
        for (children[1..]) |module_form| {
            if (out.items.len >= max_use_group) return error.MalformedAst;
            const spec = try self.parseUse(module_form);
            try self.addUseDestination(spec.alias, destinations, root_definitions);
            for (spec.referrals) |referral| {
                try self.addUseDestination(referral.local, destinations, root_definitions);
            }
            try out.append(self.scratch, spec);
        }
    }

    fn parseUse(self: *Binder, form: Form) Error!UseSpec {
        const single = [_]Form{form};
        const parts: []const Form = if (form.value.typ == b.type_symbol)
            &single
        else
            try self.listChildren(form) orelse return error.MalformedAst;
        if (parts.len == 0 or parts[0].value.typ != b.type_symbol) return error.MalformedAst;
        if ((parts.len - 1) % 2 != 0) return error.MalformedAst;

        const module_name = parts[0].value.obj.toPtr(Sym).*;
        if (module_name.len == 0 or module_name[0] == '@') return error.MalformedAst;
        try self.chargeWork(module_name.len);
        const basename = if (std.mem.findScalarLast(u8, module_name, '/')) |slash|
            module_name[slash + 1 ..]
        else
            module_name;
        var alias_override: ?Sym = null;
        var referrals: []const Referral = &.{};
        var prefix: []const u8 = "";
        var has_refer = false;
        var has_prefix = false;
        var index: usize = 1;
        while (index < parts.len) : (index += 2) {
            try self.chargeWork(1);
            const option = parts[index].value;
            const value = parts[index + 1];
            if (isOption(option, "as")) {
                if (alias_override != null or value.value.typ != b.type_symbol) return error.MalformedAst;
                alias_override = value.value.obj.toPtr(Sym);
            } else if (isOption(option, "refer")) {
                if (has_refer or (!value.value.isNil() and value.value.typ != b.type_cons)) {
                    return error.MalformedAst;
                }
                referrals = try self.parseReferrals(value);
                has_refer = true;
            } else if (isOption(option, "prefix")) {
                if (has_prefix) return error.MalformedAst;
                prefix = if (value.value.typ == b.type_symbol)
                    value.value.obj.toPtr(Sym).*
                else if (value.value.typ == b.type_string)
                    std.mem.span(value.value.obj.toPtr([*:0]const u8))
                else
                    return error.MalformedAst;
                has_prefix = true;
            } else return error.MalformedAst;
        }
        if (has_prefix and !has_refer) return error.MalformedAst;
        const alias = alias_override orelse try self.rt.store.getsym(basename);
        try self.chargeWork(alias.*.len);
        if (!validLocalName(alias) or Runtime.isSealedName(alias)) return error.MalformedAst;
        if (has_prefix and prefix.len > 0 and referrals.len > 0) {
            const prefixed = try self.scratch.alloc(Referral, referrals.len);
            for (referrals, 0..) |referral, i| {
                try self.chargeWork(prefix.len);
                try self.chargeWork(referral.local.*.len);
                const local = try std.mem.concat(self.scratch, u8, &.{ prefix, referral.local.* });
                const symbol = try self.rt.store.getsym(local);
                if (!validLocalName(symbol) or Runtime.isSealedName(symbol)) return error.MalformedAst;
                prefixed[i] = .{ .public = referral.public, .local = symbol };
            }
            referrals = prefixed;
        }
        return .{
            .module_name = module_name,
            .alias = alias,
            .referrals = referrals,
            .origin = form.origin,
        };
    }

    fn parseReferrals(self: *Binder, form: Form) Error![]const Referral {
        const entries = try self.forms(form.value, shifted(form.origin, 1));
        var referrals: std.ArrayList(Referral) = .empty;
        var publics: std.StringHashMapUnmanaged(void) = .empty;
        for (entries) |entry| {
            const public, const local = if (entry.value.typ == b.type_symbol) blk: {
                const symbol = entry.value.obj.toPtr(Sym);
                break :blk .{ symbol, symbol };
            } else blk: {
                const pair = try self.listChildren(entry) orelse return error.MalformedAst;
                if (pair.len != 2 or pair[0].value.typ != b.type_symbol or
                    pair[1].value.typ != b.type_symbol)
                {
                    return error.MalformedAst;
                }
                break :blk .{ pair[0].value.obj.toPtr(Sym), pair[1].value.obj.toPtr(Sym) };
            };
            if (!validLocalName(public) or !validLocalName(local)) return error.MalformedAst;
            try self.chargeWork(public.*.len);
            try self.chargeWork(local.*.len);
            if (publics.contains(public.*)) return error.MalformedAst;
            try publics.put(self.scratch, public.*, {});
            try referrals.append(self.scratch, .{ .public = public, .local = local });
        }
        return referrals.toOwnedSlice(self.scratch);
    }

    fn addUseDestination(
        self: *Binder,
        name: Sym,
        destinations: *std.StringHashMapUnmanaged(void),
        root_definitions: *const std.StringHashMapUnmanaged(void),
    ) Error!void {
        try self.chargeWork(1);
        if (!validLocalName(name) or Runtime.isSealedName(name)) return error.MalformedAst;
        if (destinations.contains(name.*)) return error.NameConflict;
        if (root_definitions.contains(name.*)) return error.NameConflict;
        try destinations.put(self.scratch, name.*, {});
    }

    fn makeString(self: *Binder, bytes: []const u8) Error!Value {
        const value = try self.rt.store.sym_alloc.allocSentinel(u8, bytes.len, 0);
        @memcpy(value[0..bytes.len], bytes);
        return .string(.fromPtr(value.ptr));
    }

    fn listChildren(self: *Binder, form: Form) Error!?[]const Form {
        if (form.value.typ != b.type_cons) return null;
        const children = try self.forms(form.value, shifted(form.origin, 1));
        return children;
    }
    fn forms(self: *Binder, list: Value, origin: Origin) Error![]Form {
        var output: std.ArrayList(Form) = .empty;
        var rest = list;
        var index = origin.index;
        var count: usize = 0;
        while (rest.typ == b.type_cons) {
            try self.chargeWork(1);
            if (count >= 1_048_576) return error.StackOverflow;
            count += 1;
            const cell = rest.obj.toRef().deref([2]Value);
            var source = Reader.sourceRef(rest);
            if (cell[0].typ == b.type_cons) {
                const direct = Reader.sourceRef(cell[0]);
                if (direct.unit != null) source = direct;
            }
            if (source.unit == null) source = origin.source;
            try output.append(self.scratch, .{ .value = cell[0], .origin = .{ .source = source, .index = index } });
            if (index != Code.invalid_index) index = try addIndex(index, try self.dfsSize(cell[0]));
            rest = cell[1];
        }
        if (rest.typ != b.type_nil) return error.MalformedAst;
        return output.toOwnedSlice(self.scratch);
    }
    fn childOrigin(self: *Binder, origin: Origin, offset: u32, value: Value, parent: Value) Error!Origin {
        _ = self;
        var source = if (value.typ == b.type_cons) Reader.sourceRef(value) else Reader.sourceRef(parent);
        if (source.unit == null) source = origin.source;
        return .{
            .source = source,
            .index = if (origin.index == Code.invalid_index) Code.invalid_index else try addIndex(origin.index, offset),
        };
    }

    fn dfsSize(self: *Binder, value: Value) Error!u32 {
        var active: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer active.deinit(self.scratch);
        return self.dfsSizeInner(value, &active, 0);
    }

    fn dfsSizeInner(self: *Binder, value: Value, active: *std.AutoHashMapUnmanaged(usize, void), depth: u32) Error!u32 {
        if (depth >= 4096) return error.StackOverflow;
        try self.check();
        if (self.context) |context| {
            if (context.budget()) |budget| try budget.checkDepth(depth, .binder);
        }
        try self.chargeWork(1);
        if (value.typ != b.type_cons) return 1;
        var marks: std.ArrayList(usize) = .empty;
        defer {
            for (marks.items) |address| _ = active.remove(address);
            marks.deinit(self.scratch);
        }
        var total: u32 = 1;
        var rest = value;
        var count: usize = 0;
        while (rest.typ == b.type_cons) {
            try self.chargeWork(1);
            if (count >= 1_048_576) return error.StackOverflow;
            count += 1;
            const address = rest.obj.toRef().address();
            if (active.contains(address)) return error.MalformedAst;
            try active.put(self.scratch, address, {});
            try marks.append(self.scratch, address);
            const cell = rest.obj.toRef().deref([2]Value);
            total = try addIndex(total, try self.dfsSizeInner(cell[0], active, depth + 1));
            rest = cell[1];
        }
        if (rest.typ != b.type_nil) total = try addIndex(total, try self.dfsSizeInner(rest, active, depth + 1));
        return total;
    }

    fn syntheticFn(self: *Binder, arglist: Value, bodies: Value, source: Value) Error!Value {
        const tail = try self.cons(arglist, bodies);
        const result = try self.cons(.symbol(try self.rt.store.getsym("fn")), tail);
        copyMeta(result, source);
        return result;
    }

    fn bodyValue(self: *Binder, bodies: []const Form) Error!Value {
        if (bodies.len == 0) return .nil;
        if (bodies.len == 1) return bodies[0].value;
        var rest: Value = .nil;
        var i = bodies.len;
        while (i > 0) {
            try self.chargeWork(1);
            i -= 1;
            rest = try self.cons(bodies[i].value, rest);
        }
        return self.cons(.symbol(try self.rt.store.getsym("begin")), rest);
    }

    fn valueList(self: *Binder, values: []const Value) Error!Value {
        var result: Value = .nil;
        var index = values.len;
        while (index > 0) {
            try self.chargeWork(1);
            index -= 1;
            result = try self.cons(values[index], result);
        }
        return result;
    }

    fn cons(self: *Binder, head: Value, tail: Value) Error!Value {
        const ref = try self.rt.store.create([2]Value);
        ref.deref([2]Value).* = .{ head, tail };
        return .cons(ref.toObject());
    }
};
pub fn bind(
    scratch: Allocator,
    rt: *Runtime,
    ns: Value,
    forms_value: Value,
    module_path: ?[]const u8,
) Error!*const Code.Code {
    const context = EvalContext.currentForStore(rt.store);
    if (context) |active| try active.check();
    const bound = bindWithContext(scratch, rt, ns, forms_value, module_path, context) catch |err| {
        return contextError(context, err);
    };
    return bound;
}

fn bindWithContext(
    scratch: Allocator,
    rt: *Runtime,
    ns: Value,
    forms_value: Value,
    module_path: ?[]const u8,
    context: ?*EvalContext,
) Error!*const Code.Code {
    var binder: Binder = .{
        .rt = rt,
        .ns = ns,
        .module_path = module_path,
        .scratch = scratch,
        .builder = Code.Builder.init(rt.static, context),
        .opts = rt.compiler_opts.effective(),
        .context = context,
    };
    const identity = try rt.allocCodeIdentity();
    binder.builder.id = identity.id;
    binder.builder.revision = identity.revision;
    const top_id = try binder.builder.addFunction(null, .{});
    binder.builder.functions.items[@intFromEnum(top_id)].module_entry = true;
    const entry = try binder.builder.addBlock(top_id);
    var top: Function = .{
        .parent = null,
        .id = top_id,
        .block = entry,
        .source_indexes = false,
        .top = true,
    };
    const result = if (forms_value.typ == b.type_cons)
        try binder.compileBody(&top, try binder.forms(forms_value, .{}), false)
    else
        try binder.compile(&top, .{ .value = forms_value, .origin = .{} }, false);
    if (!result.terminated) {
        const values = try binder.builder.addOperands(&.{result.value});
        try binder.builder.setTerminator(top.block, .{ .return_values = values });
    }
    // Every writer is known now, so a unit that can evaluate at run time gives
    // up register-resident let reads entirely.
    if (binder.saw_eval) binder.demoteLexicalReads();

    const code = try binder.builder.finish(scratch);
    code.owner = rt;
    return code;
}
fn typePredicateTag(name: []const u8) ?Store.Object {
    if (std.mem.eql(u8, name, "nil?")) return b.type_nil;
    if (std.mem.eql(u8, name, "Bool?") or std.mem.eql(u8, name, "bool?")) return b.type_bool;
    if (std.mem.eql(u8, name, "Symbol?") or std.mem.eql(u8, name, "symbol?")) return b.type_symbol;
    if (std.mem.eql(u8, name, "String?") or std.mem.eql(u8, name, "string?")) return b.type_string;
    if (std.mem.eql(u8, name, "Opaque?") or std.mem.eql(u8, name, "opaque?")) return b.type_opaque;
    if (std.mem.eql(u8, name, "Keyword?")) return b.type_keyword;
    if (std.mem.eql(u8, name, "Type?")) return b.type_type;
    if (std.mem.eql(u8, name, "Tensor?")) return b.type_tensor;
    if (std.mem.eql(u8, name, "f8?")) return b.type_f8;
    if (std.mem.eql(u8, name, "f16?")) return b.type_f16;
    if (std.mem.eql(u8, name, "f32?")) return b.type_f32;
    if (std.mem.eql(u8, name, "f64?")) return b.type_f64;
    if (std.mem.eql(u8, name, "u8?")) return b.type_u8;
    if (std.mem.eql(u8, name, "u16?")) return b.type_u16;
    if (std.mem.eql(u8, name, "u32?")) return b.type_u32;
    if (std.mem.eql(u8, name, "u64?")) return b.type_u64;
    if (std.mem.eql(u8, name, "i8?")) return b.type_i8;
    if (std.mem.eql(u8, name, "i16?")) return b.type_i16;
    if (std.mem.eql(u8, name, "i32?")) return b.type_i32;
    if (std.mem.eql(u8, name, "i64?")) return b.type_i64;
    if (std.mem.eql(u8, name, "c8?")) return b.type_c8;
    if (std.mem.eql(u8, name, "c16?")) return b.type_c16;
    if (std.mem.eql(u8, name, "c32?")) return b.type_c32;
    if (std.mem.eql(u8, name, "c64?")) return b.type_c64;
    if (std.mem.eql(u8, name, "cons?")) return b.type_cons;
    if (std.mem.eql(u8, name, "closure?")) return b.type_closure;
    if (std.mem.eql(u8, name, "intrinsic?")) return b.type_intrinsic;
    if (std.mem.eql(u8, name, "ffifunc?")) return b.type_ffifunc;
    if (std.mem.eql(u8, name, "method?")) return b.type_method;
    if (std.mem.eql(u8, name, "namespace?")) return b.type_namespace;
    return null;
}
fn typePredicateTypes(name: []const u8) ?TypeSet {
    if (typePredicateTag(name)) |tag| return typeBit(tag);
    if (std.mem.eql(u8, name, "int?")) {
        return typeBit(b.type_u8) | typeBit(b.type_u16) | typeBit(b.type_u32) | typeBit(b.type_u64) |
            typeBit(b.type_i8) | typeBit(b.type_i16) | typeBit(b.type_i32) | typeBit(b.type_i64);
    }
    if (std.mem.eql(u8, name, "float?")) {
        return typeBit(b.type_f8) | typeBit(b.type_f16) | typeBit(b.type_f32) | typeBit(b.type_f64);
    }
    if (std.mem.eql(u8, name, "complex?")) {
        return typeBit(b.type_c8) | typeBit(b.type_c16) | typeBit(b.type_c32) | typeBit(b.type_c64);
    }
    if (std.mem.eql(u8, name, "real?")) {
        return typeBit(b.type_u8) | typeBit(b.type_u16) | typeBit(b.type_u32) | typeBit(b.type_u64) |
            typeBit(b.type_i8) | typeBit(b.type_i16) | typeBit(b.type_i32) | typeBit(b.type_i64) |
            typeBit(b.type_f8) | typeBit(b.type_f16) | typeBit(b.type_f32) | typeBit(b.type_f64);
    }
    if (std.mem.eql(u8, name, "number?")) {
        return typeBit(b.type_u8) | typeBit(b.type_u16) | typeBit(b.type_u32) | typeBit(b.type_u64) |
            typeBit(b.type_i8) | typeBit(b.type_i16) | typeBit(b.type_i32) | typeBit(b.type_i64) |
            typeBit(b.type_f8) | typeBit(b.type_f16) | typeBit(b.type_f32) | typeBit(b.type_f64) |
            typeBit(b.type_c8) | typeBit(b.type_c16) | typeBit(b.type_c32) | typeBit(b.type_c64);
    }
    return null;
}

fn typeBit(object: Store.Object) TypeSet {
    const index = @intFromEnum(object);
    return if (index <= b.type_last_idx) @as(TypeSet, 1) << @intCast(index) else @as(TypeSet, 1) << 63;
}

fn typeSet(value: Value) TypeSet {
    return typeBit(value.typ);
}

fn numericConstructorTag(name: []const u8) ?Store.Object {
    if (std.mem.eql(u8, name, "f64")) return b.type_f64;
    if (std.mem.eql(u8, name, "i64")) return b.type_i64;
    return null;
}

fn arithmeticTypes(operation: Code.ArithOp, left: TypeSet, right: TypeSet) TypeSet {
    if (left != right or @popCount(left) != 1) return ts_unknown;
    const index = @ctz(left);
    if (index != @intFromEnum(b.type_i64) and index != @intFromEnum(b.type_f64)) return ts_unknown;
    return switch (operation) {
        .equal, .less, .greater => typeBit(b.type_bool),
        else => left,
    };
}

fn arithOp(name: []const u8) ?Code.ArithOp {
    if (std.mem.eql(u8, name, "+")) return .add;
    if (std.mem.eql(u8, name, "-")) return .sub;
    if (std.mem.eql(u8, name, "*")) return .mul;
    if (std.mem.eql(u8, name, "/")) return .div;
    if (std.mem.eql(u8, name, "=")) return .equal;
    if (std.mem.eql(u8, name, "<")) return .less;
    if (std.mem.eql(u8, name, ">")) return .greater;
    return null;
}

fn hasLexicalName(function: *Function, symbol: Sym) bool {
    for (function.dynamic.items) |dynamic| {
        if (sameSym(dynamic, symbol)) return true;
    }
    for (function.locals.items) |local| {
        if (sameSym(local.name, symbol)) return true;
    }
    if (function.parent) |parent| return hasLexicalName(parent, symbol);
    return false;
}

fn hasLocal(function: *Function, symbol: Sym) bool {
    for (function.locals.items) |local| if (sameSym(local.name, symbol)) return true;
    return false;
}

fn sameSym(a: Sym, b_: Sym) bool {
    return a == b_ or std.mem.eql(u8, a.*, b_.*);
}

fn sameValue(a: Value, b_: Value) bool {
    return a.typ == b_.typ and a.obj == b_.obj;
}

fn isSymbol(value: Value, name: []const u8) bool {
    return value.typ == b.type_symbol and std.mem.eql(u8, value.obj.toPtr(Sym).*, name);
}

fn isHead(value: Value, name: []const u8) bool {
    if (value.typ != b.type_cons) return false;
    return isSymbol(value.obj.toRef().deref([2]Value)[0], name);
}

fn isUseForm(value: Value) bool {
    return isHead(value, "use");
}

fn isOption(value: Value, option: []const u8) bool {
    if (value.typ != b.type_keyword and value.typ != b.type_symbol) return false;
    const text = value.obj.toPtr(Sym).*;
    if (std.mem.eql(u8, text, option)) return true;
    return text.len == option.len + 1 and text[0] == ':' and std.mem.eql(u8, text[1..], option);
}

fn validLocalName(name: Sym) bool {
    return name.*.len != 0 and
        name.*[0] != '@' and
        std.mem.findScalar(u8, name.*, '/') == null;
}

fn shifted(origin: Origin, delta: u32) Origin {
    return .{
        .source = origin.source,
        .index = if (origin.index == Code.invalid_index) Code.invalid_index else origin.index +| delta,
    };
}

fn addIndex(left: u32, right: u32) Error!u32 {
    const value = std.math.add(u32, left, right) catch return error.StackOverflow;
    if (value == Code.invalid_index) return error.StackOverflow;
    return value;
}

fn copyMeta(destination: Value, source: Value) void {
    if (destination.typ != b.type_cons or source.typ != b.type_cons) return;
    const source_header: *Store.Header = @ptrFromInt(source.obj.toRef().address() - Store.header_size);
    if (source_header.meta.isNull()) return;
    const destination_header: *Store.Header = @ptrFromInt(destination.obj.toRef().address() - Store.header_size);
    destination_header.meta = source_header.meta;
}

test "Binder rejects duplicate aliases across a coalesced use run" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();

    const parsed = try Reader.readUnit(
        runtime.store,
        "(use semantics) (use (errors :as semantics))",
        .{},
    );
    var scratch_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_arena.deinit();
    try std.testing.expectError(
        error.NameConflict,
        bind(
            scratch_arena.allocator(),
            runtime,
            runtime.root_ns,
            parsed.datum,
            "test/api/main.pt",
        ),
    );
}

test "Binder validates set do and eval form arity" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var scratch_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_arena.deinit();

    const cases = [_]struct { source: []const u8, expected: Error }{
        .{ .source = "(set!)", .expected = error.ArityMismatch },
        .{ .source = "(set! target)", .expected = error.ArityMismatch },
        .{ .source = "(set! target 1 2)", .expected = error.ArityMismatch },
        .{ .source = "(set! 1 2)", .expected = error.Unimplemented },
        .{ .source = "(do)", .expected = error.ArityMismatch },
        .{ .source = "(do ())", .expected = error.ArityMismatch },
        .{ .source = "(do () ())", .expected = error.MalformedAst },
        .{ .source = "(eval)", .expected = error.ArityMismatch },
        .{ .source = "(eval 'datum 1 2)", .expected = error.ArityMismatch },
    };
    for (cases) |case| {
        const parsed = try Reader.readUnit(runtime.store, case.source, .{});
        try std.testing.expectError(
            case.expected,
            bind(
                scratch_arena.allocator(),
                runtime,
                runtime.root_ns,
                parsed.datum,
                null,
            ),
        );
    }
}

test "Binder rejects sealed numeric names at every binding site" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var scratch_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_arena.deinit();

    const sources = [_][]const u8{
        "(def f64 (use missing))",
        "(defn (i64 x) x)",
        "(let ((f64 1)) f64)",
        "(letrec ((i64 1)) i64)",
        "(do ((f64 0)) (#t 0))",
        "(fn (f64) f64)",
        "(fn i64 i64)",
        "(fn (x . i64) x)",
        "(try 1 (catch f64 2))",
        "(guard (i64 (else 2)) 1)",
        "(set! f64 1)",
        "(use (fixtures/eval-target :as i64))",
        "(use (fixtures/eval-target :refer ((phase1-eval-target-initial f64))))",
    };
    for (sources) |source| {
        const parsed = try Reader.readUnit(runtime.store, source, .{});
        try std.testing.expectError(
            error.MalformedAst,
            bind(
                scratch_arena.allocator(),
                runtime,
                runtime.root_ns,
                parsed.datum,
                "test/api/main.pt",
            ),
        );
    }
    try std.testing.expectEqual(Value.i64(11), try runtime.evalString("(let ((f32 11)) f32)"));
}

test "Binder rejects invalid use options and non-top-level use" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var scratch_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_arena.deinit();

    const sources = [_][]const u8{
        "(use (fixtures/eval-target :as one :as two))",
        "(use (fixtures/eval-target :refer (x x)))",
        "(use (fixtures/eval-target :refer :all))",
        "(use (fixtures/eval-target :prefix pre- :prefix other-))",
        "(use (fixtures/eval-target :except (x)))",
        "(use (fixtures/eval-target :as))",
        "(use (fixtures/eval-target :as bad/))",
        "(use (fixtures/eval-target :refer ((x bad/))))",
        "(fn () (use fixtures/eval-target))",
        "(if #t (use fixtures/eval-target) 0)",
    };
    for (sources) |source| {
        const parsed = try Reader.readUnit(runtime.store, source, .{});
        try std.testing.expectError(
            error.MalformedAst,
            bind(
                scratch_arena.allocator(),
                runtime,
                runtime.root_ns,
                parsed.datum,
                "test/api/main.pt",
            ),
        );
    }
}

test "Binder reports NameConflict for colliding import destinations" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var scratch_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_arena.deinit();

    const sources = [_][]const u8{
        "(use (fixtures/eval-target :refer ((x y) (z y))))",
        "(use (fixtures/eval-target :as same :refer ((x same))))",
        "(use (fixtures/eval-target :as future)) (def future 1)",
        "(use (fixtures/eval-target :refer ((phase1-eval-target-initial future)))) " ++
            "(def future 1)",
        "(use (fixtures/eval-target :as repeated)) 0 " ++
            "(use (fixtures/eval-target :as repeated))",
    };
    for (sources) |source| {
        const parsed = try Reader.readUnit(runtime.store, source, .{});
        try std.testing.expectError(
            error.NameConflict,
            bind(
                scratch_arena.allocator(),
                runtime,
                runtime.root_ns,
                parsed.datum,
                "test/api/main.pt",
            ),
        );
    }
}

test "Binder bounds coalesced use groups before lowering" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const allocator = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(allocator);

    try source.appendSlice(allocator, "(use");
    for (0..32) |i| {
        var buffer: [96]u8 = undefined;
        const spec = try std.fmt.bufPrint(&buffer, " (fixtures/eval-target :as module-{d})", .{i});
        try source.appendSlice(allocator, spec);
    }
    try source.appendSlice(allocator, ") module-31/phase1-eval-target-initial");
    const process = try runtime.spawnEvalWithNs(source.items, runtime.root_ns, "test/api/main.pt");
    try std.testing.expectEqual(Value.i64(7), try runtime.awaitProcess(process));

    source.clearRetainingCapacity();
    try source.appendSlice(allocator, "(use");
    for (0..254) |i| {
        var buffer: [96]u8 = undefined;
        const spec = try std.fmt.bufPrint(&buffer, " (fixtures/eval-target :as too-many-{d})", .{i});
        try source.appendSlice(allocator, spec);
    }
    try source.appendSlice(allocator, ")");
    const parsed = try Reader.readUnit(runtime.store, source.items, .{});
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();
    try std.testing.expectError(
        error.MalformedAst,
        bind(
            scratch_arena.allocator(),
            runtime,
            runtime.root_ns,
            parsed.datum,
            "test/api/main.pt",
        ),
    );
}

test "Binder selected imports use renamed prefixed locals and basename aliases" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const source =
        "(use (fixtures/eval-target :as values " ++
        ":refer ((phase1-eval-target-initial initial)) :prefix pre-)) " ++
        "(+ values/phase1-eval-target-initial pre-initial)";
    const process = try runtime.spawnEvalWithNs(source, runtime.root_ns, "test/api/main.pt");
    try std.testing.expectEqual(Value.i64(14), try runtime.awaitProcess(process));

    const basename = try runtime.spawnEvalWithNs(
        "(use fixtures/eval-target) eval-target/phase1-eval-target-initial",
        runtime.root_ns,
        "test/api/main.pt",
    );
    try std.testing.expectEqual(Value.i64(7), try runtime.awaitProcess(basename));

    const unselected = try runtime.spawnEvalWithNs(
        "(use (fixtures/eval-target :as namespace-only)) phase1-eval-target-initial",
        runtime.root_ns,
        "test/api/main.pt",
    );
    try std.testing.expectError(error.Unbound, runtime.awaitProcess(unselected));

    const referred = try runtime.spawnEvalWithNs(
        "(use (fixtures/eval-target :as selected " ++
            ":refer (phase1-eval-target-initial))) phase1-eval-target-initial",
        runtime.root_ns,
        "test/api/main.pt",
    );
    try std.testing.expectEqual(Value.i64(7), try runtime.awaitProcess(referred));
}

test "Binder separates conflicting export names from malformed export syntax" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var scratch_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_arena.deinit();

    const cases = [_]struct { source: []const u8, expected: Error }{
        .{ .source = "(export x (rename y x))", .expected = error.NameConflict },
        .{ .source = "(export (rename x y) (from lib z (other y)))", .expected = error.NameConflict },
        .{ .source = "(export (rename x))", .expected = error.MalformedAst },
        .{ .source = "(export (from lib (x y) (z y)))", .expected = error.NameConflict },
        .{ .source = "(export (from lib))", .expected = error.MalformedAst },
        .{ .source = "(export (rename x bad/))", .expected = error.MalformedAst },
    };
    for (cases) |case| {
        const parsed = try Reader.readUnit(runtime.store, case.source, .{});
        try std.testing.expectError(
            case.expected,
            bind(
                scratch_arena.allocator(),
                runtime,
                runtime.root_ns,
                parsed.datum,
                "test/api/main.pt",
            ),
        );
    }
}

test "Binder exports local renames and selected alias reexports" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    const module_path = try std.Io.Dir.cwd().realPathFileAlloc(
        runtime.io,
        "test/api/semantics.pt",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(module_path);

    const source =
        "(use (fixtures/eval-target :as dep)) " ++
        "(def local 5) " ++
        "(export (rename local renamed) " ++
        "(from dep phase1-eval-target-initial (phase1-eval-target-initial upstream)))";
    const main = try runtime.spawnEvalWithNs(source, runtime.root_ns, module_path);
    try runtime.registerMainModule(module_path, main);
    try std.testing.expectEqual(Value.nil, try runtime.awaitProcess(main));

    const reader = try runtime.spawnEvalWithNs(
        "(def view (load \"semantics.pt\")) " ++
            "(+ (:renamed view) (+ (:phase1-eval-target-initial view) (:upstream view)))",
        runtime.root_ns,
        "test/api/main.pt",
    );
    try std.testing.expectEqual(Value.i64(19), try runtime.awaitProcess(reader));
}

test "Binder records exact types for canonical numeric constructors only" {
    const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    var scratch_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch_arena.deinit();

    const parsed = try Reader.readUnit(
        runtime.store,
        "(+ (f64 2) (@f64 3)) (+ (i64 2.0) (@i64 3.0))",
        .{},
    );
    const code = try bind(scratch_arena.allocator(), runtime, runtime.root_ns, parsed.datum, null);
    var f64_calls: usize = 0;
    var i64_calls: usize = 0;
    for (code.nodes) |node| {
        switch (node.operation) {
            .arithmetic => |arithmetic| {
                if (arithmetic.left_types == typeBit(b.type_f64) and
                    arithmetic.right_types == typeBit(b.type_f64))
                {
                    f64_calls += 1;
                }
                if (arithmetic.left_types == typeBit(b.type_i64) and
                    arithmetic.right_types == typeBit(b.type_i64))
                {
                    i64_calls += 1;
                }
            },
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 1), f64_calls);
    try std.testing.expectEqual(@as(usize, 1), i64_calls);
}

/// Compile `source` through the real register pipeline and run it on a fresh
/// top-level fiber, so these assert consumer-visible behaviour rather than
/// the shape of the emitted nodes.
fn runProgram(runtime: *Runtime, source: []const u8) !Value {
    const forms = try Reader.readAll(runtime.store, source);
    const program = try runtime.compileData(runtime.root_ns, forms, null);
    const capacity = Runtime.frame_size + @as(usize, program.nregs) * 2;
    const stack = try std.testing.allocator.alloc(Object, capacity);
    defer std.testing.allocator.free(stack);
    @memset(stack, .null);
    var fiber: Runtime.Fiber = .{
        .stack = stack,
        .sp = capacity,
        .ip = program.ir.ptr,
        .ir = program.ir,
        .nregs = program.nregs,
        .consts = program.constants,
        .fns = program.fns,
        .ns = runtime.root_ns,
    };
    return runtime.runToCompletion(runtime.root_ns, &fiber);
}

/// Run `source` under an explicit `let_binding_registers` setting. Both sides
/// must agree: the optimization may only remove a namespace lookup, never
/// change what a program computes.
fn expectParity(source: []const u8, expected: Value) !void {
    var runtime = try Runtime.init(std.testing.allocator, std.testing.io);
    defer runtime.deinit();
    runtime.compiler_opts.let_binding_registers = true;
    try std.testing.expectEqual(expected, try runProgram(runtime, source));

    runtime.compiler_opts.let_binding_registers = false;
    try std.testing.expectEqual(expected, try runProgram(runtime, source));
}

test "let bindings read as lexical values across nested and repeated calls" {
    // The mandelbrot shape: two let names, each read several times, with a
    // recursive call in between. Register-resident reads must not disturb the
    // values the recursion is handed.
    try expectParity(
        "(defn (bounded i zr zi) (if (= i 0) 0" ++
            " (let ((nzi (+ zi 1)) (nzr (+ zr 1)))" ++
            "  (+ (bounded (- i 1) nzr nzi) (+ (* nzi nzr) nzi))))) (bounded 3 0 0)",
        Value.i64(20),
    );

    // Same binding read many times, across a branch, with no set! anywhere.
    try expectParity(
        "(let ((k 3)) (+ (* k k) (+ (* k k) (* k k))))",
        Value.i64(27),
    );
}

test "let initializer scope stays sequential and shadowing stays nested" {
    // A later initializer sees the earlier binding of the same let.
    try expectParity("(let ((a 1) (b (+ a 10)) (c (+ b 100))) (+ a (+ b c)))", Value.i64(123));
    // An inner let shadows; the outer name is intact once the frame pops.
    try expectParity("(let ((x 1)) (let ((x 2)) (+ x 10)))", Value.i64(12));
    try expectParity("(let ((x 1)) (+ (let ((x 2)) x) x))", Value.i64(3));
}

test "set! def and closures keep mutating a let cell" {
    // Local mutation of the let itself.
    try expectParity("(let ((x 1)) (set! x 5) x)", Value.i64(5));
    // A closure mutating the enclosing let: the cell, not a register copy,
    // is the value the frame observes afterwards.
    try expectParity("(let ((x 1)) (defn (bump) (set! x 5)) (bump) x)", Value.i64(5));
    // A def inside a nested function rebinding an outer let name.
    try expectParity("(let ((x 1)) (defn (rebind) (def x 2)) (rebind) x)", Value.i64(2));
    // An escaping closure reads the cell as it stands at call time.
    try expectParity("(let ((x 1)) (defn (get) x) (set! x 9) (get))", Value.i64(9));
    // A closure created before the mutation still sees the new value.
    try expectParity("(let ((x 1)) (defn (get) x) (defn (bump) (set! x 4)) (bump) (get))", Value.i64(4));
    // do-loop step bindings are rewritten every iteration, and the loop test
    // reads the cell after the body has stepped.
    try expectParity("(do ((i 0 (+ i 1))) ((= i 5) i))", Value.i64(5));
    try expectParity("(do ((i 0 (+ i 1))) ((= i 3) (* i 10)))", Value.i64(30));
}

test "eval observes and rebinds the nearest let namespace" {
    // eval runs against the live frame, so it must both read the let and be
    // able to change it behind an otherwise register-resident read.
    try expectParity("(let ((x 1)) (eval 'x))", Value.i64(1));
    try expectParity("(let ((x 1)) (eval '(set! x 7)) x)", Value.i64(7));
    try expectParity("(let ((x 1)) (defn (bump) (eval '(set! x 3))) (bump) x)", Value.i64(3));
    try expectParity("(let ((x 1)) (eval '(def x 8)) x)", Value.i64(8));
}

test "letrec recursion works and prebind cells stay uninitialized" {
    try expectParity(
        "(letrec ((fact (fn (n) (if (= n 0) 1 (* n (fact (- n 1))))))) (fact 5))",
        Value.i64(120),
    );
    // Reading a not-yet-initialized letrec cell is an error, not the value the
    // binding ends up with later. A register copy would wrongly answer 2.
    for ([_]bool{ true, false }) |registers| {
        const runtime = try Runtime.init(std.testing.allocator, std.testing.io);
        defer runtime.deinit();
        runtime.compiler_opts.let_binding_registers = registers;
        // `evalString` surfaces the raised error itself; a raw fiber returns it
        // as a raised error Value instead.
        try std.testing.expectError(
            error.UninitializedBinding,
            runtime.evalString("(letrec ((a b) (b 2)) a)"),
        );
    }
}
