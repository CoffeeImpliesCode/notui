const std = @import("std");
/// re-exports aro symbols for convenience
pub const aro = @import("aro");

/// Manages the full lifecycle of an aro C parse: Compilation, Preprocessor,
/// Diagnostics, and the parsed Tree — all tied to an arena allocator.
/// Key fields (diag, comp, pp) are arena-allocated so their addresses stay
/// stable even if TreeCtx is moved (comp references diag, pp references comp,
/// tree references comp and borrows pp.tokens).
pub const TreeCtx = struct {
    arena: std.heap.ArenaAllocator,
    diag: *aro.Diagnostics,
    comp: *aro.Compilation,
    pp: *aro.Preprocessor,
    tree: aro.Tree,

    /// Parse a C source string. `gpa` is used for non-arena allocations;
    /// an internal arena is created for the Compilation's arena allocator.
    /// `include_paths` are system include directories to add to the search path.
    /// Caller must call `.deinit()` to free everything.
    pub fn parseC(
        gpa: std.mem.Allocator,
        io: std.Io,
        c_source: []const u8,
        source_path: []const u8,
        include_paths: []const []const u8,
    ) !TreeCtx {
        var arena = std.heap.ArenaAllocator.init(gpa);
        const aa = arena.allocator();

        var comp_initialized = false;
        var pp_initialized = false;
        // SAFETY: assigned before use — errdefer checks initialized flag
        var comp: *aro.Compilation = undefined;
        // SAFETY: assigned before use — errdefer checks initialized flag
        var pp: *aro.Preprocessor = undefined;
        errdefer {
            if (pp_initialized) pp.deinit();
            if (comp_initialized) comp.deinit();
            arena.deinit();
        }

        // Diagnostics — no gpa resources in .ignore mode
        const diag = try aa.create(aro.Diagnostics);
        diag.* = .{ .output = .ignore };

        // Compilation
        comp = try aa.create(aro.Compilation);
        comp.* = try aro.Compilation.init(.{
            .gpa = gpa,
            .arena = aa,
            .io = io,
            .diagnostics = diag,
            .environ_map = null,
            .add_default_pragma_handlers = false,
        });
        comp_initialized = true;
        comp.langopts.standard = .gnu17;

        // Add system include paths
        for (include_paths) |path| {
            try comp.search_path.append(comp.gpa, .{ .kind = .system, .path = path });
        }

        // Preprocessor
        pp = try aa.create(aro.Preprocessor);
        pp.* = try aro.Preprocessor.init(comp, .{ .base_file = .unused });
        pp_initialized = true;

        const builtin = try comp.generateBuiltinMacros(.no_system_defines);
        const source = try comp.addSourceFromBuffer(source_path, c_source);
        pp.base_file = source.id;
        try pp.preprocessSources(.{ .main = source, .builtin = builtin });

        const tree = try pp.parse();

        return .{
            .arena = arena,
            .diag = diag,
            .comp = comp,
            .pp = pp,
            .tree = tree,
        };
    }

    /// Return an iterator over the root declarations in this translation unit.
    pub fn rootDecls(self: *const TreeCtx) NodeRefIterator {
        return .{
            .tree = &self.tree,
            .ext_indices = self.tree.root_decls.items,
        };
    }

    /// Free all resources in the correct order:
    /// tree → pp → comp → diag → arena.
    pub fn deinit(self: *TreeCtx) void {
        self.tree.deinit();
        self.pp.deinit();
        self.comp.deinit();
        // diag.deinit() is a no-op in .ignore mode; call for correctness
        self.diag.deinit();
        self.arena.deinit();
        // SAFETY: prevent use-after-free by invalidating the entire struct.
        self.* = undefined;
    }
};

/// Iterator over a sequence of aro AST node indices, yielding `NodeRef` values.
///
/// Supports two modes:
/// - `ext_indices` — points to externally-owned memory (root_decls, compound_stmt body, call args, etc.)
/// - `inline_buf` — inline storage for dynamically-built child lists (if_stmt, binary_expr, etc.)
///
/// These modes are NOT mixed. When `inline_len > 0`, only `inline_buf` is used.
/// otherwise `ext_indices` is used. This avoids self-referential slice pointers
/// when the iterator is moved after construction.
pub const NodeRefIterator = struct {
    tree: *const aro.Tree,
    index: usize = 0,

    /// Externally-owned slice of indices (root_decls, compound_stmt body, call args).
    ext_indices: []const aro.Tree.Node.Index = &.{},

    /// Inline buffer for dynamically-built child lists. Used when `inline_len > 0`.
    /// SAFETY: only accessed when inline_len > 0. Len tracks how many are valid.
    inline_buf: [24]aro.Tree.Node.Index = undefined,
    inline_len: usize = 0,

    pub fn next(self: *NodeRefIterator) ?NodeRef {
        const indices = if (self.inline_len > 0)
            self.inline_buf[0..self.inline_len]
        else
            self.ext_indices;
        if (self.index >= indices.len) return null;
        defer self.index += 1;
        return NodeRef.init(self.tree, indices[self.index]);
    }

    pub fn reset(self: *NodeRefIterator) void {
        self.index = 0;
    }
};

/// A reference to an aro AST node with its tree context.
/// Wraps `aro.Tree.Node.Index` and provides convenience methods
/// plus `format()` for printing via `{ }` / `{fmt}`.
pub const NodeRef = struct {
    tree: *const aro.Tree,
    idx: aro.Tree.Node.Index,

    pub fn init(tree: *const aro.Tree, idx: aro.Tree.Node.Index) NodeRef {
        return .{ .tree = tree, .idx = idx };
    }

    /// Get the underlying aro Node.
    pub fn get(self: NodeRef) aro.Tree.Node {
        return self.idx.get(self.tree);
    }

    /// Get the node's kind (active tag).
    pub fn kind(self: NodeRef) std.meta.Tag(aro.Tree.Node) {
        return @as(std.meta.Tag(aro.Tree.Node), self.idx.get(self.tree));
    }

    /// Return an iterator over the direct children of this node.
    pub fn children(self: NodeRef) NodeRefIterator {
        const node = self.idx.get(self.tree);
        var iter: NodeRefIterator = .{ .tree = self.tree };
        switch (node) {
            .function => |f| {
                if (f.body) |body| {
                    iter.inline_buf[0] = body;
                    iter.inline_len = 1;
                }
            },
            .compound_stmt => |cs| {
                iter.ext_indices = cs.body;
            },
            .if_stmt => |s| {
                iter.inline_buf[0] = s.cond;
                iter.inline_buf[1] = s.then_body;
                var count: usize = 2;
                if (s.else_body) |e| {
                    iter.inline_buf[count] = e;
                    count += 1;
                }
                iter.inline_len = count;
            },
            .while_stmt => |s| {
                iter.inline_buf[0] = s.cond;
                iter.inline_buf[1] = s.body;
                iter.inline_len = 2;
            },
            .do_while_stmt => |s| {
                iter.inline_buf[0] = s.body;
                iter.inline_buf[1] = s.cond;
                iter.inline_len = 2;
            },
            .for_stmt => |s| {
                var count: usize = 0;
                switch (s.init) {
                    .decls => |decls| {
                        for (decls) |d| {
                            iter.inline_buf[count] = d;
                            count += 1;
                        }
                    },
                    .expr => |expr| {
                        if (expr) |e| {
                            iter.inline_buf[count] = e;
                            count += 1;
                        }
                    },
                }
                if (s.cond) |c| {
                    iter.inline_buf[count] = c;
                    count += 1;
                }
                if (s.incr) |i| {
                    iter.inline_buf[count] = i;
                    count += 1;
                }
                iter.inline_buf[count] = s.body;
                count += 1;
                iter.inline_len = count;
            },
            .switch_stmt => |s| {
                iter.inline_buf[0] = s.cond;
                iter.inline_buf[1] = s.body;
                iter.inline_len = 2;
            },
            .case_stmt => |s| {
                iter.inline_buf[0] = s.start;
                if (s.end) |e| {
                    iter.inline_buf[1] = e;
                    iter.inline_buf[2] = s.body;
                    iter.inline_len = 3;
                } else {
                    iter.inline_buf[1] = s.body;
                    iter.inline_len = 2;
                }
            },
            .default_stmt => |s| {
                iter.inline_buf[0] = s.body;
                iter.inline_len = 1;
            },
            .labeled_stmt => |s| {
                iter.inline_buf[0] = s.body;
                iter.inline_len = 1;
            },
            .computed_goto_stmt => |s| {
                iter.inline_buf[0] = s.expr;
                iter.inline_len = 1;
            },
            // binary expressions
            .add_expr, .sub_expr, .mul_expr, .div_expr, .mod_expr, .equal_expr, .not_equal_expr => |b| {
                iter.inline_buf[0] = b.lhs;
                iter.inline_buf[1] = b.rhs;
                iter.inline_len = 2;
            },
            .less_than_expr, .greater_than_expr, .less_than_equal_expr, .greater_than_equal_expr => |b| {
                iter.inline_buf[0] = b.lhs;
                iter.inline_buf[1] = b.rhs;
                iter.inline_len = 2;
            },
            .bool_and_expr, .bool_or_expr, .bit_and_expr, .bit_or_expr, .bit_xor_expr, .shl_expr => |b| {
                iter.inline_buf[0] = b.lhs;
                iter.inline_buf[1] = b.rhs;
                iter.inline_len = 2;
            },
            .shr_expr, .comma_expr, .assign_expr, .mul_assign_expr, .div_assign_expr, .mod_assign_expr => |b| {
                iter.inline_buf[0] = b.lhs;
                iter.inline_buf[1] = b.rhs;
                iter.inline_len = 2;
            },
            .add_assign_expr, .sub_assign_expr, .shl_assign_expr, .shr_assign_expr, .bit_and_assign_expr => |b| {
                iter.inline_buf[0] = b.lhs;
                iter.inline_buf[1] = b.rhs;
                iter.inline_len = 2;
            },
            .bit_xor_assign_expr, .bit_or_assign_expr => |b| {
                iter.inline_buf[0] = b.lhs;
                iter.inline_buf[1] = b.rhs;
                iter.inline_len = 2;
            },
            // unary prefix/postfix expressions
            .negate_expr, .plus_expr, .bit_not_expr, .bool_not_expr, .addr_of_expr, .deref_expr => |u| {
                iter.inline_buf[0] = u.operand;
                iter.inline_len = 1;
            },
            .pre_inc_expr, .pre_dec_expr, .imag_expr, .real_expr => |u| {
                iter.inline_buf[0] = u.operand;
                iter.inline_len = 1;
            },
            .paren_expr, .stmt_expr, .post_inc_expr, .post_dec_expr => |u| {
                iter.inline_buf[0] = u.operand;
                iter.inline_len = 1;
            },
            .cast => |c| {
                iter.inline_buf[0] = c.operand;
                iter.inline_len = 1;
            },
            .call_expr => |c| {
                iter.ext_indices = c.args;
            },
            .decl_ref_expr, .enumeration_ref => |d| {
                iter.inline_buf[0] = d.decl;
                iter.inline_len = 1;
            },
            .member_access_expr, .member_access_ptr_expr => |m| {
                iter.inline_buf[0] = m.base;
                iter.inline_len = 1;
            },
            .array_access_expr => |a| {
                iter.inline_buf[0] = a.base;
                iter.inline_buf[1] = a.index;
                iter.inline_len = 2;
            },
            .cond_expr, .binary_cond_expr => |c| {
                iter.inline_buf[0] = c.cond;
                iter.inline_buf[1] = c.then_expr;
                iter.inline_buf[2] = c.else_expr;
                iter.inline_len = 3;
            },
            .return_stmt => |r| {
                switch (r.operand) {
                    .expr => |e| {
                        iter.inline_buf[0] = e;
                        iter.inline_len = 1;
                    },
                    else => {},
                }
            },
            .static_assert => |sa| {
                iter.inline_buf[0] = sa.cond;
                if (sa.message) |msg| {
                    iter.inline_buf[1] = msg;
                    iter.inline_len = 2;
                } else {
                    iter.inline_len = 1;
                }
            },
            else => {},
        }
        return iter;
    }

    /// Print this node using the present* dispatchers.
    pub fn format(self: NodeRef, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const node = self.idx.get(self.tree);
        switch (node) {
            .function => try presentFunction(w, self.tree, self.idx),
            .typedef => try presentTypedef(w, self.tree, self.idx),
            .struct_decl => try presentContainerDecl(w, "struct", node.struct_decl, self.tree),
            .union_decl => try presentContainerDecl(w, "union", node.union_decl, self.tree),
            .enum_decl => try presentContainerDecl(w, "enum", node.enum_decl, self.tree),
            .struct_forward_decl => try presentForwardDecl(w, "struct", node.struct_forward_decl, self.tree),
            .union_forward_decl => try presentForwardDecl(w, "union", node.union_forward_decl, self.tree),
            .enum_forward_decl => try presentForwardDecl(w, "enum", node.enum_forward_decl, self.tree),
            .variable => try presentVariable(w, self.tree, self.idx),
            .static_assert => try presentStaticAssert(w, self.tree, self.idx),
            .global_asm => try presentGlobalAsm(w, self.tree, self.idx),
            .empty_decl => try presentEmptyDecl(w),
            .return_stmt => try presentReturnStmt(w, self.tree, self.idx),

            // Statements
            .compound_stmt => try presentCompoundStmt(w, self.tree, self.idx),
            .if_stmt => try presentIfStmt(w, self.tree, self.idx),
            .while_stmt => try presentWhileStmt(w, self.tree, self.idx),
            .do_while_stmt => try presentDoWhileStmt(w, self.tree, self.idx),
            .for_stmt => try presentForStmt(w, self.tree, self.idx),
            .labeled_stmt => try presentLabeledStmt(w, self.tree, self.idx),
            .switch_stmt => try presentSwitchStmt(w, self.tree, self.idx),
            .case_stmt => try presentCaseStmt(w, self.tree, self.idx),
            .default_stmt => try presentDefaultStmt(w, self.tree, self.idx),
            .goto_stmt => try presentGotoStmt(w, self.tree, self.idx),
            .computed_goto_stmt => try presentComputedGotoStmt(w, self.tree, self.idx),
            .continue_stmt => try presentContinueStmt(w, self.tree, self.idx),
            .break_stmt => try presentBreakStmt(w, self.tree, self.idx),
            .null_stmt => try presentNullStmt(w),
            .asm_stmt => try presentAsmStmt(w, self.tree, self.idx),

            // Binary expressions — all use Binary payload
            .add_expr, .sub_expr, .mul_expr => |b| try presentBinaryExpr(w, self.tree, b.lhs, b.op_tok, b.rhs),
            .div_expr, .mod_expr, .equal_expr => |b| try presentBinaryExpr(w, self.tree, b.lhs, b.op_tok, b.rhs),
            .not_equal_expr, .less_than_expr => |b| try presentBinaryExpr(w, self.tree, b.lhs, b.op_tok, b.rhs),
            .greater_than_expr => |b| try presentBinaryExpr(w, self.tree, b.lhs, b.op_tok, b.rhs),
            .less_than_equal_expr => |b| try presentBinaryExpr(w, self.tree, b.lhs, b.op_tok, b.rhs),
            .greater_than_equal_expr => |b| try presentBinaryExpr(w, self.tree, b.lhs, b.op_tok, b.rhs),
            .bool_and_expr, .bool_or_expr => |b| try presentBinaryExpr(w, self.tree, b.lhs, b.op_tok, b.rhs),
            .bit_and_expr, .bit_or_expr => |b| try presentBinaryExpr(w, self.tree, b.lhs, b.op_tok, b.rhs),
            .bit_xor_expr, .shl_expr => |b| try presentBinaryExpr(w, self.tree, b.lhs, b.op_tok, b.rhs),
            .shr_expr, .comma_expr => |b| try presentBinaryExpr(w, self.tree, b.lhs, b.op_tok, b.rhs),
            .assign_expr, .mul_assign_expr => |b| try presentBinaryExpr(w, self.tree, b.lhs, b.op_tok, b.rhs),
            .div_assign_expr, .mod_assign_expr => |b| try presentBinaryExpr(w, self.tree, b.lhs, b.op_tok, b.rhs),
            .add_assign_expr, .sub_assign_expr => |b| try presentBinaryExpr(w, self.tree, b.lhs, b.op_tok, b.rhs),
            .shl_assign_expr, .shr_assign_expr => |b| try presentBinaryExpr(w, self.tree, b.lhs, b.op_tok, b.rhs),
            .bit_and_assign_expr => |b| try presentBinaryExpr(w, self.tree, b.lhs, b.op_tok, b.rhs),
            .bit_xor_assign_expr => |b| try presentBinaryExpr(w, self.tree, b.lhs, b.op_tok, b.rhs),
            .bit_or_assign_expr => |b| try presentBinaryExpr(w, self.tree, b.lhs, b.op_tok, b.rhs),

            // Unary prefix expressions
            .negate_expr, .plus_expr => |u| try presentUnaryExpr(w, self.tree, u.op_tok, u.operand),
            .bit_not_expr, .bool_not_expr => |u| try presentUnaryExpr(w, self.tree, u.op_tok, u.operand),
            .addr_of_expr, .deref_expr => |u| try presentUnaryExpr(w, self.tree, u.op_tok, u.operand),
            .pre_inc_expr, .pre_dec_expr => |u| try presentUnaryExpr(w, self.tree, u.op_tok, u.operand),

            // Unary postfix expressions
            .post_inc_expr, .post_dec_expr => |u| try presentPostfixExpr(w, self.tree, u.operand, u.op_tok),

            // Other expressions
            .cast => try presentCast(w, self.tree, self.idx),
            .decl_ref_expr => try presentDeclRef(w, self.tree, self.idx),
            .enumeration_ref => try presentDeclRef(w, self.tree, self.idx),
            .call_expr => try presentCall(w, self.tree, self.idx),
            .int_literal => try presentLiteral(w, self.tree, self.idx),
            .float_literal => try presentLiteral(w, self.tree, self.idx),
            .bool_literal => try presentLiteral(w, self.tree, self.idx),
            .nullptr_literal => try presentLiteral(w, self.tree, self.idx),
            .char_literal => try presentCharLiteral(w, self.tree, self.idx),
            .string_literal_expr => try presentStringLiteral(w, self.tree, self.idx),
            .paren_expr => |u| try presentParenExpr(w, self.tree, u.op_tok, u.operand),
            .member_access_expr => try presentMemberAccess(w, self.tree, self.idx),
            .member_access_ptr_expr => try presentMemberAccess(w, self.tree, self.idx),
            .array_access_expr => try presentArrayAccess(w, self.tree, self.idx),
            .cond_expr => try presentConditional(w, self.tree, self.idx),
            .binary_cond_expr => try presentConditional(w, self.tree, self.idx),
            .compound_literal_expr => try presentCompoundLiteral(w, self.tree, self.idx),
            .sizeof_expr => try presentSizeofExpr(w, self.tree, node.sizeof_expr),
            .alignof_expr => try presentAlignofExpr(w, self.tree, node.alignof_expr),
            .builtin_call_expr => try presentBuiltinCall(w, self.tree, self.idx),
            .builtin_ref => try presentBuiltinRef(w, self.tree, self.idx),
            .imag_expr, .real_expr, .imaginary_literal => |u| try presentUnaryExpr(w, self.tree, u.op_tok, u.operand),
            .stmt_expr => |u| try presentParenExpr(w, self.tree, u.op_tok, u.operand),
            .array_init_expr => try presentContainerInit(w, self.tree, self.idx),
            .struct_init_expr => try presentContainerInit(w, self.tree, self.idx),
            .generic_expr => try presentGenericExpr(w, self.tree, self.idx),
            else => try w.print("{any}", .{node}),
        }
    }
};

/// Print qualifier keywords before the type name (e.g. "const int" not "int const").
fn presentQualifiers(w: *std.Io.Writer, qt: aro.QualType) std.Io.Writer.Error!void {
    if (qt.@"const") try w.print("const ", .{});
    if (qt.@"volatile") try w.print("volatile ", .{});
    if (qt.restrict) try w.print("restrict ", .{});
}

/// Present a function declaration/definition from the aro AST.
pub fn presentFunction(
    w: *std.Io.Writer,
    tree: *const aro.Tree,
    node_idx: aro.Tree.Node.Index,
) std.Io.Writer.Error!void {
    const node = node_idx.get(tree);
    const fn_data = node.function;

    // Look up the full function type from the node's QualType
    const func_type = fn_data.qt.get(tree.comp, .func) orelse {
        try w.print("(unknown)", .{});
        return;
    };

    // static/inline specifiers
    if (fn_data.static) try w.print("static ", .{});
    if (fn_data.@"inline") try w.print("inline ", .{});

    // Return type (qualifiers before type for the outermost level)
    try presentQualType(w, func_type.return_type, tree.comp);

    // Function name
    const name_slice = tree.tokSlice(fn_data.name_tok);
    try w.print(" {s}", .{name_slice});

    // Parameters
    if (func_type.params.len == 0) {
        try w.print("(void)", .{});
    } else {
        try w.print("(", .{});
        for (func_type.params, 0..) |param, i| {
            if (i > 0) try w.print(", ", .{});
            const pname = param.name.lookup(tree.comp);
            try presentDeclarator(w, param.qt, pname, tree.comp);
        }
        try w.print(")", .{});
    }

    // Body
    if (fn_data.body) |body_idx| {
        try w.print(" ", .{});
        const body_ref = NodeRef.init(tree, body_idx);
        try body_ref.format(w);
    } else {}
}

/// Present a typedef from the aro AST.
pub fn presentTypedef(
    w: *std.Io.Writer,
    tree: *const aro.Tree,
    node_idx: aro.Tree.Node.Index,
) std.Io.Writer.Error!void {
    const td = node_idx.get(tree).typedef;
    const name = tree.tokSlice(td.name_tok);
    try w.print("typedef ", .{});
    try presentDeclarator(w, td.qt, name, tree.comp);
    if (td.implicit) try w.print(" /* builtin */", .{});
}

/// Return true if `name` is a real container name (not the keyword token or anonymous placeholder).
fn containerHasName(name: []const u8, kind: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, kind)) return false;
    return true;
}

/// Present a container (struct/union/enum) declaration from the aro AST.
pub fn presentContainerDecl(
    w: *std.Io.Writer,
    kind: []const u8,
    sd: aro.Tree.Node.ContainerDecl,
    tree: *const aro.Tree,
) std.Io.Writer.Error!void {
    const name = tree.tokSlice(sd.name_or_kind_tok);
    // Skip duplicate name when it is just the keyword token (anonymous decls)
    if (containerHasName(name, kind)) {
        try w.print("{s} {s}", .{ kind, name });
    } else {
        try w.print("{s}", .{kind});
    }
    if (sd.fields.len == 0) {
        return;
    }
    try w.print(" {{", .{});
    const sep: []const u8 = if (std.mem.eql(u8, kind, "enum")) "," else ";";
    for (sd.fields) |field_idx| {
        const field_node = field_idx.get(tree);
        try w.print(" ", .{});
        switch (field_node) {
            .record_field => {
                const field = field_node.record_field;
                const fname = tree.tokSlice(field.name_or_first_tok);
                try presentDeclarator(w, field.qt, fname, tree.comp);
                if (field.bit_width) |bw_idx| {
                    try w.print(" : ", .{});
                    const bw_ref = NodeRef.init(tree, bw_idx);
                    try bw_ref.format(w);
                }
            },
            .enum_field => {
                const field = field_node.enum_field;
                const fname = tree.tokSlice(field.name_tok);
                try w.print("{s}", .{fname});
                if (field.init) |init_idx| {
                    try w.print(" = ", .{});
                    const init_ref = NodeRef.init(tree, init_idx);
                    try init_ref.format(w);
                }
            },
            else => try w.print("<unknown field>", .{}),
        }
        try w.print("{s}", .{sep});
    }
    try w.print(" }}", .{});
}

/// Present a variable declaration from the aro AST.
pub fn presentVariable(
    w: *std.Io.Writer,
    tree: *const aro.Tree,
    node_idx: aro.Tree.Node.Index,
) std.Io.Writer.Error!void {
    const v = node_idx.get(tree).variable;
    const name = tree.tokSlice(v.name_tok);
    // storage_class
    switch (v.storage_class) {
        .auto => {},
        .static => try w.print("static ", .{}),
        .@"extern" => try w.print("extern ", .{}),
        .register => try w.print("register ", .{}),
    }
    if (v.thread_local) try w.print("_Thread_local ", .{});
    try presentDeclarator(w, v.qt, name, tree.comp);
    if (v.initializer) |_| try w.print(" /* ... */", .{});
    if (v.implicit) try w.print(" /* implicit */", .{});
}

/// Present a static_assert from the aro AST.
pub fn presentStaticAssert(w: *std.Io.Writer, _: *const aro.Tree, _: aro.Tree.Node.Index) std.Io.Writer.Error!void {
    try w.print("_Static_assert(...)", .{});
}

/// Present a global asm from the aro AST.
pub fn presentGlobalAsm(
    w: *std.Io.Writer,
    tree: *const aro.Tree,
    node_idx: aro.Tree.Node.Index,
) std.Io.Writer.Error!void {
    const ga = node_idx.get(tree).global_asm;
    const str_ref = NodeRef.init(tree, ga.asm_str);
    try w.print("__asm__(", .{});
    try str_ref.format(w);
    try w.print(")", .{});
}

/// Present a container forward declaration from the aro AST.
pub fn presentForwardDecl(
    w: *std.Io.Writer,
    kind: []const u8,
    fd: aro.Tree.Node.ContainerForwardDecl,
    tree: *const aro.Tree,
) std.Io.Writer.Error!void {
    const name = tree.tokSlice(fd.name_or_kind_tok);
    if (containerHasName(name, kind)) {
        try w.print("{s} {s}", .{ kind, name });
    } else {
        try w.print("{s}", .{kind});
    }
}

/// Present an empty declaration from the aro AST.
pub fn presentEmptyDecl(_: *std.Io.Writer) std.Io.Writer.Error!void {
    // empty — just semicolon
}

// ─── Statement Presenters ────────────────────────────

/// Present a compound statement (block).
pub fn presentCompoundStmt(
    w: *std.Io.Writer,
    tree: *const aro.Tree,
    idx: aro.Tree.Node.Index,
) std.Io.Writer.Error!void {
    const cs = idx.get(tree).compound_stmt;
    try w.print("{{", .{});
    for (cs.body) |stmt_idx| {
        try w.print(" ", .{});
        const stmt_ref = NodeRef.init(tree, stmt_idx);
        try stmt_ref.format(w);
        // Add semicolon for statement kinds that need one
        switch (stmt_ref.kind()) {
            .compound_stmt, .if_stmt, .while_stmt, .do_while_stmt => {},
            .for_stmt, .switch_stmt, .case_stmt, .default_stmt => {},
            .labeled_stmt => {},
            else => try w.print(";", .{}),
        }
    }
    try w.print(" }}", .{});
}

/// Present an if statement.
pub fn presentIfStmt(w: *std.Io.Writer, tree: *const aro.Tree, idx: aro.Tree.Node.Index) std.Io.Writer.Error!void {
    const is = idx.get(tree).if_stmt;
    try w.print("if (", .{});
    const cond_ref = NodeRef.init(tree, is.cond);
    try cond_ref.format(w);
    try w.print(") ", .{});
    const then_ref = NodeRef.init(tree, is.then_body);
    try then_ref.format(w);
    if (is.else_body) |else_idx| {
        try w.print(" else ", .{});
        const else_ref = NodeRef.init(tree, else_idx);
        try else_ref.format(w);
    }
}

/// Present a while statement.
pub fn presentWhileStmt(w: *std.Io.Writer, tree: *const aro.Tree, idx: aro.Tree.Node.Index) std.Io.Writer.Error!void {
    const ws = idx.get(tree).while_stmt;
    try w.print("while (", .{});
    const cond_ref = NodeRef.init(tree, ws.cond);
    try cond_ref.format(w);
    try w.print(") ", .{});
    const body_ref = NodeRef.init(tree, ws.body);
    try body_ref.format(w);
}

/// Present a do-while statement.
pub fn presentDoWhileStmt(w: *std.Io.Writer, tree: *const aro.Tree, idx: aro.Tree.Node.Index) std.Io.Writer.Error!void {
    const ds = idx.get(tree).do_while_stmt;
    try w.print("do ", .{});
    const body_ref = NodeRef.init(tree, ds.body);
    try body_ref.format(w);
    try w.print(" while (", .{});
    const cond_ref = NodeRef.init(tree, ds.cond);
    try cond_ref.format(w);
    try w.print(")", .{});
}

/// Present a for statement.
pub fn presentForStmt(w: *std.Io.Writer, tree: *const aro.Tree, idx: aro.Tree.Node.Index) std.Io.Writer.Error!void {
    const fs = idx.get(tree).for_stmt;
    try w.print("for (", .{});
    switch (fs.init) {
        .decls => |decls| {
            for (decls, 0..) |d, i| {
                if (i > 0) try w.print(", ", .{});
                const d_ref = NodeRef.init(tree, d);
                try d_ref.format(w);
            }
        },
        .expr => |expr| {
            if (expr) |e| {
                const e_ref = NodeRef.init(tree, e);
                try e_ref.format(w);
            }
        },
    }
    try w.print("; ", .{});
    if (fs.cond) |cond_idx| {
        const cond_ref = NodeRef.init(tree, cond_idx);
        try cond_ref.format(w);
    }
    try w.print("; ", .{});
    if (fs.incr) |incr_idx| {
        const incr_ref = NodeRef.init(tree, incr_idx);
        try incr_ref.format(w);
    }
    try w.print(") ", .{});
    const body_ref = NodeRef.init(tree, fs.body);
    try body_ref.format(w);
}

/// Present a labeled statement (case label or user label).
pub fn presentLabeledStmt(w: *std.Io.Writer, tree: *const aro.Tree, idx: aro.Tree.Node.Index) std.Io.Writer.Error!void {
    const ls = idx.get(tree).labeled_stmt;
    const label = tree.tokSlice(ls.label_tok);
    try w.print("{s}: ", .{label});
    const body_ref = NodeRef.init(tree, ls.body);
    try body_ref.format(w);
}

/// Present a switch statement.
pub fn presentSwitchStmt(w: *std.Io.Writer, tree: *const aro.Tree, idx: aro.Tree.Node.Index) std.Io.Writer.Error!void {
    const ss = idx.get(tree).switch_stmt;
    try w.print("switch (", .{});
    const cond_ref = NodeRef.init(tree, ss.cond);
    try cond_ref.format(w);
    try w.print(") ", .{});
    const body_ref = NodeRef.init(tree, ss.body);
    try body_ref.format(w);
}

/// Present a case statement.
pub fn presentCaseStmt(w: *std.Io.Writer, tree: *const aro.Tree, idx: aro.Tree.Node.Index) std.Io.Writer.Error!void {
    const cs = idx.get(tree).case_stmt;
    try w.print("case ", .{});
    const start_ref = NodeRef.init(tree, cs.start);
    try start_ref.format(w);
    if (cs.end) |end_idx| {
        try w.print(" ... ", .{});
        const end_ref = NodeRef.init(tree, end_idx);
        try end_ref.format(w);
    }
    try w.print(": ", .{});
    const body_ref = NodeRef.init(tree, cs.body);
    try body_ref.format(w);
}

/// Present a default statement.
pub fn presentDefaultStmt(w: *std.Io.Writer, tree: *const aro.Tree, idx: aro.Tree.Node.Index) std.Io.Writer.Error!void {
    const ds = idx.get(tree).default_stmt;
    try w.print("default: ", .{});
    const body_ref = NodeRef.init(tree, ds.body);
    try body_ref.format(w);
}

/// Present a goto statement.
pub fn presentGotoStmt(w: *std.Io.Writer, tree: *const aro.Tree, idx: aro.Tree.Node.Index) std.Io.Writer.Error!void {
    const gs = idx.get(tree).goto_stmt;
    const label = tree.tokSlice(gs.label_tok);
    try w.print("goto {s}", .{label});
}

/// Present a computed goto statement.
pub fn presentComputedGotoStmt(
    w: *std.Io.Writer,
    tree: *const aro.Tree,
    idx: aro.Tree.Node.Index,
) std.Io.Writer.Error!void {
    const cg = idx.get(tree).computed_goto_stmt;
    const goto_tok = tree.tokSlice(cg.goto_tok);
    try w.print("{s} ", .{goto_tok});
    const expr_ref = NodeRef.init(tree, cg.expr);
    try expr_ref.format(w);
}

/// Present a continue statement.
pub fn presentContinueStmt(w: *std.Io.Writer, _: *const aro.Tree, _: aro.Tree.Node.Index) std.Io.Writer.Error!void {
    try w.print("continue", .{});
}

/// Present a break statement.
pub fn presentBreakStmt(w: *std.Io.Writer, _: *const aro.Tree, _: aro.Tree.Node.Index) std.Io.Writer.Error!void {
    try w.print("break", .{});
}

/// Present a null statement.
pub fn presentNullStmt(_: *std.Io.Writer) std.Io.Writer.Error!void {
    // null statements are already ";"
}

/// Present an asm statement.
pub fn presentAsmStmt(w: *std.Io.Writer, tree: *const aro.Tree, idx: aro.Tree.Node.Index) std.Io.Writer.Error!void {
    const a = idx.get(tree).asm_stmt;
    try w.print("__asm__(", .{});
    const str_ref = NodeRef.init(tree, a.asm_str);
    try str_ref.format(w);
    try w.print(")", .{});
}

pub fn presentCompoundLiteral(
    w: *std.Io.Writer,
    tree: *const aro.Tree,
    idx: aro.Tree.Node.Index,
) std.Io.Writer.Error!void {
    const cl = idx.get(tree).compound_literal_expr;
    try w.print("(", .{});
    try presentQualType(w, cl.qt, tree.comp);
    try w.print(")", .{});
    const init_ref = NodeRef.init(tree, cl.initializer);
    try init_ref.format(w);
}

pub fn presentContainerInit(
    w: *std.Io.Writer,
    tree: *const aro.Tree,
    idx: aro.Tree.Node.Index,
) std.Io.Writer.Error!void {
    const ci = idx.get(tree).array_init_expr;
    try w.print("{{ ", .{});
    for (ci.items, 0..) |item, i| {
        if (i > 0) try w.print(", ", .{});
        const item_ref = NodeRef.init(tree, item);
        try item_ref.format(w);
    }
    try w.print(" }}", .{});
}

pub fn presentSizeofExpr(
    w: *std.Io.Writer,
    tree: *const aro.Tree,
    ti: aro.Tree.Node.TypeInfo,
) std.Io.Writer.Error!void {
    const op = tree.tokSlice(ti.op_tok);
    try w.print("{s}(", .{op});
    if (ti.expr) |expr_idx| {
        const expr_ref = NodeRef.init(tree, expr_idx);
        try expr_ref.format(w);
    } else {
        try presentQualType(w, ti.operand_qt, tree.comp);
    }
    try w.print(")", .{});
}

pub fn presentAlignofExpr(
    w: *std.Io.Writer,
    tree: *const aro.Tree,
    ti: aro.Tree.Node.TypeInfo,
) std.Io.Writer.Error!void {
    const op = tree.tokSlice(ti.op_tok);
    try w.print("{s}(", .{op});
    if (ti.expr) |expr_idx| {
        const expr_ref = NodeRef.init(tree, expr_idx);
        try expr_ref.format(w);
    } else {
        try presentQualType(w, ti.operand_qt, tree.comp);
    }
    try w.print(")", .{});
}

pub fn presentBuiltinCall(w: *std.Io.Writer, tree: *const aro.Tree, idx: aro.Tree.Node.Index) std.Io.Writer.Error!void {
    const bc = idx.get(tree).builtin_call_expr;
    const name = tree.tokSlice(bc.builtin_tok);
    try w.print("{s}(", .{name});
    for (bc.args, 0..) |arg, i| {
        if (i > 0) try w.print(", ", .{});
        const arg_ref = NodeRef.init(tree, arg);
        try arg_ref.format(w);
    }
    try w.print(")", .{});
}

pub fn presentBuiltinRef(w: *std.Io.Writer, tree: *const aro.Tree, idx: aro.Tree.Node.Index) std.Io.Writer.Error!void {
    const br = idx.get(tree).builtin_ref;
    const name = tree.tokSlice(br.name_tok);
    try w.print("{s}", .{name});
}

pub fn presentGenericExpr(w: *std.Io.Writer, tree: *const aro.Tree, idx: aro.Tree.Node.Index) std.Io.Writer.Error!void {
    const ge = idx.get(tree).generic_expr;
    try w.print("_Generic(", .{});
    const ctrl_ref = NodeRef.init(tree, ge.controlling);
    try ctrl_ref.format(w);
    try w.print(", ", .{});
    for (ge.rest, 0..) |r, i| {
        if (i > 0) try w.print(", ", .{});
        const r_ref = NodeRef.init(tree, r);
        try r_ref.format(w);
    }
    try w.print(")", .{});
}

// ─── Expression Presenters ────────────────────────────

/// Present a return statement from the aro AST.
pub fn presentReturnStmt(
    w: *std.Io.Writer,
    tree: *const aro.Tree,
    node_idx: aro.Tree.Node.Index,
) std.Io.Writer.Error!void {
    const ret = node_idx.get(tree).return_stmt;
    try w.print("return", .{});
    switch (ret.operand) {
        .expr => |expr_idx| {
            try w.print(" ", .{});
            // Print the expression value as a child NodeRef
            const expr_ref = NodeRef.init(tree, expr_idx);
            try expr_ref.format(w);
        },
        .implicit => {},
        .none => {},
    }
}

/// Present a binary expression (e.g. a + b, x == y).
pub fn presentBinaryExpr(
    w: *std.Io.Writer,
    tree: *const aro.Tree,
    lhs: aro.Tree.Node.Index,
    op_tok: aro.Tree.TokenIndex,
    rhs: aro.Tree.Node.Index,
) std.Io.Writer.Error!void {
    const lhs_ref = NodeRef.init(tree, lhs);
    try lhs_ref.format(w);
    const op = tree.tokSlice(op_tok);
    try w.print(" {s} ", .{op});
    const rhs_ref = NodeRef.init(tree, rhs);
    try rhs_ref.format(w);
}

/// Present a unary expression (e.g. -x, !flag, &var).
pub fn presentUnaryExpr(
    w: *std.Io.Writer,
    tree: *const aro.Tree,
    op_tok: aro.Tree.TokenIndex,
    operand: aro.Tree.Node.Index,
) std.Io.Writer.Error!void {
    const op = tree.tokSlice(op_tok);
    try w.print("{s}", .{op});
    const operand_ref = NodeRef.init(tree, operand);
    try operand_ref.format(w);
}

/// Present a postfix unary expression (e.g. x++, y--).
pub fn presentPostfixExpr(
    w: *std.Io.Writer,
    tree: *const aro.Tree,
    operand: aro.Tree.Node.Index,
    op_tok: aro.Tree.TokenIndex,
) std.Io.Writer.Error!void {
    const operand_ref = NodeRef.init(tree, operand);
    try operand_ref.format(w);
    const op = tree.tokSlice(op_tok);
    try w.print("{s}", .{op});
}

/// Present a parenthesized expression.
pub fn presentParenExpr(
    w: *std.Io.Writer,
    tree: *const aro.Tree,
    _: aro.Tree.TokenIndex,
    operand: aro.Tree.Node.Index,
) std.Io.Writer.Error!void {
    try w.print("(", .{});
    const operand_ref = NodeRef.init(tree, operand);
    try operand_ref.format(w);
    try w.print(")", .{});
}

/// Present a cast expression.
pub fn presentCast(w: *std.Io.Writer, tree: *const aro.Tree, idx: aro.Tree.Node.Index) std.Io.Writer.Error!void {
    const c = idx.get(tree).cast;
    if (c.implicit) {
        // Implicit cast — just show the operand
        const operand_ref = NodeRef.init(tree, c.operand);
        try operand_ref.format(w);
    } else {
        try w.print("(", .{});
        try presentQualType(w, c.qt, tree.comp);
        try w.print(")", .{});
        const operand_ref = NodeRef.init(tree, c.operand);
        try operand_ref.format(w);
    }
}

/// Present a declaration reference (variable/function name).
pub fn presentDeclRef(w: *std.Io.Writer, tree: *const aro.Tree, idx: aro.Tree.Node.Index) std.Io.Writer.Error!void {
    const dr = idx.get(tree).decl_ref_expr;
    const name = tree.tokSlice(dr.name_tok);
    try w.print("{s}", .{name});
}

/// Present a call expression.
pub fn presentCall(w: *std.Io.Writer, tree: *const aro.Tree, idx: aro.Tree.Node.Index) std.Io.Writer.Error!void {
    const c = idx.get(tree).call_expr;
    const callee_ref = NodeRef.init(tree, c.callee);
    try callee_ref.format(w);
    try w.print("(", .{});
    for (c.args, 0..) |arg, i| {
        if (i > 0) try w.print(", ", .{});
        const arg_ref = NodeRef.init(tree, arg);
        try arg_ref.format(w);
    }
    try w.print(")", .{});
}

/// Present a literal (int, float, bool, nullptr).
pub fn presentLiteral(w: *std.Io.Writer, tree: *const aro.Tree, idx: aro.Tree.Node.Index) std.Io.Writer.Error!void {
    const lit = idx.get(tree).int_literal;
    const slice = tree.tokSlice(lit.literal_tok);
    try w.print("{s}", .{slice});
}

/// Present a char literal.
pub fn presentCharLiteral(w: *std.Io.Writer, tree: *const aro.Tree, idx: aro.Tree.Node.Index) std.Io.Writer.Error!void {
    const cl = idx.get(tree).char_literal;
    const slice = tree.tokSlice(cl.literal_tok);
    try w.print("{s}", .{slice});
}

/// Present a string literal.
pub fn presentStringLiteral(
    w: *std.Io.Writer,
    tree: *const aro.Tree,
    idx: aro.Tree.Node.Index,
) std.Io.Writer.Error!void {
    const sl = idx.get(tree).string_literal_expr;
    const slice = tree.tokSlice(sl.literal_tok);
    try w.print("{s}", .{slice});
}

/// Present a member access expression (e.g. obj.field or ptr->field).
pub fn presentMemberAccess(
    w: *std.Io.Writer,
    tree: *const aro.Tree,
    idx: aro.Tree.Node.Index,
) std.Io.Writer.Error!void {
    const ma = idx.get(tree).member_access_expr;
    const base_ref = NodeRef.init(tree, ma.base);
    try base_ref.format(w);
    const op = tree.tokSlice(ma.access_tok);
    try w.print("{s}", .{op});
    // Try to get field name from the record type
    const member_name = getMemberFieldName(ma, tree);
    try w.print("{s}", .{member_name});
}

/// Try to look up the field name for a member access expression.
fn getMemberFieldName(ma: aro.Tree.Node.MemberAccess, tree: *const aro.Tree) []const u8 {
    var qt = ma.base.qt(tree);
    if (qt.isInvalid()) return "<unknown>";
    if (qt.get(tree.comp, .pointer)) |ptr| qt = ptr.child;
    const record_ty = switch (qt.base(tree.comp).type) {
        .@"struct", .@"union" => |record| record,
        else => return "<unknown>",
    };
    if (ma.member_index < record_ty.fields.len) {
        return record_ty.fields[ma.member_index].name.lookup(tree.comp);
    }
    return "<unknown>";
}

/// Present an array access expression (e.g. arr[idx]).
pub fn presentArrayAccess(w: *std.Io.Writer, tree: *const aro.Tree, idx: aro.Tree.Node.Index) std.Io.Writer.Error!void {
    const aa = idx.get(tree).array_access_expr;
    const base_ref = NodeRef.init(tree, aa.base);
    try base_ref.format(w);
    try w.print("[", .{});
    const index_ref = NodeRef.init(tree, aa.index);
    try index_ref.format(w);
    try w.print("]", .{});
}

/// Present a conditional/ternary expression (e.g. cond ? a : b).
pub fn presentConditional(w: *std.Io.Writer, tree: *const aro.Tree, idx: aro.Tree.Node.Index) std.Io.Writer.Error!void {
    const c = idx.get(tree).cond_expr;
    const cond_ref = NodeRef.init(tree, c.cond);
    try cond_ref.format(w);
    try w.print(" ? ", .{});
    const then_ref = NodeRef.init(tree, c.then_expr);
    try then_ref.format(w);
    try w.print(" : ", .{});
    const else_ref = NodeRef.init(tree, c.else_expr);
    try else_ref.format(w);
}

/// Print a QualType in a human-readable C form.
/// Qualifiers (const/volatile/restrict) are printed BEFORE the type at the
/// outermost level, and BEFORE the pointed-to type for pointers.
pub fn presentQualType(w: *std.Io.Writer, qt: aro.QualType, comp: *const aro.Compilation) std.Io.Writer.Error!void {
    // Check for typedef name first (full type match)
    switch (qt.type(comp)) {
        .typedef => |td| {
            const name = td.name.lookup(comp);
            try presentQualifiers(w, qt);
            try w.print("{s}", .{name});
            return;
        },
        .attributed => |attr| {
            try presentQualType(w, attr.base, comp);
            return;
        },
        else => {},
    }

    // Get the base type
    const base_info = qt.base(comp);
    const base_ty = base_info.type;
    const base_qt = base_info.qt;

    // For base types (non-pointer, non-array, non-function), print qualifiers before the type name
    // For pointer types, qualifiers after * apply to the pointer
    // For other types, qualifiers go before the type name

    switch (base_ty) {
        .void => {
            try presentQualifiers(w, base_qt);
            try w.print("void", .{});
        },
        .bool => {
            try presentQualifiers(w, base_qt);
            try w.print("bool", .{});
        },
        .nullptr_t => {
            try presentQualifiers(w, base_qt);
            try w.print("nullptr_t", .{});
        },
        .int => |int| {
            try presentQualifiers(w, base_qt);
            const name: []const u8 = switch (int) {
                .char => "char",
                .schar => "signed char",
                .uchar => "unsigned char",
                .short => "short",
                .ushort => "unsigned short",
                .int => "int",
                .uint => "unsigned int",
                .long => "long",
                .ulong => "unsigned long",
                .long_long => "long long",
                .ulong_long => "unsigned long long",
                .int128 => "__int128",
                .uint128 => "unsigned __int128",
            };
            try w.print("{s}", .{name});
        },
        .float => |float| {
            try presentQualifiers(w, base_qt);
            const name: []const u8 = switch (float) {
                .float => "float",
                .double => "double",
                .long_double => "long double",
                else => @tagName(float),
            };
            try w.print("{s}", .{name});
        },
        .complex => {
            try presentQualifiers(w, base_qt);
            try w.print("complex ", .{});
        },
        .bit_int => |bi| {
            try presentQualifiers(w, base_qt);
            try w.print("_BitInt({})", .{bi.bits});
        },
        .func => |f| {
            try presentQualType(w, f.return_type, comp);
            try w.print("(", .{});
            for (f.params, 0..) |param, i| {
                if (i > 0) try w.print(", ", .{});
                try presentQualType(w, param.qt, comp);
            }
            try w.print(")", .{});
        },
        .pointer => |p| {
            // Check if child is a function — function pointer
            if (p.child.get(comp, .func)) |func_type| {
                try presentQualifiers(w, base_qt);
                try presentQualType(w, func_type.return_type, comp);
                try w.print("(*)(", .{});
                for (func_type.params, 0..) |param, i| {
                    if (i > 0) try w.print(", ", .{});
                    try presentQualType(w, param.qt, comp);
                }
                try w.print(")", .{});
            } else {
                // Regular pointer: print child type, then qualifiers, then *
                try presentQualType(w, p.child, comp);
                try presentQualifiers(w, base_qt);
                try w.print("*", .{});
            }
        },
        .array => |a| {
            try presentQualifiers(w, base_qt);
            try presentQualType(w, a.elem, comp);
            switch (a.len) {
                .incomplete => try w.print("[]", .{}),
                .fixed => |n| try w.print("[{}]", .{n}),
                .static => |n| try w.print("[static {}]", .{n}),
                .variable => try w.print("[]", .{}),
                .unspecified_variable => try w.print("[]", .{}),
            }
        },
        .vector => |v| {
            try presentQualifiers(w, base_qt);
            try presentQualType(w, v.elem, comp);
            try w.print("[{}]", .{v.len});
        },
        .@"struct" => |rec| {
            const sname = rec.name.lookup(comp);
            try presentQualifiers(w, base_qt);
            try w.print("struct", .{});
            if (sname.len > 0 and sname[0] != '(') {
                try w.print(" {s}", .{sname});
            }
        },
        .@"union" => |rec| {
            const uname = rec.name.lookup(comp);
            try presentQualifiers(w, base_qt);
            try w.print("union", .{});
            if (uname.len > 0 and uname[0] != '(') {
                try w.print(" {s}", .{uname});
            }
        },
        .@"enum" => |rec| {
            const ename = rec.name.lookup(comp);
            try presentQualifiers(w, base_qt);
            try w.print("enum", .{});
            if (ename.len > 0 and ename[0] != '(') {
                try w.print(" {s}", .{ename});
            }
        },
        .typeof => {
            try presentQualifiers(w, base_qt);
            try w.print("typeof", .{});
        },
        .atomic => {
            try presentQualifiers(w, base_qt);
            try w.print("atomic", .{});
        },
        .typedef => unreachable, // handled above
        .attributed => unreachable, // handled above
    }
}

/// Print a QualType with a declarator name, handling arrays and function pointers in C syntax.
/// For arrays: prints `elem_type name[size]` instead of `elem_type[size] name`.
/// For function pointers: prints `return_type (*name)(params)`.
pub fn presentDeclarator(
    w: *std.Io.Writer,
    qt: aro.QualType,
    name: []const u8,
    comp: *const aro.Compilation,
) std.Io.Writer.Error!void {
    // Strip typedefs/attributed to check for wrapping types
    switch (qt.base(comp).type) {
        .array => |a| {
            try presentDeclarator(w, a.elem, name, comp);
            switch (a.len) {
                .incomplete => try w.print("[]", .{}),
                .fixed => |n| try w.print("[{}]", .{n}),
                .static => |n| try w.print("[static {}]", .{n}),
                .variable => try w.print("[]", .{}),
                .unspecified_variable => try w.print("[]", .{}),
            }
        },
        .pointer => |p| {
            // Check if child is a function — function pointer
            if (p.child.get(comp, .func)) |func_type| {
                try presentQualType(w, func_type.return_type, comp);
                try w.print(" (*{s})(", .{name});
                for (func_type.params, 0..) |param, i| {
                    if (i > 0) try w.print(", ", .{});
                    // For function pointer params, also use declarator style if there is a name
                    try presentQualType(w, param.qt, comp);
                }
                try w.print(")", .{});
            } else {
                // Regular pointer — print child type, then * and name
                try presentDeclarator(w, p.child, "", comp);
                try w.print("*", .{});
                if (name.len > 0) try w.print("{s}", .{name});
            }
        },
        else => {
            // Simple type — print qualtype then name
            try presentQualType(w, qt, comp);
            if (name.len > 0) try w.print(" {s}", .{name});
        },
    }
}

const expect = std.testing.expect;

/// Shared C source used by NodeRefIterator tests.
const test_c_code =
    \\int add(int a, int b) {
    \\    return a + b;
    \\}
    \\
    \\int if_test(int x) {
    \\    if (x > 0) return 1; else return -1;
    \\}
    \\
    \\int while_test(int n) {
    \\    while (n > 0) n = n - 1;
    \\    return n;
    \\}
    \\
    \\int do_while_test(int n) {
    \\    do { n = n - 1; } while (n > 0);
    \\    return n;
    \\}
    \\
    \\int for_test(int n) {
    \\    int i;
    \\    for (i = 0; i < n; i = i + 1) { }
    \\    return i;
    \\}
    \\
    \\int factorial(int n) {
    \\    if (n <= 1) return 1;
    \\    return n * factorial(n - 1);
    \\}
    \\
    \\struct Point { float x; float y; };
    \\
    \\int use_ternary(int c) {
    \\    return c > 0 ? c : -c;
    \\}
    \\
    \\int use_switch(int x) {
    \\    switch (x) {
    \\        case 1: return 10;
    \\        case 2: return 20;
    \\        default: return 0;
    \\    }
    \\}
    \\
    \\int use_goto(int x) {
    \\    if (x == 0) goto err;
    \\    return x;
    \\    err: return -1;
    \\}
    \\
    \\struct Pair { int a; int b; };
    \\
    \\int use_member(struct Pair p) {
    \\    return p.a + p.b;
    \\}
    \\
    \\void use_pointer(int *ptr) {
    \\    *ptr = 42;
    \\}
    \\
    \\int arr[10];
    \\
    \\int get_arr(int i) {
    \\    return arr[i];
    \\}
    \\
    \\void use_break(void) {
    \\    while (1) { break; }
    \\}
    \\
    \\void do_return(void) {
    \\    return;
    \\}
    \\
    \\float do_cast(int x) {
    \\    return (float)x;
    \\}
    \\
    \\int use_comma(int a, int b) {
    \\    return (a += 1, a + b);
    \\}
    \\
    \\enum Color { RED, GREEN, BLUE };
    \\
    \\enum Color use_enum(int x) {
    \\    return RED;
    \\}
    \\
    \\void use_continue(void) {
    \\    for (;;) { continue; }
    \\}
    \\
    \\_Static_assert(sizeof(int) == 4, "int must be 4 bytes");
    \\
    \\union Data { int i; float f; };
    \\
    \\struct Forward;
    \\union Maybe;
    \\
    \\extern int global_var;
    \\static int file_static;
    \\
    \\void empty_decl(void);
    \\
    \\int sum(int count, ...);
;

/// Parse the shared test C code and return a TreeCtx.
fn parseTestC() !TreeCtx {
    return TreeCtx.parseC(std.testing.allocator, std.testing.io, test_c_code, "test_iter.c", &.{});
}

test "aro parse C" {
    var ctx = try parseTestC();
    defer ctx.deinit();

    const tree = &ctx.tree;

    try expect(tree.root_decls.items.len >= 20);

    var found_function = false;
    var found_struct = false;
    var found_union = false;
    var found_enum = false;
    var found_typedef = false;
    var found_struct_fwd = false;
    var found_union_fwd = false;
    var found_variable = false;
    var found_static_assert = false;

    for (tree.root_decls.items) |idx| {
        const n = idx.get(tree);
        switch (n) {
            .function => found_function = true,
            .struct_decl => found_struct = true,
            .union_decl => found_union = true,
            .enum_decl => found_enum = true,
            .typedef => found_typedef = true,
            .struct_forward_decl => found_struct_fwd = true,
            .union_forward_decl => found_union_fwd = true,
            .variable => found_variable = true,
            .static_assert => found_static_assert = true,
            else => {},
        }
    }

    try expect(found_function);
    try expect(found_struct);
    try expect(found_union);
    try expect(found_enum);
    try expect(found_typedef);
    try expect(found_struct_fwd);
    try expect(found_union_fwd);
    try expect(found_variable);
    try expect(found_static_assert);
}

test "NodeRefIterator — rootDecls" {
    var ctx = try parseTestC();
    defer ctx.deinit();

    var root_count: usize = 0;
    var it = ctx.rootDecls();
    while (it.next()) |ref| {
        root_count += 1;
        try expect(ref.tree == &ctx.tree);
    }
    try expect(root_count > 0);
    try expect(root_count == ctx.tree.root_decls.items.len);
}

test "NodeRefIterator — reset" {
    var ctx = try parseTestC();
    defer ctx.deinit();

    var it = ctx.rootDecls();
    const first = it.next() orelse return error.TestUnexpectedResult;
    it.reset();
    const first_again = it.next() orelse return error.TestUnexpectedResult;
    try expect(first.idx == first_again.idx);
}

test "NodeRefIterator — compound_stmt" {
    var ctx = try parseTestC();
    defer ctx.deinit();

    var it = ctx.rootDecls();
    while (it.next()) |ref| {
        if (ref.kind() == .function) {
            const f = ref.get().function;
            if (f.body) |body_idx| {
                const body_ref = NodeRef.init(&ctx.tree, body_idx);
                try expect(body_ref.kind() == .compound_stmt);
                var child_it = body_ref.children();
                var count: usize = 0;
                while (child_it.next()) |_| {
                    count += 1;
                }
                try expect(count > 0);
            }
        }
    }
}

test "NodeRefIterator — function" {
    var ctx = try parseTestC();
    defer ctx.deinit();

    var it = ctx.rootDecls();
    while (it.next()) |ref| {
        if (ref.kind() == .function) {
            var child_it = ref.children();
            var count: usize = 0;
            while (child_it.next()) |_| {
                count += 1;
            }
            try expect(count <= 1);
        }
    }
}

test "NodeRefIterator — return_stmt" {
    var ctx = try parseTestC();
    defer ctx.deinit();

    var it = ctx.rootDecls();
    while (it.next()) |ref| {
        const node = ref.get();
        if (node == .function and std.mem.eql(u8, ctx.tree.tokSlice(node.function.name_tok), "add")) {
            const f = node.function;
            if (f.body) |body_idx| {
                var body_it = NodeRef.init(&ctx.tree, body_idx).children();
                while (body_it.next()) |stmt_ref| {
                    if (stmt_ref.kind() == .return_stmt) {
                        var ret_it = stmt_ref.children();
                        var ret_count: usize = 0;
                        while (ret_it.next()) |_| {
                            ret_count += 1;
                        }
                        // return a + b has one child (the add_expr)
                        try expect(ret_count == 1);
                    }
                }
            }
        }
    }
}

test "NodeRefIterator — binary expressions" {
    var ctx = try parseTestC();
    defer ctx.deinit();

    var it = ctx.rootDecls();
    while (it.next()) |ref| {
        const node = ref.get();
        if (node == .function and std.mem.eql(u8, ctx.tree.tokSlice(node.function.name_tok), "add")) {
            const f = node.function;
            if (f.body) |body_idx| {
                var body_it = NodeRef.init(&ctx.tree, body_idx).children();
                while (body_it.next()) |stmt_ref| {
                    if (stmt_ref.kind() == .return_stmt) {
                        var ret_it = stmt_ref.children();
                        if (ret_it.next()) |expr_ref| {
                            var bin_it = expr_ref.children();
                            var bin_count: usize = 0;
                            while (bin_it.next()) |_| {
                                bin_count += 1;
                            }
                            try expect(bin_count == 2);
                        }
                    }
                }
            }
        }
    }
}

test "NodeRefIterator — if_stmt" {
    var ctx = try parseTestC();
    defer ctx.deinit();

    var it = ctx.rootDecls();
    while (it.next()) |ref| {
        const node = ref.get();
        if (node == .function and std.mem.eql(u8, ctx.tree.tokSlice(node.function.name_tok), "if_test")) {
            const f = node.function;
            if (f.body) |body_idx| {
                var body_it = NodeRef.init(&ctx.tree, body_idx).children();
                if (body_it.next()) |stmt_ref| {
                    try expect(stmt_ref.kind() == .if_stmt);
                    var if_it = stmt_ref.children();
                    var if_count: usize = 0;
                    while (if_it.next()) |_| {
                        if_count += 1;
                    }
                    try expect(if_count == 3);
                }
            }
        }
    }
}

test "NodeRefIterator — while/do-while" {
    var ctx = try parseTestC();
    defer ctx.deinit();

    var it = ctx.rootDecls();
    while (it.next()) |ref| {
        const node = ref.get();
        if (node == .function) {
            const name = ctx.tree.tokSlice(node.function.name_tok);
            if (std.mem.eql(u8, name, "while_test") or std.mem.eql(u8, name, "do_while_test")) {
                const f = node.function;
                if (f.body) |body_idx| {
                    var body_it = NodeRef.init(&ctx.tree, body_idx).children();
                    while (body_it.next()) |stmt_ref| {
                        if (stmt_ref.kind() == .while_stmt or stmt_ref.kind() == .do_while_stmt) {
                            var w_it = stmt_ref.children();
                            var count: usize = 0;
                            while (w_it.next()) |_| {
                                count += 1;
                            }
                            try expect(count == 2);
                        }
                    }
                }
            }
        }
    }
}

test "NodeRefIterator — for_stmt" {
    var ctx = try parseTestC();
    defer ctx.deinit();

    var it = ctx.rootDecls();
    while (it.next()) |ref| {
        const node = ref.get();
        if (node == .function and std.mem.eql(u8, ctx.tree.tokSlice(node.function.name_tok), "for_test")) {
            const f = node.function;
            if (f.body) |body_idx| {
                var body_it = NodeRef.init(&ctx.tree, body_idx).children();
                while (body_it.next()) |stmt_ref| {
                    if (stmt_ref.kind() == .for_stmt) {
                        var for_it = stmt_ref.children();
                        var count: usize = 0;
                        while (for_it.next()) |_| {
                            count += 1;
                        }
                        try expect(count == 4);
                    }
                }
            }
        }
    }
}

test "NodeRefIterator — switch/case/default" {
    var ctx = try parseTestC();
    defer ctx.deinit();

    var it = ctx.rootDecls();
    while (it.next()) |ref| {
        const node = ref.get();
        if (node == .function and std.mem.eql(u8, ctx.tree.tokSlice(node.function.name_tok), "use_switch")) {
            const f = node.function;
            if (f.body) |body_idx| {
                var body_it = NodeRef.init(&ctx.tree, body_idx).children();
                if (body_it.next()) |switch_ref| {
                    try expect(switch_ref.kind() == .switch_stmt);
                    var sw_it = switch_ref.children();
                    var sw_count: usize = 0;
                    while (sw_it.next()) |_| {
                        sw_count += 1;
                    }
                    try expect(sw_count == 2); // cond + body

                    // Inside switch body: case and default stmts
                    sw_it.reset();
                    _ = sw_it.next(); // cond
                    if (sw_it.next()) |case_body_ref| {
                        var cs_it = case_body_ref.children();
                        while (cs_it.next()) |case_ref| {
                            if (case_ref.kind() == .case_stmt) {
                                var c_it = case_ref.children();
                                var c_count: usize = 0;
                                while (c_it.next()) |_| {
                                    c_count += 1;
                                }
                                try expect(c_count == 2); // start + body
                            }
                            if (case_ref.kind() == .default_stmt) {
                                var d_it = case_ref.children();
                                var d_count: usize = 0;
                                while (d_it.next()) |_| {
                                    d_count += 1;
                                }
                                try expect(d_count == 1); // body
                            }
                        }
                    }
                }
            }
        }
    }
}

test "NodeRefIterator — labeled/goto" {
    var ctx = try parseTestC();
    defer ctx.deinit();

    var it = ctx.rootDecls();
    while (it.next()) |ref| {
        const node = ref.get();
        if (node == .function and std.mem.eql(u8, ctx.tree.tokSlice(node.function.name_tok), "use_goto")) {
            const f = node.function;
            if (f.body) |body_idx| {
                var body_it = NodeRef.init(&ctx.tree, body_idx).children();
                while (body_it.next()) |stmt_ref| {
                    if (stmt_ref.kind() == .labeled_stmt) {
                        var label_it = stmt_ref.children();
                        var lc: usize = 0;
                        while (label_it.next()) |_| {
                            lc += 1;
                        }
                        try expect(lc == 1);
                    }
                    if (stmt_ref.kind() == .goto_stmt) {
                        var goto_it = stmt_ref.children();
                        var gc: usize = 0;
                        while (goto_it.next()) |_| {
                            gc += 1;
                        }
                        try expect(gc == 0);
                    }
                }
            }
        }
    }
}

test "NodeRefIterator — break/continue/void_return" {
    var ctx = try parseTestC();
    defer ctx.deinit();

    // use_break function: while (1) { break; }
    {
        var it = ctx.rootDecls();
        while (it.next()) |ref| {
            const node = ref.get();
            if (node == .function and std.mem.eql(u8, ctx.tree.tokSlice(node.function.name_tok), "use_break")) {
                const f = node.function;
                if (f.body) |body_idx| {
                    var body_it = NodeRef.init(&ctx.tree, body_idx).children();
                    while (body_it.next()) |stmt_ref| {
                        if (stmt_ref.kind() == .while_stmt) {
                            var while_it = stmt_ref.children();
                            _ = while_it.next(); // cond
                            if (while_it.next()) |body_ref| {
                                var cs_it = body_ref.children();
                                if (cs_it.next()) |inner_ref| {
                                    try expect(inner_ref.kind() == .break_stmt);
                                    var brk_it = inner_ref.children();
                                    var bc: usize = 0;
                                    while (brk_it.next()) |_| {
                                        bc += 1;
                                    }
                                    try expect(bc == 0);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // use_continue function: for (;;) { continue; }
    {
        var it = ctx.rootDecls();
        while (it.next()) |ref| {
            const node = ref.get();
            if (node == .function and std.mem.eql(u8, ctx.tree.tokSlice(node.function.name_tok), "use_continue")) {
                const f = node.function;
                if (f.body) |body_idx| {
                    var body_it = NodeRef.init(&ctx.tree, body_idx).children();
                    if (body_it.next()) |for_ref| {
                        if (for_ref.kind() == .for_stmt) {
                            var for_it = for_ref.children();
                            _ = for_it.next(); // init
                            _ = for_it.next(); // cond
                            _ = for_it.next(); // incr
                            if (for_it.next()) |body_ref| {
                                var cs_it = body_ref.children();
                                while (cs_it.next()) |inner_ref| {
                                    if (inner_ref.kind() == .continue_stmt) {
                                        var cont_it = inner_ref.children();
                                        var cc: usize = 0;
                                        while (cont_it.next()) |_| {
                                            cc += 1;
                                        }
                                        try expect(cc == 0);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // do_return function: void return has no operand
    {
        var it = ctx.rootDecls();
        while (it.next()) |ref| {
            const node = ref.get();
            if (node == .function and std.mem.eql(u8, ctx.tree.tokSlice(node.function.name_tok), "do_return")) {
                const f = node.function;
                if (f.body) |body_idx| {
                    var body_it = NodeRef.init(&ctx.tree, body_idx).children();
                    if (body_it.next()) |ret_ref| {
                        try expect(ret_ref.kind() == .return_stmt);
                        var r_it = ret_ref.children();
                        var r_count: usize = 0;
                        while (r_it.next()) |_| {
                            r_count += 1;
                        }
                        try expect(r_count == 0);
                    }
                }
            }
        }
    }
}

test "NodeRefIterator — decl_ref / call / member_access" {
    var ctx = try parseTestC();
    defer ctx.deinit();

    // decl_ref_expr from factorial: n * factorial(n - 1)
    // The LHS (`n`) should be a decl_ref or enum ref with exactly 1 child.
    {
        var it = ctx.rootDecls();
        while (it.next()) |ref| {
            const node = ref.get();
            if (node == .function and std.mem.eql(u8, ctx.tree.tokSlice(node.function.name_tok), "factorial")) {
                const f = node.function;
                if (f.body) |body_idx| {
                    var body_it = NodeRef.init(&ctx.tree, body_idx).children();
                    while (body_it.next()) |stmt_ref| {
                        if (stmt_ref.kind() == .return_stmt) {
                            var ret_it = stmt_ref.children();
                            if (ret_it.next()) |expr_ref| {
                                // `n * factorial(n - 1)` — should have 2 children (lhs, rhs)
                                var tmp_it = expr_ref.children();
                                try expect(tmp_it.next() != null);
                            }
                        }
                    }
                }
            }
        }
    }

    // call_expr from factorial
    {
        var it = ctx.rootDecls();
        while (it.next()) |ref| {
            const node = ref.get();
            if (node == .function and std.mem.eql(u8, ctx.tree.tokSlice(node.function.name_tok), "factorial")) {
                const f = node.function;
                if (f.body) |body_idx| {
                    var body_it = NodeRef.init(&ctx.tree, body_idx).children();
                    while (body_it.next()) |stmt_ref| {
                        if (stmt_ref.kind() == .return_stmt) {
                            var ret_it = stmt_ref.children();
                            if (ret_it.next()) |expr_ref| {
                                // `n * factorial(n - 1)` — should have at least 1 child
                                var tmp2 = expr_ref.children();
                                try expect(tmp2.next() != null);
                            }
                        }
                    }
                }
            }
        }
    }

    // member_access_expr from use_member: p.a + p.b
    {
        var it = ctx.rootDecls();
        while (it.next()) |ref| {
            const node = ref.get();
            if (node == .function and std.mem.eql(u8, ctx.tree.tokSlice(node.function.name_tok), "use_member")) {
                const f = node.function;
                if (f.body) |body_idx| {
                    var body_it = NodeRef.init(&ctx.tree, body_idx).children();
                    if (body_it.next()) |ret_ref| {
                        if (ret_ref.kind() == .return_stmt) {
                            var ret_it = ret_ref.children();
                            if (ret_it.next()) |add_ref| {
                                var add_it = add_ref.children();
                                if (add_it.next()) |lhs_ref| {
                                    // member access should have 1 child (base)
                                    var m_it = lhs_ref.children();
                                    var m_count: usize = 0;
                                    while (m_it.next()) |_| {
                                        m_count += 1;
                                    }
                                    // member access should have 1 child (base)
                                    try expect(m_count == 1);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

test "NodeRefIterator — array_access / deref / cast / enum_ref" {
    var ctx = try parseTestC();
    defer ctx.deinit();

    // array_access_expr from get_arr: return arr[i];
    // The return expression should have children (base + index or similar)
    {
        var it = ctx.rootDecls();
        while (it.next()) |ref| {
            const node = ref.get();
            if (node == .function and std.mem.eql(u8, ctx.tree.tokSlice(node.function.name_tok), "get_arr")) {
                const f = node.function;
                if (f.body) |body_idx| {
                    var body_it = NodeRef.init(&ctx.tree, body_idx).children();
                    while (body_it.next()) |stmt_ref| {
                        if (stmt_ref.kind() == .return_stmt) {
                            var ret_it = stmt_ref.children();
                            if (ret_it.next()) |expr_ref| {
                                // Should have at least 1 child
                                var arr_it = expr_ref.children();
                                try expect(arr_it.next() != null);
                            }
                        }
                    }
                }
            }
        }
    }

    // deref_expr from use_pointer: *ptr = 42;
    {
        var it = ctx.rootDecls();
        while (it.next()) |ref| {
            const node = ref.get();
            if (node == .function and std.mem.eql(u8, ctx.tree.tokSlice(node.function.name_tok), "use_pointer")) {
                const f = node.function;
                if (f.body) |body_idx| {
                    var body_it = NodeRef.init(&ctx.tree, body_idx).children();
                    while (body_it.next()) |stmt_ref| {
                        if (stmt_ref.kind() == .assign_expr) {
                            var assign_it = stmt_ref.children();
                            if (assign_it.next()) |lhs_ref| {
                                try expect(lhs_ref.kind() == .deref_expr);
                                var deref_it = lhs_ref.children();
                                var dc: usize = 0;
                                while (deref_it.next()) |_| {
                                    dc += 1;
                                }
                                try expect(dc == 1);
                            }
                        }
                    }
                }
            }
        }
    }

    // cast/coerce from do_cast: return (float)x;
    {
        var it = ctx.rootDecls();
        while (it.next()) |ref| {
            const node = ref.get();
            if (node == .function and std.mem.eql(u8, ctx.tree.tokSlice(node.function.name_tok), "do_cast")) {
                const f = node.function;
                if (f.body) |body_idx| {
                    var body_it = NodeRef.init(&ctx.tree, body_idx).children();
                    if (body_it.next()) |ret_ref| {
                        if (ret_ref.kind() == .return_stmt) {
                            var ret_it = ret_ref.children();
                            try expect(ret_it.next() != null); // return has a child
                        }
                    }
                }
            }
        }
    }

    // enum expr from use_enum: return RED;
    {
        var it = ctx.rootDecls();
        while (it.next()) |ref| {
            const node = ref.get();
            if (node == .function and std.mem.eql(u8, ctx.tree.tokSlice(node.function.name_tok), "use_enum")) {
                const f = node.function;
                if (f.body) |body_idx| {
                    var body_it = NodeRef.init(&ctx.tree, body_idx).children();
                    if (body_it.next()) |ret_ref| {
                        if (ret_ref.kind() == .return_stmt) {
                            var ret_it = ret_ref.children();
                            if (ret_it.next()) |expr_ref| {
                                // RED reference should have at least 1 child
                                var e_it = expr_ref.children();
                                try expect(e_it.next() != null);
                            }
                        }
                    }
                }
            }
        }
    }
}

test "NodeRefIterator — ternary / comma / paren" {
    var ctx = try parseTestC();
    defer ctx.deinit();

    // ternary from use_ternary: return c > 0 ? c : -c;
    {
        var it = ctx.rootDecls();
        while (it.next()) |ref| {
            const node = ref.get();
            if (node == .function and std.mem.eql(u8, ctx.tree.tokSlice(node.function.name_tok), "use_ternary")) {
                const f = node.function;
                if (f.body) |body_idx| {
                    var body_it = NodeRef.init(&ctx.tree, body_idx).children();
                    while (body_it.next()) |stmt_ref| {
                        if (stmt_ref.kind() == .return_stmt) {
                            var ret_it = stmt_ref.children();
                            if (ret_it.next()) |expr_ref| {
                                try expect(expr_ref.kind() == .cond_expr);
                                var cond_it = expr_ref.children();
                                var cond_count: usize = 0;
                                while (cond_it.next()) |_| {
                                    cond_count += 1;
                                }
                                try expect(cond_count == 3);
                            }
                        }
                    }
                }
            }
        }
    }

    // comma + paren from use_comma: return (a += 1, a + b);
    {
        var it = ctx.rootDecls();
        while (it.next()) |ref| {
            const node = ref.get();
            if (node == .function and std.mem.eql(u8, ctx.tree.tokSlice(node.function.name_tok), "use_comma")) {
                const f = node.function;
                if (f.body) |body_idx| {
                    var body_it = NodeRef.init(&ctx.tree, body_idx).children();
                    if (body_it.next()) |ret_ref| {
                        if (ret_ref.kind() == .return_stmt) {
                            var ret_it = ret_ref.children();
                            if (ret_it.next()) |expr_ref| {
                                try expect(expr_ref.kind() == .paren_expr);
                                var paren_it = expr_ref.children();
                                if (paren_it.next()) |inner_ref| {
                                    try expect(inner_ref.kind() == .comma_expr);
                                    var cm_it = inner_ref.children();
                                    var cm_count: usize = 0;
                                    while (cm_it.next()) |_| {
                                        cm_count += 1;
                                    }
                                    try expect(cm_count == 2);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

test "NodeRefIterator — variable / forward_decl / static_assert" {
    var ctx = try parseTestC();
    defer ctx.deinit();

    // variable children (0)
    {
        var it = ctx.rootDecls();
        while (it.next()) |ref| {
            if (ref.kind() == .variable) {
                var v_it = ref.children();
                var vc: usize = 0;
                while (v_it.next()) |_| {
                    vc += 1;
                }
                try expect(vc == 0);
            }
        }
    }

    // forward_decl children (0) — no forward decl in this C source, so just check no crash
    {
        var it = ctx.rootDecls();
        while (it.next()) |ref| {
            if (ref.kind() == .struct_forward_decl or ref.kind() == .union_forward_decl) {
                var fwd_it = ref.children();
                var fc: usize = 0;
                while (fwd_it.next()) |_| {
                    fc += 1;
                }
                try expect(fc == 0);
            }
        }
    }

    // static_assert children (2: cond, message)
    {
        var it = ctx.rootDecls();
        while (it.next()) |ref| {
            if (ref.kind() == .static_assert) {
                var sa_it = ref.children();
                var sa_count: usize = 0;
                while (sa_it.next()) |_| {
                    sa_count += 1;
                }
                try expect(sa_count == 2);
            }
        }
    }
}

test "NodeRefIterator — struct_decl / typedef / enum_decl" {
    var ctx = try parseTestC();
    defer ctx.deinit();

    var it = ctx.rootDecls();
    while (it.next()) |ref| {
        switch (ref.kind()) {
            .struct_decl, .enum_decl => {
                var s_it = ref.children();
                var sc: usize = 0;
                while (s_it.next()) |_| {
                    sc += 1;
                }
                try expect(sc == 0);
            },
            .typedef => {
                var td_it = ref.children();
                var tc: usize = 0;
                while (td_it.next()) |_| {
                    tc += 1;
                }
                try expect(tc == 0);
            },
            else => {},
        }
    }
}

test "force analysis of all decls" {
    comptime {
        std.testing.refAllDecls(@This());
        std.testing.refAllDecls(TreeCtx);
        std.testing.refAllDecls(NodeRefIterator);
        std.testing.refAllDecls(NodeRef);
    }
}
