const std = @import("std");

const StringBuilder = @import("../common.zig").StringBuilder;
const String = []const u8;
const CString = [:0]const u8;
const MutString = std.ArrayList(u8);

pub const TokenType = enum {
    None,
    // Keywords - Clauses
    Select,
    From,
    Where,
    GroupBy,
    Having,
    OrderBy,
    Qualify,
    Limit,
    Join,
    InnerJoin,
    LeftJoin,
    RightJoin,
    FullJoin,
    CrossJoin,
    On,
    // Keywords - Other
    With,
    In,
    Is,
    And,
    Or,
    As,
    Over,
    Null,
    // Single Char Punctuation
    Star,
    Plus,
    Minus,
    Slash,
    LessThan,
    GreaterThan,
    Equal,
    OpenParen,
    CloseParen,
    Colon,
    Comma,
    Dot,
    ExclamationPoint,
    // Multi Char Punctuation
    LessThanEqual,
    GreaterThanEqual,
    NotEqual,
    DoubleColon,
    ColonEqual,
    // Generic Types
    Numeric,
    String,
    Identifier,
    Boolean,
    // Function Types
    AggregateFunction,
    NonAggregateFunction,
    WindowFunction,
    //

};

pub const Token = struct {
    token_type: TokenType,
    string_index: usize,
};

pub const LexedTokens = struct {
    allocator: std.mem.Allocator,
    tokens: std.ArrayList(Token),
    string_buffer: std.ArrayList(MutString),

    pub fn init(allocator: std.mem.Allocator) !LexedTokens {
        const tokens = try std.ArrayList(Token).initCapacity(allocator, 8);
        var string_buffer = try std.ArrayList(MutString).initCapacity(allocator, 8);

        const new_string: MutString = .empty;

        try string_buffer.append(allocator, new_string);
        return LexedTokens{ .allocator = allocator, .tokens = tokens, .string_buffer = string_buffer };
    }

    pub fn deinit(self: *LexedTokens) void {
        self.tokens.deinit(self.allocator);

        for (self.string_buffer.items) |*str| {
            str.deinit(self.allocator);
        }

        self.string_buffer.deinit(self.allocator);
    }

    fn append(self: *LexedTokens, token_type: TokenType, token_text: String) !void {
        if (token_text.len == 0) {
            const token = Token{ .token_type = token_type, .string_index = 0 };
            try self.tokens.append(self.allocator, token);
            return;
        }

        var new_string = try MutString.initCapacity(self.allocator, token_text.len);
        try new_string.appendSlice(self.allocator, token_text);
        const string_index = self.string_buffer.items.len;

        try self.string_buffer.append(self.allocator, new_string);

        const token = Token{ .token_type = token_type, .string_index = string_index };

        try self.tokens.append(self.allocator, token);
    }

    fn getTokenTypes(self: *const LexedTokens, allocator: std.mem.Allocator) !std.ArrayList(TokenType) {
        var token_types = try std.ArrayList(TokenType).initCapacity(allocator, self.tokens.items.len);

        for (self.tokens.items) |token| {
            try token_types.append(allocator, token.token_type);
        }
        return token_types;
    }

    fn debugPrintElement(self: *const LexedTokens, index: usize) void {
        const token = self.tokens.items[index];
        const string = self.string_buffer.items[token.string_index];

        std.debug.print("{any}('{s}') ", .{ token.token_type, string.items });
    }

    pub fn debugPrint(self: *LexedTokens, allocator: std.mem.Allocator) !void {
        var token_types = try self.getTokenTypes(allocator);
        defer token_types.deinit(allocator);

        std.debug.print("{any}\n", .{token_types.items});

        for (0..self.tokens.items.len) |token_index| {
            self.debugPrintElement(token_index);
        }
        std.debug.print("{s}", .{"\n\n"});
    }
};

pub fn buildLexString(lexed_tokens: LexedTokens, string_builder: *StringBuilder) String {
    string_builder.clear();

    var format_buffer: [1024]u8 = undefined;

    for (lexed_tokens.tokens.items) |token| {
        const string = lexed_tokens.string_buffer.items[token.string_index];

        const formatted_string = std.fmt.bufPrint(&format_buffer, "{any}('{s}') ", .{ token.token_type, string.items }) catch {
            return "<error formatting string>";
        };

        string_builder.append(formatted_string);
    }

    return string_builder.viewString();
}

inline fn isNumeric(char: u8) bool {
    return char >= 48 and char <= 57;
}

// TODO: Support unicode probably?
inline fn isAlpha(char: u8) bool {
    return ((char >= 65 and char <= 90) or
        (char >= 97 and char <= 122));
}

inline fn isWhitespace(char: u8) bool {
    return char <= 32;
}

inline fn toAsciiLowercase(char: u8) u8 {
    if (char >= 'A' and char <= 'Z') {
        return char + 32;
    } else {
        return char;
    }
}

pub const Lexer = struct {
    allocator: std.mem.Allocator,
    lexed_tokens: LexedTokens,
    input: String,
    position: usize,

    pub fn init(allocator: std.mem.Allocator, input: String) !Lexer {
        const lexed_tokens = try LexedTokens.init(allocator);

        return Lexer{
            .allocator = allocator,
            .lexed_tokens = lexed_tokens,
            .input = input,
            .position = 0,
        };
    }

    pub fn deinit(self: *Lexer) void {
        self.lexed_tokens.deinit();
    }

    fn isAtEnd(self: *Lexer) bool {
        return self.position >= self.input.len;
    }

    fn peek(self: *Lexer) u8 {
        if (self.position >= self.input.len) {
            return 0;
        }
        return self.input[self.position];
    }

    fn peekNext(self: *Lexer) u8 {
        if (self.position + 1 >= self.input.len) {
            return 0;
        }
        return self.input[self.position + 1];
    }

    fn advance(self: *Lexer) void {
        self.position += 1;
    }

    fn advanceBy(self: *Lexer, steps: usize) void {
        self.position += steps;
    }

    fn consume(self: *Lexer) u8 {
        const next_byte = self.peek();
        self.advance();
        return next_byte;
    }

    fn consumeWordCaseInsensitive(self: *Lexer, allocator: std.mem.Allocator) !MutString {
        var word = try MutString.initCapacity(allocator, 64);

        while (!self.isAtEnd()) {
            const char = self.peek();

            if (isAlpha(char) or isNumeric(char) or char == '_') {
                const lower_char = toAsciiLowercase(char);
                try word.append(allocator, lower_char);
                self.advance();
            } else {
                break;
            }
        }

        return word;
    }

    fn commitTextAsToken(self: *Lexer, text: String) !void {
        var token_type = TokenType.Identifier;

        if (std.mem.eql(u8, text, "select")) {
            token_type = TokenType.Select;
        } else if (std.mem.eql(u8, text, "from")) {
            token_type = TokenType.From;
        } else {}

        try self.lexed_tokens.append(token_type, text);
    }

    // TODO: Make this stricter. It will ingest tons of invalid numbers.
    fn commitNumber(self: *Lexer) !void {
        const start_position = self.position;
        var numeric_length: usize = 0;

        var last_seen_char: u8 = 0;
        var seen_exponent = false;
        var seen_decimal = false;

        while (!self.isAtEnd()) {
            const char = self.peek();

            if (isNumeric(char)) {
                self.advance();
                numeric_length += 1;
            } else if (char == '-') {
                if (last_seen_char == 'e' or last_seen_char == 'E' or last_seen_char == 0) {
                    self.advance();
                    numeric_length += 1;
                } else {
                    break;
                }
            } else if ((char == 'e' or char == 'E') and !seen_exponent) {
                seen_exponent = true;
                self.advance();
                numeric_length += 1;
            } else if (char == '.') { // TODO: This isn't precise, since it will match 3e.4 and nonsense like that.
                seen_decimal = true;
                self.advance();
                numeric_length += 1;
            } else {
                break;
            }
            last_seen_char = char;
        }

        if (numeric_length > 0) {
            try self.lexed_tokens.append(TokenType.Numeric, self.input[start_position .. start_position + numeric_length]);
        }
    }

    pub fn resolveTextToken(text: String) TokenType {
        // Reserved words for specific tokens
        if (std.mem.eql(u8, text, "and")) {
            return TokenType.And;
        } else if (std.mem.eql(u8, text, "or")) {
            return TokenType.Or;
        } else if (std.mem.eql(u8, text, "over")) {
            return TokenType.Over;
        }

        // Boolean
        if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false")) {
            return TokenType.Boolean;
        }

        // Clause types
        if (std.mem.eql(u8, text, "select")) {
            return TokenType.Select;
        } else if (std.mem.eql(u8, text, "from")) {
            return TokenType.From;
        } else if (std.mem.eql(u8, text, "where")) {
            return TokenType.Where;
        } else if (std.mem.eql(u8, text, "groupby")) {
            return TokenType.GroupBy; // TODO: I need to parse "group by" as two words
        } else if (std.mem.eql(u8, text, "having")) {
            return TokenType.Having;
        } else if (std.mem.eql(u8, text, "qualify")) {
            return TokenType.Qualify;
        } else if (std.mem.eql(u8, text, "limit")) {
            return TokenType.Limit;
        } else if (std.mem.eql(u8, text, "join")) {
            return TokenType.Join;
        } else if (std.mem.eql(u8, text, "on")) {
            return TokenType.On;
        } else if (std.mem.eql(u8, text, "with")) {
            return TokenType.With;
        } else if (std.mem.eql(u8, text, "as")) {
            return TokenType.As;
        }

        // All Aggregate functions can be window functions
        const aggregate_functions = [_][]const u8{
            "any_value",
            "approx_count_distinct",
            "approx_percentile_accumulate",
            "approx_percentile_combine",
            "approx_percentile_estimate",
            "approx_percentile",
            "approx_top_k_accumulate",
            "approx_top_k_combine",
            "approx_top_k_estimate",
            "approx_top_k",
            "approximate_jaccard_index",
            "approximate_similarity",
            "array_agg",
            "array_union_agg",
            "array_unique_agg",
            "avg",
            "bitand_agg",
            "bitor_agg",
            "bitxor_agg",
            "booland_agg",
            "boolor_agg",
            "boolxor_agg",
            "corr",
            "count_if",
            "count",
            "covar_pop",
            "covar_samp",
            "datasketches_hll_accumulate",
            "datasketches_hll_combine",
            "datasketches_hll_estimate",
            "datasketches_hll",
            "hash_agg",
            "hll_accumulate",
            "hll_combine",
            "hll_estimate",
            "hll_export",
            "hll_import",
            "hll",
            "kurtosis",
            "listagg",
            "max",
            "median",
            "min",
            "minhash_combine",
            "minhash",
            "mode",
            "object_agg",
            "percentile_cont",
            "percentile_disc",
            "regr_avgx",
            "regr_avgy",
            "regr_count",
            "regr_intercept",
            "regr_r2",
            "regr_slope",
            "regr_sxx",
            "regr_sxy",
            "regr_syy",
            "stddev_pop",
            "stddev",
            "stddev_samp",
            "sum",
            "var_pop",
            "var_samp",
            "variance",
            "variance_samp",
            "variance_pop",
        };

        for (aggregate_functions) |name| {
            if (std.mem.eql(u8, text, name)) {
                return TokenType.AggregateFunction;
            }
        }

        const window_functions = [_][]const u8{
            "conditional_change_event",
            "conditional_true_event",
            "cume_dist",
            "dense_rank",
            "first_value",
            "interpolate_bfill, interpolate_ffill, interpolate_linear",
            "lag",
            "last_value",
            "lead",
            "nth_value",
            "ntile",
            "percent_rank",
            "rank",
            "ratio_to_report",
            "row_number",
        };

        for (window_functions) |name| {
            if (std.mem.eql(u8, text, name)) {
                return TokenType.WindowFunction;
            }
        }

        const non_aggregate_functions = [_][]const u8{
            "abs",
            "acos",
            "acosh",
            "add_months",
            "ai_complete",
            "all_user_names",
            "application_json",
            "array_append",
            "array_cat",
            "array_compact",
            "array_construct_compact",
            "array_construct",
            "array_contains",
            "array_distinct",
            "array_except",
            "array_flatten",
            "array_generate_range",
            "array_insert",
            "array_intersection",
            "array_max",
            "array_min",
            "array_position",
            "array_prepend",
            "array_remove_at",
            "array_remove",
            "array_reverse",
            "array_size",
            "array_slice",
            "array_sort",
            "array_to_string",
            "arrays_overlap",
            "arrays_to_object",
            "arrays_zip",
            "as_array",
            "as_binary",
            "as_boolean",
            "as_char",
            "as_varchar",
            "as_date",
            "as_decimal",
            "as_number",
            "as_double",
            "as_real",
            "as_integer",
            "as_object",
            "as_time",
            "as_timestamp",
            "ascii",
            "asin",
            "asinh",
            "atan",
            "atan2",
            "atanh",
            "base64_decode_binary",
            "base64_decode_string",
            "base64_encode",
            "bit_length",
            "bitand",
            "bitnot",
            "bitor",
            "bitshiftleft",
            "bitshiftright",
            "bitxor",
            "booland",
            "boolnot",
            "boolor",
            "boolxor",
            "case",
            "cast",
            "cbrt",
            "ceil",
            "charindex",
            "check_json",
            "check_xml",
            "chr",
            "char",
            "classify_text",
            "coalesce",
            "collate",
            "collation",
            "complete",
            "compress",
            "concat",
            "concat_ws",
            "contains",
            "convert_timezone",
            "cos",
            "cosh",
            "cot",
            "current_account_name",
            "current_account",
            "current_available_roles",
            "current_client",
            "current_database",
            "current_date",
            "current_ip_address",
            "current_organization_name",
            "current_organization_user",
            "current_region",
            "current_role_type",
            "current_role",
            "current_schema",
            "current_schemas",
            "current_secondary_roles",
            "current_session",
            "current_statement",
            "current_time",
            "current_timestamp",
            "current_transaction",
            "current_user",
            "current_version",
            "current_warehouse",
            "date_from_parts",
            "date_part",
            "date_trunc",
            "dateadd",
            "datediff",
            "dayname",
            "decode",
            "decompress_binary",
            "decompress_string",
            "decrypt_raw",
            "decrypt",
            "degrees",
            "div0",
            "div0null",
            "dp_interval_high",
            "dp_interval_low",
            "editdistance",
            "email_integration_config",
            "encrypt_raw",
            "encrypt",
            "endswith",
            "equal_null",
            "estimate_remaining_dp_aggregates",
            "exp",
            "extract",
            "factorial",
            "filter",
            "floor",
            "generate_column_description",
            "get_condition_query_uuid",
            "get_ddl",
            "get_ignore_case",
            "get_path",
            "get",
            "getbit",
            "getdate",
            "getvariable",
            "greatest_ignore_nulls",
            "greatest",
            "h3_cell_to_boundary",
            "h3_cell_to_children_string",
            "h3_cell_to_children",
            "h3_cell_to_parent",
            "h3_cell_to_point",
            "h3_compact_cells_strings",
            "h3_compact_cells",
            "h3_coverage_strings",
            "h3_coverage",
            "h3_get_resolution",
            "h3_grid_disk",
            "h3_grid_distance",
            "h3_grid_path",
            "h3_int_to_string",
            "h3_is_pentagon",
            "h3_is_valid_cell",
            "h3_latlng_to_cell_string",
            "h3_latlng_to_cell",
            "h3_point_to_cell_string",
            "h3_point_to_cell",
            "h3_polygon_to_cells_strings",
            "h3_polygon_to_cells",
            "h3_string_to_int",
            "h3_try_coverage_strings",
            "h3_try_coverage",
            "h3_try_grid_distance",
            "h3_try_grid_path",
            "h3_try_polygon_to_cells_strings",
            "h3_try_polygon_to_cells",
            "h3_uncompact_cells_strings",
            "h3_uncompact_cells",
            "hash",
            "haversine",
            "hex_decode_binary",
            "hex_decode_string",
            "hex_encode",
            "hour",
            "minute",
            "second",
            "iff",
            "ifnull",
            "ilike any",
            "initcap",
            "insert",
            "integration",
            "invoker_role",
            "invoker_share",
            "is_array",
            "is_binary",
            "is_boolean",
            "is_char",
            "is_varchar",
            "is_date",
            "is_date_value",
            "is_decimal",
            "is_double , is_real",
            "is_integer",
            "is_null_value",
            "is_object",
            "is_organization_user_group",
            "is_organization_user",
            "is_time",
            "is_timestamp",
            "jarowinkler_similarity",
            "json_extract_path_text",
            "last_day",
            "last_query_id",
            "last_successful_scheduled_time",
            "last_transaction",
            "least_ignore_nulls",
            "least",
            "left",
            "length",
            "len",
            "ln",
            "localtime",
            "localtimestamp",
            "log",
            "lower",
            "lpad",
            "ltrim",
            "map_cat",
            "map_contains_key",
            "map_delete",
            "map_insert",
            "map_keys",
            "map_pick",
            "map_size",
            "md5",
            "md5_hex",
            "md5_binary",
            "md5_number_lower64",
            "md5_number_upper64",
            "mod",
            "model_monitor_drift_metric",
            "model_monitor_performance_metric",
            "model_monitor_stat_metric",
            "monthname",
            "months_between",
            "next_day",
            "normal",
            "nullif",
            "nullifzero",
            "nvl",
            "nvl2",
            "object_construct_keep_null",
            "object_construct",
            "object_delete",
            "object_insert",
            "object_keys",
            "object_pick",
            "octet_length",
            "parse_ip",
            "parse_json",
            "parse_url",
            "parse_xml",
            "pi",
            "policy_context",
            "position",
            "pow",
            "power",
            "previous_day",
            "prompt",
            "radians",
            "random",
            "randstr",
            "reduce",
            "regexp_count",
            "regexp_instr",
            "regexp_like",
            "regexp_replace",
            "regexp_substr_all",
            "regexp_substr",
            "regr_valx",
            "regr_valy",
            "repeat",
            "replace",
            "reverse",
            "right",
            "round",
            "rpad",
            "rtrim",
            "rtrimmed_length",
            "sanitize_webhook_content",
            "scheduled_time",
            "search_ip",
            "search",
            "sha1",
            "sha1_hex",
            "sha1_binary",
            "sha2",
            "sha2_hex",
            "sha2_binary",
            "sign",
            "sin",
            "sinh",
            "soundex_p123",
            "soundex",
            "space",
            "split_part",
            "split_to_table",
            "split",
            "sqrt",
            "square",
            "st_x",
            "st_xmax",
            "st_xmin",
            "st_y",
            "st_ymax",
            "st_ymin",
            "startswith",
            "strip_null_value",
            "strtok_split_to_table",
            "strtok_to_array",
            "strtok",
            "substr",
            "substring",
            "sysdate",
            "systimestamp",
            "tan",
            "tanh",
            "text_html",
            "text_plain",
            "time_from_parts",
            "time_slice",
            "timeadd",
            "timediff",
            "timestamp_from_parts",
            "timestampadd",
            "timestampdiff",
            "to_array",
            "to_binary",
            "to_boolean",
            "to_char",
            "to_varchar",
            "to_date",
            "date",
            "to_decfloat",
            "to_decimal",
            "to_number",
            "to_numeric",
            "to_double",
            "to_geography",
            "to_geometry",
            "to_json",
            "to_object",
            "to_time",
            "time",
            "to_timestamp",
            "to_variant",
            "to_xml",
            "transform",
            "translate",
            "trim",
            "truncate",
            "trunc",
            "try_base64_decode_binary",
            "try_base64_decode_string",
            "try_cast",
            "try_decrypt_raw",
            "try_decrypt",
            "try_hex_decode_binary",
            "try_hex_decode_string",
            "try_parse_json",
            "try_to_binary",
            "try_to_boolean",
            "try_to_date",
            "try_to_decfloat",
            "try_to_decimal",
            "try_to_number",
            "try_to_numeric",
            "try_to_double",
            "try_to_geography",
            "try_to_geometry",
            "try_to_time",
            "try_to_timestamp",
            "typeof",
            "unicode",
            "uniform",
            "upper",
            "uuid_string",
            "vector_avg",
            "vector_cosine_similarity",
            "vector_inner_product",
            "vector_l1_distance",
            "vector_l2_distance",
            "vector_max",
            "vector_min",
            "vector_sum",
            "width_bucket",
            "xmlget",
            "year",
            "day",
            "week",
            "month",
            "quarter",
            "zeroifnull",
            "zipf",
        };

        for (non_aggregate_functions) |name| {
            if (std.mem.eql(u8, text, name)) {
                return TokenType.NonAggregateFunction;
            }
        }

        return TokenType.Identifier;
    }

    fn tryConsumeJoinToken(self: *Lexer, first_word: String) !?TokenType {
        if (!std.mem.eql(u8, first_word, "inner") and
            !std.mem.eql(u8, first_word, "left") and
            !std.mem.eql(u8, first_word, "right") and
            !std.mem.eql(u8, first_word, "full") and
            !std.mem.eql(u8, first_word, "cross")) return null;

        const saved_position = self.position;

        while (!self.isAtEnd() and isWhitespace(self.peek())) self.advance();

        if (self.isAtEnd() or !isAlpha(self.peek())) {
            self.position = saved_position;
            return null;
        }

        var second_word = try self.consumeWordCaseInsensitive(self.allocator);
        defer second_word.deinit(self.allocator);

        if (std.mem.eql(u8, second_word.items, "outer")) {
            while (!self.isAtEnd() and isWhitespace(self.peek())) self.advance();

            if (self.isAtEnd() or !isAlpha(self.peek())) {
                self.position = saved_position;
                return null;
            }

            var third_word = try self.consumeWordCaseInsensitive(self.allocator);
            defer third_word.deinit(self.allocator);

            if (!std.mem.eql(u8, third_word.items, "join")) {
                self.position = saved_position;
                return null;
            }

            if (std.mem.eql(u8, first_word, "full")) return TokenType.FullJoin;
            if (std.mem.eql(u8, first_word, "left")) return TokenType.LeftJoin;
            if (std.mem.eql(u8, first_word, "right")) return TokenType.RightJoin;
            self.position = saved_position;
            return null;
        }

        if (std.mem.eql(u8, second_word.items, "join")) {
            if (std.mem.eql(u8, first_word, "inner")) return TokenType.InnerJoin;
            if (std.mem.eql(u8, first_word, "left")) return TokenType.LeftJoin;
            if (std.mem.eql(u8, first_word, "right")) return TokenType.RightJoin;
            if (std.mem.eql(u8, first_word, "full")) return TokenType.FullJoin;
            if (std.mem.eql(u8, first_word, "cross")) return TokenType.CrossJoin;
        }

        self.position = saved_position;
        return null;
    }

    pub fn lex(self: *Lexer) !void {
        while (!self.isAtEnd()) {
            const char = self.peek();
            var token_type = TokenType.None;

            if (isWhitespace(char)) {
                self.advance();
            } else if (isNumeric(char)) {
                try self.commitNumber();
            } else if (isAlpha(char)) {
                var matched_text = try self.consumeWordCaseInsensitive(self.allocator);
                defer matched_text.deinit(self.allocator);

                const matched_slice = matched_text.items[0..];

                if (try self.tryConsumeJoinToken(matched_slice)) |join_token| {
                    try self.lexed_tokens.append(join_token, "");
                } else {
                    const resolved_token = resolveTextToken(matched_slice);
                    try self.lexed_tokens.append(resolved_token, matched_slice);
                }
            } else if (char == '"') {} else if (char == '\'') {} else {
                const next_char = self.peekNext();

                token_type = switch (char) {
                    '*' => TokenType.Star,
                    '+' => TokenType.Plus,
                    '-' => TokenType.Minus,
                    '/' => TokenType.Slash,
                    '<' => switch (next_char) {
                        '=' => TokenType.LessThanEqual,
                        '>' => TokenType.NotEqual,
                        else => TokenType.LessThan,
                    },
                    '>' => switch (next_char) {
                        '=' => TokenType.GreaterThanEqual,
                        else => TokenType.GreaterThan,
                    },
                    '=' => TokenType.Equal,
                    '(' => TokenType.OpenParen,
                    ')' => TokenType.CloseParen,
                    ':' => switch (next_char) {
                        ':' => TokenType.DoubleColon,
                        '=' => TokenType.ColonEqual,
                        else => TokenType.Colon,
                    },
                    ',' => TokenType.Comma,
                    '.' => TokenType.Dot,
                    '!' => switch (next_char) {
                        '=' => TokenType.NotEqual,
                        else => TokenType.ExclamationPoint,
                    },
                    else => TokenType.None,
                };

                _ = switch (token_type) {
                    TokenType.LessThanEqual, TokenType.GreaterThanEqual, TokenType.NotEqual, TokenType.DoubleColon, TokenType.ColonEqual => {
                        self.advanceBy(2);
                    },
                    else => {
                        self.advance();
                    },
                };

                try self.lexed_tokens.append(token_type, "");
            }
        }
    }

    // TODO: Is there a better way to handle ownership here, especially if I arena this?
    pub fn getOwnedResult(self: *Lexer) !LexedTokens {
        const lexed_tokens = self.lexed_tokens;

        self.lexed_tokens = try LexedTokens.init(self.allocator);
        self.position = 0;

        return lexed_tokens;
    }
};

pub fn lex(allocator: std.mem.Allocator, input: String) !LexedTokens {
    var lexer = try Lexer.init(allocator, input);
    defer lexer.deinit();

    try lexer.lex();
    return lexer.getOwnedResult();
}

fn testHarness(allocator: std.mem.Allocator, input: String, expect: []const TokenType) !bool {
    var lexer = try Lexer.init(allocator, input);
    defer lexer.deinit();

    try lexer.lex();
    var lexed_result = try lexer.getOwnedResult();
    defer lexed_result.deinit(); // TODO: Make unmanaged maybe

    var token_types = try lexed_result.getTokenTypes(allocator);
    defer token_types.deinit(allocator);

    return std.mem.eql(TokenType, token_types.items, expect);
}

test "lex_single_punctuation" {
    const input = "+ - *";
    const expected: [3]TokenType = .{ TokenType.Plus, TokenType.Minus, TokenType.Star };

    try std.testing.expect(try testHarness(std.testing.allocator, input, &expected));
}

test "lex_multi_punctuation" {
    const input = "+ <> : : * ::";
    const expected: [6]TokenType = .{ TokenType.Plus, TokenType.NotEqual, TokenType.Colon, TokenType.Colon, TokenType.Star, TokenType.DoubleColon };

    try std.testing.expect(try testHarness(std.testing.allocator, input, &expected));
}

test "lex_numbers" {
    const input = "3 + 33 + 33.3 + 3.3e3";
    const expected: [7]TokenType = .{ TokenType.Numeric, TokenType.Plus, TokenType.Numeric, TokenType.Plus, TokenType.Numeric, TokenType.Plus, TokenType.Numeric };

    try std.testing.expect(try testHarness(std.testing.allocator, input, &expected));
}

test "lex_reserved_words" {
    const input = "select abc from xyz";
    const expected: [4]TokenType = .{ TokenType.Select, TokenType.Identifier, TokenType.From, TokenType.Identifier };

    try std.testing.expect(try testHarness(std.testing.allocator, input, &expected));
}

test "lex_simple_literals" {
    const input = "select 10, 20";
    const expected: [4]TokenType = .{ TokenType.Select, TokenType.Numeric, TokenType.Comma, TokenType.Numeric };

    try std.testing.expect(try testHarness(std.testing.allocator, input, &expected));
}
