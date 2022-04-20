const js_ast = @import("js_ast.zig");
const bun = @import("global.zig");
const string = bun.string;
const Output = bun.Output;
const Global = bun.Global;
const Environment = bun.Environment;
const strings = bun.strings;
const MutableString = bun.MutableString;
const stringZ = bun.stringZ;
const default_allocator = bun.default_allocator;
const C = bun.C;
const std = @import("std");
const Ref = @import("./ast/base.zig").Ref;
const logger = @import("logger.zig");

// This is...poorly named
// It does not rename
// It merely names
pub const Renamer = struct {
    symbols: js_ast.Symbol.Map,
    source: *const logger.Source,

    pub fn init(symbols: js_ast.Symbol.Map, source: *const logger.Source) Renamer {
        return Renamer{ .symbols = symbols, .source = source };
    }

    pub fn nameForSymbol(renamer: *Renamer, ref: Ref) string {
        if (ref.isSourceContentsSlice()) {
            return renamer.source.contents[ref.sourceIndex() .. ref.sourceIndex() + ref.innerIndex()];
        }

        const resolved = renamer.symbols.follow(ref);

        if (renamer.symbols.getConst(resolved)) |symbol| {
            return symbol.original_name;
        } else {
            Global.panic("Invalid symbol {s} in {s}", .{ ref, renamer.source.path.text });
        }
    }
};

pub const BundledRenamer = struct {
    symbols: js_ast.Symbol.Map,
    sources: []const []const u8,

    pub fn init(symbols: js_ast.Symbol.Map, sources: []const []const u8) Renamer {
        return Renamer{ .symbols = symbols, .source = sources };
    }

    pub fn nameForSymbol(renamer: *Renamer, ref: Ref) string {
        if (ref.isSourceContentsSlice()) {
            unreachable;
        }

        const resolved = renamer.symbols.follow(ref);

        if (renamer.symbols.getConst(resolved)) |symbol| {
            return symbol.original_name;
        } else {
            Global.panic("Invalid symbol {s} in {s}", .{ ref, renamer.source.path.text });
        }
    }
};

pub const DisabledRenamer = struct {
    pub fn init(_: js_ast.Symbol.Map) DisabledRenamer {}
    pub inline fn nameForSymbol(_: *Renamer, _: js_ast.Ref) string {
        @compileError("DisabledRunner called");
    }
};
