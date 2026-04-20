const std = @import("std");
const lexing = @import("./lexing.zig");

const StringBuilder = @import("../common.zig").StringBuilder;
const String = []const u8;
const MutString = std.ArrayList(u8);

const Token = lexing.Token;
const TokenType = lexing.TokenType;
const LexedTokens = lexing.LexedTokens;

const ExpressionID = usize;

// --Types of clauses--
const ClauseType = enum {
    Select,
    From,
    Where,
    GroupBy,
    Having,
    Qualify,
    Limit,
};

const ParseError = error{
    GeneralError,
};

// -- Types of nodes --
// Use IDs to represent elements already defined.

// -- Expression types for representing compound operations --

pub const Expression = union(enum) {
    empty: void,
    literal: Literal,
    identifier: Identifier,
    uncategorized: Identifier,
    binary_op: BinaryOp,
    grouping: Grouping,
    function: Function,
    star: Star,
    join: Join,
    subquery: SubQuery,

    pub const JoinKind = enum { inner, left, right, full, cross };

    pub const Join = struct {
        kind: JoinKind,
        table: ExpressionID,
        on_condition: ExpressionID,
    };

    pub const Literal = struct {
        token_type: TokenType,
        string_index: usize,
    };

    pub const Identifier = struct {
        string_index: usize,
    };

    pub const BinaryOp = struct {
        left: ExpressionID,
        op: Operator,
        right: ExpressionID,
    };

    pub const Grouping = struct {
        inner: ExpressionID,
    };

    pub const Function = struct { function_name_index: usize, arguments: std.ArrayList(ExpressionID) };

    pub const Star = struct {};

    pub const SubQuery = struct {
        select: std.ArrayListUnmanaged(ExpressionID),
        from: ExpressionID,
        joins: std.ArrayListUnmanaged(ExpressionID),
        where: ExpressionID,
        group_by: std.ArrayListUnmanaged(ExpressionID),
        having: ExpressionID,
        qualify: ExpressionID,
        limit: ExpressionID,
    };

    pub const Operator = enum {
        add,
        subtract,
        multiply,
        divide,
        logical_and,
        logical_or,
        equal,
        not_equal,
        less_than,
        greater_than,

        pub fn fromTokenType(token_type: TokenType) ?Operator {
            return switch (token_type) {
                .Plus => .add,
                .Minus => .subtract,
                .Star => .multiply,
                .Slash => .divide,
                .And => .logical_and,
                .Or => .logical_or,
                .Equal => .equal,
                .NotEqual => .not_equal,
                .LessThan => .less_than,
                .GreaterThan => .greater_than,
                else => null,
            };
        }

        pub fn precedence(self: Operator) u8 {
            return switch (self) {
                .logical_or => 1,
                .logical_and => 2,
                .equal, .not_equal, .less_than, .greater_than => 3,
                .add, .subtract => 4,
                .multiply, .divide => 5,
            };
        }

        pub fn toStr(self: Operator) []const u8 {
            return switch (self) {
                .add => "+",
                .subtract => "-",
                .multiply => "*",
                .divide => "/",
                .logical_and => "and",
                .logical_or => "or",
                .less_than => "<",
                .greater_than => ">",
                .equal => "=",
                .not_equal => "<>",
            };
        }
    };
};

const NullExpression = Expression{ .empty = undefined };

// -- Valid Elements per clause --

// TODO: These can also have aliases
const SelectElement = struct {
    expression: ExpressionID,
};

// -- Parse summaries --

const CteDefinition = struct {
    name_index: usize,
    body: ExpressionID, // points to a .subquery expression
};

const MinimalParsedQuery = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    ctes: std.ArrayList(CteDefinition),
    select_expressions: std.ArrayList(ExpressionID),
    from_expression: ExpressionID,
    join_expressions: std.ArrayList(ExpressionID),
    where_expression: ExpressionID,
    group_by_expressions: std.ArrayList(ExpressionID),
    having_expression: ExpressionID,
    qualify_expression: ExpressionID,
    limit_expression: ExpressionID,

    expressions: []Expression,
    string_buffer: []MutString,
    contains_aggregate: bool,

    pub fn deinit(self: *Self) void {
        self.ctes.deinit(self.allocator);
        self.select_expressions.deinit(self.allocator);
        self.join_expressions.deinit(self.allocator);
        self.group_by_expressions.deinit(self.allocator);
        self.expressions = undefined;
        self.string_buffer = undefined;
    }

    fn renderExpression(self: *const Self, expression_id: ExpressionID, builder: *StringBuilder) void {
        switch (self.expressions[expression_id]) {
            .literal => |lit| {
                const string = self.string_buffer[lit.string_index];
                builder.append(string.items);
            },
            .identifier, .uncategorized => |ident| {
                const string = self.string_buffer[ident.string_index];
                builder.append(string.items);
            },
            .binary_op => |bin| {
                self.renderExpression(bin.left, builder);
                builder.push(' ');
                builder.append(bin.op.toStr());
                builder.push(' ');
                self.renderExpression(bin.right, builder);
            },
            .grouping => |grp| {
                builder.push('(');
                self.renderExpression(grp.inner, builder);
                builder.push(')');
            },
            .function => |func| {
                const string = self.string_buffer[func.function_name_index];
                builder.append(string.items);

                if (func.arguments.items.len > 0) {
                    builder.push('(');
                    self.renderExpressionList(func.arguments.items[0..], builder);
                    builder.push(')');
                }
            },
            .star => {
                builder.push('*');
            },
            .join => |join| {
                const kind_str: []const u8 = switch (join.kind) {
                    .inner => "join",
                    .left => "left join",
                    .right => "right join",
                    .full => "full outer join",
                    .cross => "cross join",
                };
                builder.append(kind_str);
                builder.push(' ');
                self.renderExpression(join.table, builder);
                if (join.on_condition > 0) {
                    builder.append(" on ");
                    self.renderExpression(join.on_condition, builder);
                }
            },
            .subquery => |subquery| {
                builder.push('(');
                builder.append("select ");
                if (subquery.select.items.len > 0) {
                    self.renderExpressionList(subquery.select.items, builder);
                } else {
                    builder.append("*");
                }
                if (subquery.from > 0) {
                    builder.append(" from ");
                    self.renderExpression(subquery.from, builder);
                }
                for (subquery.joins.items) |join_id| {
                    builder.push(' ');
                    self.renderExpression(join_id, builder);
                }
                if (subquery.where > 0) {
                    builder.append(" where ");
                    self.renderExpression(subquery.where, builder);
                }
                if (subquery.group_by.items.len > 0) {
                    builder.append(" group by ");
                    self.renderExpressionList(subquery.group_by.items, builder);
                }
                if (subquery.having > 0) {
                    builder.append(" having ");
                    self.renderExpression(subquery.having, builder);
                }
                if (subquery.qualify > 0) {
                    builder.append(" qualify ");
                    self.renderExpression(subquery.qualify, builder);
                }
                builder.push(')');
            },
            .empty => {},
        }
    }

    pub fn renderExpressionList(self: *const Self, expressions: []ExpressionID, builder: *StringBuilder) void {
        var is_first_element = true;
        for (expressions) |expression_id| {
            if (expression_id == 0) {
                continue;
            }

            if (!is_first_element) {
                builder.push(',');
                builder.push(' ');
            }

            self.renderExpression(expression_id, builder);

            is_first_element = false;
        }
    }

    pub fn render(self: *const Self, allocator: std.mem.Allocator) !MutString {
        var builder = StringBuilder.init(allocator);
        defer builder.deinit();

        if (self.ctes.items.len > 0) {
            builder.append("with ");
            for (self.ctes.items, 0..) |cte, cte_index| {
                if (cte_index > 0) builder.append(", ");
                builder.append(self.string_buffer[cte.name_index].items);
                builder.append(" as ");
                self.renderExpression(cte.body, &builder);
            }
            builder.push(' ');
        }

        builder.append("select ");
        if (self.select_expressions.items.len > 0) {
            self.renderExpressionList(self.select_expressions.items[0..], &builder);
        } else {
            builder.append("*");
        }

        if (self.from_expression > 0) {
            builder.append(" from ");
            self.renderExpression(self.from_expression, &builder);
        }

        for (self.join_expressions.items) |join_id| {
            builder.push(' ');
            self.renderExpression(join_id, &builder);
        }

        if (self.where_expression > 0) {
            builder.append(" where ");
            self.renderExpression(self.where_expression, &builder);
        }

        if (self.group_by_expressions.items.len > 0) {
            builder.append(" group by ");
            self.renderExpressionList(self.group_by_expressions.items[0..], &builder);
        }

        if (self.having_expression > 0) {
            builder.append(" having ");
            self.renderExpression(self.having_expression, &builder);
        }

        if (self.qualify_expression > 0) {
            builder.append(" qualify ");
            self.renderExpression(self.qualify_expression, &builder);
        }

        return builder.toOwnedMutString();
    }
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexed_tokens: LexedTokens,
    string_buffer: std.ArrayList(MutString),
    position: usize = 0,
    // Arena for allocating expression nodes - they live for the lifetime of the parse result
    expressions: std.ArrayList(Expression),

    pub fn init(allocator: std.mem.Allocator, lexed_tokens: LexedTokens) !Parser {
        const string_buffer = try lexed_tokens.string_buffer.clone(allocator);
        var expressions = try std.ArrayList(Expression).initCapacity(allocator, 1024);
        try expressions.append(allocator, NullExpression);

        return Parser{
            .allocator = allocator,
            .lexed_tokens = lexed_tokens,
            .string_buffer = string_buffer,
            .position = 0,
            .expressions = expressions,
        };
    }

    pub fn deinit(self: *Parser) void {
        // Free owned data inside expression nodes
        for (self.expressions.items) |*expr| {
            switch (expr.*) {
                .subquery => |*subquery| {
                    subquery.select.deinit(self.allocator);
                    subquery.joins.deinit(self.allocator);
                    subquery.group_by.deinit(self.allocator);
                },
                .function => |*func| {
                    func.arguments.deinit(self.allocator);
                },
                else => {},
            }
        }
        // Free strings appended by the parser (dotted identifiers etc.) beyond the
        // original lexer buffer. The lexer owns and will free the originals.
        const original_count = self.lexed_tokens.string_buffer.items.len;
        for (self.string_buffer.items[original_count..]) |*str| {
            str.deinit(self.allocator);
        }
        self.string_buffer.deinit(self.allocator);
        self.lexed_tokens.deinit();
        self.expressions.deinit(self.allocator);
    }

    fn isAtEnd(self: *Parser) bool {
        return self.position >= self.lexed_tokens.tokens.items.len;
    }

    fn peek(self: *Parser) Token {
        if (self.isAtEnd()) {
            return Token{ .token_type = TokenType.None, .string_index = 0 };
        }
        return self.lexed_tokens.tokens.items[self.position];
    }

    fn peekNAhead(self: *Parser, lookahead: usize) Token {
        const new_position = self.position + lookahead;
        if (new_position >= self.lexed_tokens.tokens.items.len) {
            return Token{ .token_type = TokenType.None, .string_index = 0 };
        }
        return self.lexed_tokens.tokens.items[new_position];
    }

    fn advance(self: *Parser) void {
        self.position += 1;
    }

    fn consume(self: *Parser, token_type: TokenType) bool {
        const next_token = self.peek();
        if (next_token.token_type == token_type) {
            self.advance();
            return true;
        }
        return false;
    }

    fn isNewClause(token: Token) bool {
        return (token.token_type == TokenType.Select or
            token.token_type == TokenType.From or
            token.token_type == TokenType.Where or
            token.token_type == TokenType.GroupBy or
            token.token_type == TokenType.Having or
            token.token_type == TokenType.Qualify or
            token.token_type == TokenType.OrderBy or
            token.token_type == TokenType.Join or
            token.token_type == TokenType.InnerJoin or
            token.token_type == TokenType.LeftJoin or
            token.token_type == TokenType.RightJoin or
            token.token_type == TokenType.FullJoin or
            token.token_type == TokenType.CrossJoin);
    }

    // Check if current token marks the end of an expression
    fn isExpressionTerminator(token: Token) bool {
        return isNewClause(token) or
            token.token_type == TokenType.Comma or
            token.token_type == TokenType.None;
    }

    fn addExpression(self: *Parser, expr: Expression) !ExpressionID {
        try self.expressions.append(self.allocator, expr);
        return self.expressions.items.len - 1;
    }

    // Parse a primary expression (literals, identifiers)
    fn parsePrimary(self: *Parser) !ExpressionID {
        const token = self.peek();
        self.advance();

        switch (token.token_type) {
            .Numeric, .Boolean => {
                return try self.addExpression(.{
                    .literal = .{
                        .token_type = token.token_type,
                        .string_index = token.string_index,
                    },
                });
            },
            .String => {
                return try self.addExpression(.{
                    .literal = .{
                        .token_type = .String,
                        .string_index = token.string_index,
                    },
                });
            },
            .Identifier => {
                var string_index = token.string_index;
                // Handle dotted identifiers like a.x or schema.table.column
                while (self.peek().token_type == .Dot) {
                    self.advance(); // consume dot
                    const next = self.peek();
                    if (next.token_type != .Identifier) break;
                    self.advance(); // consume next identifier
                    const left_str = self.string_buffer.items[string_index];
                    const right_str = self.string_buffer.items[next.string_index];
                    var combined = try MutString.initCapacity(self.allocator, left_str.items.len + 1 + right_str.items.len);
                    try combined.appendSlice(self.allocator, left_str.items);
                    try combined.append(self.allocator, '.');
                    try combined.appendSlice(self.allocator, right_str.items);
                    string_index = self.string_buffer.items.len;
                    try self.string_buffer.append(self.allocator, combined);
                }
                return try self.addExpression(.{
                    .identifier = .{
                        .string_index = string_index,
                    },
                });
            },
            .AggregateFunction, .NonAggregateFunction, .WindowFunction => {
                var arguments: std.ArrayList(ExpressionID) = .empty;
                if (self.consume(.OpenParen)) {
                    arguments = try self.parseExpressionList(true);
                }

                return try self.addExpression(.{
                    .function = .{
                        .function_name_index = token.string_index,
                        .arguments = arguments,
                    },
                });
            },
            .OpenParen => {
                // Detect subquery: (SELECT ...) or (WITH ...)
                const next = self.peek();
                if (next.token_type == .Select or next.token_type == .With) {
                    const subquery = try self.parseQueryBody(self.allocator);
                    if (!self.consume(.CloseParen)) {
                        return 0;
                    }
                    return try self.addExpression(.{ .subquery = subquery });
                }

                const inner = try self.parseExpressionWithPrecedence(0);
                if (inner == 0) {
                    return 0; // empty parentheses
                }
                // Expect closing paren
                if (!self.consume(.CloseParen)) {
                    return 0; // TODO: error handling for missing ')'
                }

                return try self.addExpression(.{
                    .grouping = .{
                        .inner = inner,
                    },
                });
            },
            else => return 0,
        }
    }

    // Pratt parser: parse expression with given minimum precedence
    fn parseExpressionWithPrecedence(self: *Parser, min_precedence: u8) ParseError!ExpressionID {
        // Parse left-hand side (primary expression)
        var left = self.parsePrimary() catch {
            return ParseError.GeneralError;
        };

        // Keep parsing binary operators while they have sufficient precedence
        while (true) {
            const token = self.peek();

            // Check if this is an operator
            const op = Expression.Operator.fromTokenType(token.token_type) orelse break;

            // Check precedence
            const op_precedence = op.precedence();
            if (op_precedence < min_precedence) {
                break;
            }

            // Consume the operator
            self.advance();

            // Parse right-hand side with higher precedence (for left-associativity)
            const right = self.parseExpressionWithPrecedence(op_precedence + 1) catch {
                return ParseError.GeneralError;
            };
            if (right == 0) {
                return 0; // TODO: Not totally sure if this is correct. Is this for like "select 3 + , hello" ?
            }

            // Create binary operation node
            left = self.addExpression(.{
                .binary_op = .{
                    .left = left,
                    .op = op,
                    .right = right,
                },
            }) catch {
                return ParseError.GeneralError;
            };
        }

        return left;
    }

    // Public entry point for expression parsing
    fn parseExpression(self: *Parser) !ExpressionID {
        return self.parseExpressionWithPrecedence(0);
    }

    fn parseExpressionList(self: *Parser, break_on_paren: bool) !std.ArrayList(ExpressionID) {
        var elements: std.ArrayList(ExpressionID) = .empty;

        while (!self.isAtEnd()) {
            const next_token = self.peek();
            std.debug.print("Peek: {any}\n", .{next_token.token_type});

            if (isNewClause(next_token)) {
                std.debug.print("Breaking\n", .{});
                break;
            }

            // Skip commas between elements
            if (next_token.token_type == TokenType.Comma) {
                self.advance();
                continue;
            }

            if (next_token.token_type == TokenType.CloseParen) {
                if (break_on_paren) {
                    self.advance();
                }
                return elements;
            }

            // Kind of a hack, * is valid as a list element
            if (next_token.token_type == .Star) {
                self.advance();
                const expression_id = try self.addExpression(.{ .star = .{} });
                try elements.append(self.allocator, expression_id);

                continue;
            }

            // Try to parse an expression
            const expression_id = try self.parseExpression();
            if (expression_id > 0) {
                try elements.append(self.allocator, expression_id);
            } else {
                // Skip unknown tokens
                self.advance();
            }
        }

        return elements;
    }

    // Parse clauses until `)` or EOF, returning a SubQuery expression value.
    // The caller is responsible for consuming the closing `)`.
    fn parseQueryBody(self: *Parser, allocator: std.mem.Allocator) anyerror!Expression.SubQuery {
        var select: std.ArrayListUnmanaged(ExpressionID) = .empty;
        var from: ExpressionID = 0;
        var joins: std.ArrayListUnmanaged(ExpressionID) = .empty;
        var where: ExpressionID = 0;
        var group_by: std.ArrayListUnmanaged(ExpressionID) = .empty;
        var having: ExpressionID = 0;
        var qualify: ExpressionID = 0;
        var limit: ExpressionID = 0;

        while (!self.isAtEnd()) {
            // Stop at `)` so caller can consume it
            if (self.peek().token_type == .CloseParen) break;

            const next_token = self.peek();
            self.advance();

            switch (next_token.token_type) {
                .Select => {
                    var elems = try self.parseExpressionList(false);
                    try select.appendSlice(allocator, elems.items);
                    elems.deinit(allocator);
                },
                .From => {
                    from = self.parseExpression() catch 0;
                },
                .Where => {
                    where = self.parseExpression() catch 0;
                },
                .GroupBy => {
                    var elems = try self.parseExpressionList(false);
                    try group_by.appendSlice(allocator, elems.items);
                    elems.deinit(allocator);
                },
                .Having => {
                    having = self.parseExpression() catch 0;
                },
                .Qualify => {
                    qualify = self.parseExpression() catch 0;
                },
                .Join, .InnerJoin, .LeftJoin, .RightJoin, .FullJoin, .CrossJoin => {
                    const kind: Expression.JoinKind = switch (next_token.token_type) {
                        .LeftJoin => .left,
                        .RightJoin => .right,
                        .FullJoin => .full,
                        .CrossJoin => .cross,
                        else => .inner,
                    };
                    const table = self.parseExpression() catch 0;
                    const on_condition: ExpressionID = if (self.consume(.On))
                        self.parseExpression() catch 0
                    else
                        0;
                    const join_expr = try self.addExpression(.{
                        .join = .{ .kind = kind, .table = table, .on_condition = on_condition },
                    });
                    try joins.append(allocator, join_expr);
                },
                .Limit => {
                    if (self.peek().token_type == TokenType.Numeric) {
                        limit = self.parsePrimary() catch 0;
                    } else {
                        break;
                    }
                },
                else => {},
            }
        }

        return Expression.SubQuery{
            .select = select,
            .from = from,
            .joins = joins,
            .where = where,
            .group_by = group_by,
            .having = having,
            .qualify = qualify,
            .limit = limit,
        };
    }

    pub fn parse(self: *Parser, allocator: std.mem.Allocator) !MinimalParsedQuery {
        var current_clause: ClauseType = ClauseType.Select;

        var ctes: std.ArrayList(CteDefinition) = .empty;
        var select_expressions: std.ArrayList(ExpressionID) = .empty;
        var from_expression: ExpressionID = 0;
        var join_expressions: std.ArrayList(ExpressionID) = .empty;
        var where_expression: ExpressionID = 0;
        var group_by_expressions: std.ArrayList(ExpressionID) = .empty;
        var having_expression: ExpressionID = 0;
        var qualify_expression: ExpressionID = 0;
        var limit_expression: ExpressionID = 0; // TODO: Just make this an integer maybe

        while (!self.isAtEnd()) {
            const next_token = self.peek();
            self.advance();

            switch (next_token.token_type) {
                .With => {
                    var is_more_to_parse = true;
                    while (is_more_to_parse) {
                        is_more_to_parse = false;

                        const name_token = self.peek();
                        if (name_token.token_type != .Identifier) break;
                        self.advance();
                        if (!(self.consume(.As) or self.consume(.ColonEqual))) break;
                        if (!self.consume(.OpenParen)) break;
                        const body = try self.parseQueryBody(allocator);

                        std.debug.print("Expecting close paren: {any}\n", .{self.peek().token_type});

                        if (!self.consume(.CloseParen)) break;
                        const body_id = try self.addExpression(.{ .subquery = body });
                        try ctes.append(allocator, CteDefinition{
                            .name_index = name_token.string_index,
                            .body = body_id,
                        });

                        if (self.consume(.Comma)) {
                            is_more_to_parse = true;
                            continue;
                        }

                        if (self.peek().token_type == .Identifier and self.peekNAhead(1).token_type == .ColonEqual) {
                            is_more_to_parse = true;
                            continue;
                        }
                    }
                },
                .Select => {
                    var new_select_elements = try self.parseExpressionList(false);
                    try select_expressions.appendSlice(allocator, new_select_elements.items);
                    new_select_elements.deinit(allocator);
                },
                .From => {
                    current_clause = ClauseType.From;
                    from_expression = self.parseExpression() catch 0;
                },
                .Where => {
                    current_clause = ClauseType.Where;
                    where_expression = self.parseExpression() catch 0;
                },
                .GroupBy => {
                    current_clause = ClauseType.GroupBy;
                    var new_group_elements = try self.parseExpressionList(false);
                    try group_by_expressions.appendSlice(allocator, new_group_elements.items);
                    new_group_elements.deinit(allocator);
                },
                .Having => {
                    current_clause = ClauseType.Having;
                    having_expression = self.parseExpression() catch 0;
                },
                .Qualify => {
                    current_clause = ClauseType.Qualify;
                    qualify_expression = self.parseExpression() catch 0;
                },
                .Join, .InnerJoin, .LeftJoin, .RightJoin, .FullJoin, .CrossJoin => {
                    const kind: Expression.JoinKind = switch (next_token.token_type) {
                        .LeftJoin => .left,
                        .RightJoin => .right,
                        .FullJoin => .full,
                        .CrossJoin => .cross,
                        else => .inner,
                    };
                    const table = self.parseExpression() catch 0;
                    const on_condition: ExpressionID = if (self.consume(.On))
                        self.parseExpression() catch 0
                    else
                        0;
                    const join_expr = try self.addExpression(.{
                        .join = .{
                            .kind = kind,
                            .table = table,
                            .on_condition = on_condition,
                        },
                    });
                    try join_expressions.append(allocator, join_expr);
                },
                .Limit => {
                    current_clause = ClauseType.Limit;
                    const maybe_limit = self.peek();
                    if (maybe_limit.token_type == TokenType.Numeric) {
                        limit_expression = self.parsePrimary() catch 0;
                    } else {
                        break;
                    }
                },
                else => {},
            }
        }

        return MinimalParsedQuery{
            .allocator = allocator,

            .ctes = ctes,
            .select_expressions = select_expressions,
            .from_expression = from_expression,
            .join_expressions = join_expressions,
            .where_expression = where_expression,
            .group_by_expressions = group_by_expressions,
            .having_expression = having_expression,
            .qualify_expression = qualify_expression,
            .limit_expression = limit_expression,

            .string_buffer = self.string_buffer.items,
            .expressions = self.expressions.items,
            .contains_aggregate = false,
        };
    }
};

fn innerTestHarness(input: String, expected: String) !bool {
    const allocator = std.testing.allocator;

    // Weird, so I don't want to deinit the lexed tokens because I pass ownership of them to the parser.
    const lexed_result = try lexing.lex(allocator, input);
    var lex_string_builder = StringBuilder.init(allocator);
    defer lex_string_builder.deinit();

    // TODO: Fix up this allocation pattern
    var parser = try Parser.init(allocator, lexed_result);
    defer parser.deinit();
    var parsed_result = try parser.parse(allocator);
    defer parsed_result.deinit();

    var output = try parsed_result.render(allocator);
    defer output.deinit(allocator);

    const did_pass = std.mem.eql(u8, expected, output.items);

    if (!did_pass) {
        std.debug.print("\n---FAIL---\n", .{});
        std.debug.print("Input: '{s}'\n", .{input});
        std.debug.print("Lexed: '{s}'\n", .{lexing.buildLexString(lexed_result, &lex_string_builder)});
        std.debug.print("Expected: '{s}'\n", .{expected});
        std.debug.print("Got:      '{s}'\n", .{output.items});
    }

    return did_pass;
}

fn testHarness(input: String, expected: String) bool {
    const result = innerTestHarness(input, expected) catch |err| {
        std.debug.print("Error occurred: {}\n", .{err});
        return false;
    };

    return result;
}

test "parse simple literals" {
    const input = "select    10, 20, 30, cats";
    const expected = "select 10, 20, 30, cats";

    try std.testing.expect(testHarness(input, expected));
}

test "parse multi token elements" {
    const input = "select  cats  *  3, dogs + 4 ";
    const expected = "select cats * 3, dogs + 4";

    try std.testing.expect(testHarness(input, expected));
}

test "parse expression with precedence" {
    // x + y * z should parse as x + (y * z), rendering left-to-right gives "x + y * z"
    const input = "select a + b * c";
    const expected = "select a + b * c";

    try std.testing.expect(testHarness(input, expected));
}

test "parse chained operations same precedence" {
    // a - b - c should parse as (a - b) - c (left associative)
    const input = "select x - y - z";
    const expected = "select x - y - z";

    try std.testing.expect(testHarness(input, expected));
}

test "parse parens" {
    const input = "select (1+2)*3";
    const expected = "select (1 + 2) * 3";

    try std.testing.expect(testHarness(input, expected));
}

test "parse joins" {
    const input = "select * from a join b on a.x = b.x";
    const expected = "select * from a join b on a.x = b.x";

    try std.testing.expect(testHarness(input, expected));
}

test "parse complex joins" {
    const input = "select * from a left join b on a.x = b.x full outer join c on a.y = c.y";
    const expected = input;

    try std.testing.expect(testHarness(input, expected));
}

// test "parse unions" {
//     const input = "select * from a union all select * from b";
//     const expected = input;

//     try std.testing.expect(testHarness(input, expected));
// }

test "parse nested query" {
    const input = "select * from (select col from table)";
    const expected = input;

    try std.testing.expect(testHarness(input, expected));
}

test "parse simple cte" {
    const input = "with my_cte as (select col from table) select * from my_cte";
    const expected = input;

    try std.testing.expect(testHarness(input, expected));
}

test "parse multiple ctes" {
    const input = "with a as (select x from t1), b as (select y from t2) select * from a join b on a.x = b.y";
    const expected = input;

    try std.testing.expect(testHarness(input, expected));
}

test "parse minimal cte" {
    const input = "with x as (select 1) select * from x";
    const expected = input;

    try std.testing.expect(testHarness(input, expected));
}

test "implicit select" {
    const input = "xyx";
    const expected = "select * from xyz";

    try std.testing.expect(testHarness(input, expected));
}

test "select with alias" {
    const input = "select 1 as xyz";
    const expected = input;

    try std.testing.expect(testHarness(input, expected));
}

// TEST
