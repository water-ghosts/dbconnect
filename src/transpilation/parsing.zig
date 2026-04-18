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
                // else => 1,
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
    selectExpressions: std.ArrayList(ExpressionID),
    fromExpression: ExpressionID,
    joinExpressions: std.ArrayList(ExpressionID),
    whereExpression: ExpressionID,
    groupByExpressions: std.ArrayList(ExpressionID),
    havingExpression: ExpressionID,
    qualifyExpression: ExpressionID,
    limitExpression: ExpressionID,

    expressions: []Expression,
    stringBuffer: []MutString,
    containsAggregate: bool,

    pub fn deinit(self: *Self) void {
        self.ctes.deinit(self.allocator);
        self.selectExpressions.deinit(self.allocator);
        self.joinExpressions.deinit(self.allocator);
        self.groupByExpressions.deinit(self.allocator);
        self.expressions = undefined;
        self.stringBuffer = undefined;
    }

    fn renderExpression(self: *const Self, expression_id: ExpressionID, builder: *StringBuilder) void {
        switch (self.expressions[expression_id]) {
            .literal => |lit| {
                const theString = self.stringBuffer[lit.string_index];
                builder.append(theString.items);
            },
            .identifier, .uncategorized => |ident| {
                const theString = self.stringBuffer[ident.string_index];
                builder.append(theString.items);
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
                const theString = self.stringBuffer[func.function_name_index];
                builder.append(theString.items);

                if (func.arguments.items.len > 0) {
                    builder.push('(');
                    self.renderExpressionList(func.arguments.items[0..], builder);
                    builder.push(')');
                }
            },
            .star => {
                builder.push('*');
            },
            .join => |j| {
                const kind_str: []const u8 = switch (j.kind) {
                    .inner => "join",
                    .left => "left join",
                    .right => "right join",
                    .full => "full outer join",
                    .cross => "cross join",
                };
                builder.append(kind_str);
                builder.push(' ');
                self.renderExpression(j.table, builder);
                if (j.on_condition > 0) {
                    builder.append(" on ");
                    self.renderExpression(j.on_condition, builder);
                }
            },
            .subquery => |sq| {
                builder.push('(');
                builder.append("select ");
                if (sq.select.items.len > 0) {
                    self.renderExpressionList(sq.select.items, builder);
                } else {
                    builder.append("*");
                }
                if (sq.from > 0) {
                    builder.append(" from ");
                    self.renderExpression(sq.from, builder);
                }
                for (sq.joins.items) |join_id| {
                    builder.push(' ');
                    self.renderExpression(join_id, builder);
                }
                if (sq.where > 0) {
                    builder.append(" where ");
                    self.renderExpression(sq.where, builder);
                }
                if (sq.group_by.items.len > 0) {
                    builder.append(" group by ");
                    self.renderExpressionList(sq.group_by.items, builder);
                }
                if (sq.having > 0) {
                    builder.append(" having ");
                    self.renderExpression(sq.having, builder);
                }
                if (sq.qualify > 0) {
                    builder.append(" qualify ");
                    self.renderExpression(sq.qualify, builder);
                }
                builder.push(')');
            },
            .empty => {},
        }
    }

    pub fn renderExpressionList(self: *const Self, expressions: []ExpressionID, builder: *StringBuilder) void {
        var isFirstElement = true;
        for (expressions) |expression_id| {
            if (expression_id == 0) {
                continue;
            }

            if (!isFirstElement) {
                builder.push(',');
                builder.push(' ');
            }

            self.renderExpression(expression_id, builder);

            isFirstElement = false;
        }
    }

    pub fn render(self: *const Self, allocator: std.mem.Allocator) !MutString {
        var builder = StringBuilder.init(allocator);
        defer builder.deinit();

        if (self.ctes.items.len > 0) {
            builder.append("with ");
            for (self.ctes.items, 0..) |cte, i| {
                if (i > 0) builder.append(", ");
                builder.append(self.stringBuffer[cte.name_index].items);
                builder.append(" as ");
                self.renderExpression(cte.body, &builder);
            }
            builder.push(' ');
        }

        builder.append("select ");
        if (self.selectExpressions.items.len > 0) {
            self.renderExpressionList(self.selectExpressions.items[0..], &builder);
        } else {
            builder.append("*");
        }

        if (self.fromExpression > 0) {
            builder.append(" from ");
            self.renderExpression(self.fromExpression, &builder);
        }

        for (self.joinExpressions.items) |join_id| {
            builder.push(' ');
            self.renderExpression(join_id, &builder);
        }

        if (self.whereExpression > 0) {
            builder.append(" where ");
            self.renderExpression(self.whereExpression, &builder);
        }

        if (self.groupByExpressions.items.len > 0) {
            builder.append(" group by ");
            self.renderExpressionList(self.groupByExpressions.items[0..], &builder);
        }

        if (self.havingExpression > 0) {
            builder.append(" having ");
            self.renderExpression(self.havingExpression, &builder);
        }

        if (self.qualifyExpression > 0) {
            builder.append(" qualify ");
            self.renderExpression(self.qualifyExpression, &builder);
        }

        return builder.toOwnedMutString();
    }
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexedTokens: LexedTokens,
    stringBuffer: std.ArrayList(MutString),
    position: usize = 0,
    // Arena for allocating expression nodes - they live for the lifetime of the parse result
    expressions: std.ArrayList(Expression),

    pub fn init(allocator: std.mem.Allocator, lexedTokens: LexedTokens) !Parser {
        const stringBuffer = try lexedTokens.stringBuffer.clone(allocator);
        var expressions = try std.ArrayList(Expression).initCapacity(allocator, 1024);
        try expressions.append(allocator, NullExpression);

        return Parser{
            .allocator = allocator,
            .lexedTokens = lexedTokens,
            .stringBuffer = stringBuffer,
            .position = 0,
            .expressions = expressions,
        };
    }

    pub fn deinit(self: *Parser) void {
        // Free owned data inside expression nodes
        for (self.expressions.items) |*expr| {
            switch (expr.*) {
                .subquery => |*sq| {
                    sq.select.deinit(self.allocator);
                    sq.joins.deinit(self.allocator);
                    sq.group_by.deinit(self.allocator);
                },
                .function => |*func| {
                    func.arguments.deinit(self.allocator);
                },
                else => {},
            }
        }
        // Free strings appended by the parser (dotted identifiers etc.) beyond the
        // original lexer buffer. The lexer owns and will free the originals.
        const original_count = self.lexedTokens.stringBuffer.items.len;
        for (self.stringBuffer.items[original_count..]) |*str| {
            str.deinit(self.allocator);
        }
        self.stringBuffer.deinit(self.allocator);
        self.lexedTokens.deinit();
        self.expressions.deinit(self.allocator);
    }

    fn isAtEnd(self: *Parser) bool {
        return self.position >= self.lexedTokens.tokens.items.len;
    }

    fn peek(self: *Parser) Token {
        if (self.isAtEnd()) {
            return Token{ .tokenType = TokenType.None, .stringIndex = 0 };
        }
        return self.lexedTokens.tokens.items[self.position];
    }

    fn peek_n_ahead(self: *Parser, n: usize) Token {
        const newPosition = self.position + n;
        if (newPosition >= self.lexedTokens.tokens.items.len) {
            return Token{ .tokenType = TokenType.None, .stringIndex = 0 };
        }
        return self.lexedTokens.tokens.items[newPosition];
    }

    fn advance(self: *Parser) void {
        self.position += 1;
    }

    fn consume(self: *Parser, token_type: TokenType) bool {
        const nextToken = self.peek();
        if (nextToken.tokenType == token_type) {
            self.advance();
            return true;
        }
        return false;
    }

    fn isNewClause(token: Token) bool {
        return (token.tokenType == TokenType.Select or
            token.tokenType == TokenType.From or
            token.tokenType == TokenType.Where or
            token.tokenType == TokenType.GroupBy or
            token.tokenType == TokenType.Having or
            token.tokenType == TokenType.Qualify or
            token.tokenType == TokenType.OrderBy or
            token.tokenType == TokenType.Join or
            token.tokenType == TokenType.InnerJoin or
            token.tokenType == TokenType.LeftJoin or
            token.tokenType == TokenType.RightJoin or
            token.tokenType == TokenType.FullJoin or
            token.tokenType == TokenType.CrossJoin);
    }

    // Check if current token marks the end of an expression
    fn isExpressionTerminator(token: Token) bool {
        return isNewClause(token) or
            token.tokenType == TokenType.Comma or
            token.tokenType == TokenType.None;
    }

    fn addExpression(self: *Parser, expr: Expression) !ExpressionID {
        try self.expressions.append(self.allocator, expr);
        return self.expressions.items.len - 1;
    }

    // Parse a primary expression (literals, identifiers)
    fn parsePrimary(self: *Parser) !ExpressionID {
        const token = self.peek();
        self.advance();

        switch (token.tokenType) {
            .Numeric, .Boolean => {
                return try self.addExpression(.{
                    .literal = .{
                        .token_type = token.tokenType,
                        .string_index = token.stringIndex,
                    },
                });
            },
            .String => {
                return try self.addExpression(.{
                    .literal = .{
                        .token_type = .String,
                        .string_index = token.stringIndex,
                    },
                });
            },
            .Identifier => {
                var string_index = token.stringIndex;
                // Handle dotted identifiers like a.x or schema.table.column
                while (self.peek().tokenType == .Dot) {
                    self.advance(); // consume dot
                    const next = self.peek();
                    if (next.tokenType != .Identifier) break;
                    self.advance(); // consume next identifier
                    const left_str = self.stringBuffer.items[string_index];
                    const right_str = self.stringBuffer.items[next.stringIndex];
                    var combined = try MutString.initCapacity(self.allocator, left_str.items.len + 1 + right_str.items.len);
                    try combined.appendSlice(self.allocator, left_str.items);
                    try combined.append(self.allocator, '.');
                    try combined.appendSlice(self.allocator, right_str.items);
                    string_index = self.stringBuffer.items.len;
                    try self.stringBuffer.append(self.allocator, combined);
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
                        .function_name_index = token.stringIndex,
                        .arguments = arguments,
                    },
                });
            },
            .OpenParen => {
                // Detect subquery: (SELECT ...) or (WITH ...)
                const next = self.peek();
                if (next.tokenType == .Select or next.tokenType == .With) {
                    const sq = try self.parseQueryBody(self.allocator);
                    if (!self.consume(.CloseParen)) {
                        return 0;
                    }
                    return try self.addExpression(.{ .subquery = sq });
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
            const op = Expression.Operator.fromTokenType(token.tokenType) orelse break;

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
            const nextToken = self.peek();
            std.debug.print("Peek: {any}\n", .{nextToken.tokenType});

            if (isNewClause(nextToken)) {
                std.debug.print("Breaking\n", .{});
                break;
            }

            // Skip commas between elements
            if (nextToken.tokenType == TokenType.Comma) {
                self.advance();
                continue;
            }

            if (nextToken.tokenType == TokenType.CloseParen) {
                if (break_on_paren) {
                    self.advance();
                }
                return elements;
            }

            // Kind of a hack, * is valid as a list element
            if (nextToken.tokenType == .Star) {
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
            if (self.peek().tokenType == .CloseParen) break;

            const nextToken = self.peek();
            self.advance();

            switch (nextToken.tokenType) {
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
                    const kind: Expression.JoinKind = switch (nextToken.tokenType) {
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
                    if (self.peek().tokenType == TokenType.Numeric) {
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
        var currentClause: ClauseType = ClauseType.Select;

        var ctes: std.ArrayList(CteDefinition) = .empty;
        var selectExpressions: std.ArrayList(ExpressionID) = .empty;
        var fromExpression: ExpressionID = 0;
        var joinExpressions: std.ArrayList(ExpressionID) = .empty;
        var whereExpression: ExpressionID = 0;
        var groupByExpressions: std.ArrayList(ExpressionID) = .empty;
        var havingExpression: ExpressionID = 0;
        var qualifyExpression: ExpressionID = 0;
        var limitExpression: ExpressionID = 0; // TODO: Just make this an integer maybe

        while (!self.isAtEnd()) {
            const nextToken = self.peek();
            self.advance();

            switch (nextToken.tokenType) {
                .With => {
                    var isMoreToParse = true;
                    while (isMoreToParse) {
                        isMoreToParse = false;

                        const name_token = self.peek();
                        if (name_token.tokenType != .Identifier) break;
                        self.advance();
                        if (!(self.consume(.As) or self.consume(.ColonEqual))) break;
                        if (!self.consume(.OpenParen)) break;
                        const body = try self.parseQueryBody(allocator);

                        std.debug.print("Expecting close paren: {any}\n", .{self.peek().tokenType});

                        if (!self.consume(.CloseParen)) break;
                        const body_id = try self.addExpression(.{ .subquery = body });
                        try ctes.append(allocator, CteDefinition{
                            .name_index = name_token.stringIndex,
                            .body = body_id,
                        });

                        if (self.consume(.Comma)) {
                            isMoreToParse = true;
                            continue;
                        }

                        if (self.peek().tokenType == .Identifier and self.peek_n_ahead(1).tokenType == .ColonEqual) {
                            isMoreToParse = true;
                            continue;
                        }
                    }
                },
                .Select => {
                    var newSelectElements = try self.parseExpressionList(false);
                    try selectExpressions.appendSlice(allocator, newSelectElements.items);
                    newSelectElements.deinit(allocator);
                },
                .From => {
                    currentClause = ClauseType.From;
                    fromExpression = self.parseExpression() catch 0;
                },
                .Where => {
                    currentClause = ClauseType.Where;
                    whereExpression = self.parseExpression() catch 0;
                },
                .GroupBy => {
                    currentClause = ClauseType.GroupBy;
                    var newGroupElements = try self.parseExpressionList(false);
                    try groupByExpressions.appendSlice(allocator, newGroupElements.items);
                    newGroupElements.deinit(allocator);
                },
                .Having => {
                    currentClause = ClauseType.Having;
                    havingExpression = self.parseExpression() catch 0;
                },
                .Qualify => {
                    currentClause = ClauseType.Qualify;
                    qualifyExpression = self.parseExpression() catch 0;
                },
                .Join, .InnerJoin, .LeftJoin, .RightJoin, .FullJoin, .CrossJoin => {
                    const kind: Expression.JoinKind = switch (nextToken.tokenType) {
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
                    try joinExpressions.append(allocator, join_expr);
                },
                .Limit => {
                    currentClause = ClauseType.Limit;
                    const maybeLimit = self.peek();
                    if (maybeLimit.tokenType == TokenType.Numeric) {
                        limitExpression = self.parsePrimary() catch 0;
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
            .selectExpressions = selectExpressions,
            .fromExpression = fromExpression,
            .joinExpressions = joinExpressions,
            .whereExpression = whereExpression,
            .groupByExpressions = groupByExpressions,
            .havingExpression = havingExpression,
            .qualifyExpression = qualifyExpression,
            .limitExpression = limitExpression,

            .stringBuffer = self.stringBuffer.items,
            .expressions = self.expressions.items,
            .containsAggregate = false,
        };
    }
};

fn innerTestHarness(input: String, expected: String) !bool {
    const allocator = std.testing.allocator;

    // Weird, so I don't want to deinit the lexed tokens because I pass ownership of them to the parser.
    const lexedResult = try lexing.lex(allocator, input);
    var lexStringBuilder = StringBuilder.init(allocator);
    defer lexStringBuilder.deinit();

    // TODO: Fix up this allocation pattern
    var parser = try Parser.init(allocator, lexedResult);
    defer parser.deinit();
    var parsedResult = try parser.parse(allocator);
    defer parsedResult.deinit();

    var output = try parsedResult.render(allocator);
    defer output.deinit(allocator);

    const didPass = std.mem.eql(u8, expected, output.items);

    if (!didPass) {
        std.debug.print("\n---FAIL---\n", .{});
        std.debug.print("Input: '{s}'\n", .{input});
        std.debug.print("Lexed: '{s}'\n", .{lexing.buildLexString(lexedResult, &lexStringBuilder)});
        std.debug.print("Expected: '{s}'\n", .{expected});
        std.debug.print("Got:      '{s}'\n", .{output.items});
    }

    return didPass;
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

// TEST
