const std = @import("std");
const bun = @import("root").bun;
const Environment = bun.Environment;
const JSC = bun.JSC;
const string = bun.string;
const Output = bun.Output;
const ZigString = JSC.ZigString;
const createTypeError = JSC.JSGlobalObject.createTypeErrorInstanceWithCode;
const createError = JSC.JSGlobalObject.createErrorInstanceWithCode;
const createRangeError = JSC.JSGlobalObject.createRangeErrorInstanceWithCode;

pub const ERR_SOCKET_BAD_TYPE = createSimpleError(createTypeError, .ERR_SOCKET_BAD_TYPE, "Bad socket type specified. Valid types are: udp4, udp6");
pub const ERR_IPC_CHANNEL_CLOSED = createSimpleError(createError, .ERR_IPC_CHANNEL_CLOSED, "Channel closed");
pub const ERR_INVALID_HANDLE_TYPE = createSimpleError(createTypeError, .ERR_INVALID_HANDLE_TYPE, "This handle type cannot be sent");
pub const ERR_CHILD_CLOSED_BEFORE_REPLY = createSimpleError(createError, .ERR_CHILD_CLOSED_BEFORE_REPLY, "Child closed before reply received");
pub const ERR_SERVER_NOT_RUNNING = createSimpleError(createError, .ERR_SERVER_NOT_RUNNING, "Server is not running.");

fn createSimpleError(comptime createFn: anytype, comptime code: JSC.Node.ErrorCode, comptime message: string) JSC.JS2NativeFunctionType {
    const R = struct {
        pub fn cbb(global: *JSC.JSGlobalObject) callconv(JSC.conv) JSC.JSValue {
            const S = struct {
                fn cb(globalThis: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) callconv(JSC.conv) JSC.JSValue {
                    _ = callframe;
                    return createFn(globalThis, code, message, .{});
                }
            };
            return JSC.JSFunction.create(global, @tagName(code), S.cb, 0, .{});
        }
    };
    return R.cbb;
}
