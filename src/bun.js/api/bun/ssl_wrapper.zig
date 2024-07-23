const bun = @import("root").bun;

const BoringSSL = bun.BoringSSL;
const X509 = @import("./x509.zig");
const JSC = bun.JSC;
const uws = bun.uws;

/// Mimics the behavior of openssl.c in uSockets, wrapping data that can be received from any where (network, DuplexStream, etc)
pub fn SSLWrapper(T: type) type {
    // receiveData() is called when we receive data from the network (encrypted data that will be decrypted by SSLWrapper)
    // writeData() is called when we want to send data to the network (unencrypted data that will be encrypted by SSLWrapper)

    // after init we need to call start() to start the SSL handshake
    // this will trigger the onOpen callback before the handshake starts and the onHandshake callback after the handshake completes
    // onRead and onWrite callbacks are triggered when we have data to read or write respectively
    // onRead will pass the decrypted data that we received from the network
    // onWrite will pass the encrypted data that we want to send to the network
    // onClose callback is triggered when we wanna the network connection to be closed (remember to flush the data before closing the connection)

    // Notes:
    // SSL_read() read unencrypted data which is stored in the input BIO.
    // SSL_write() write unencrypted data into the output BIO.
    // BIO_write() write encrypted data into the input BIO.
    // BIO_read() read encrypted data from the output BIO.

    return struct {
        const This = @This();

        handlers: Handlers,
        ssl: *BoringSSL.SSL,
        input: *BoringSSL.BIO,
        output: *BoringSSL.BIO,
        ctx: *BoringSSL.SSL_CTX,

        flags: Flags = .{},

        pub const Flags = packed struct {
            handshake_state: HandshakeState = HandshakeState.HANDSHAKE_PENDING,
            received_ssl_shutdown: bool = false,
            is_client: bool = false,
        };
        pub const HandshakeState = enum(u8) {
            HANDSHAKE_PENDING = 0,
            HANDSHAKE_COMPLETED = 1,
            HANDSHAKE_RENEGOTIATION_PENDING = 2,
        };
        pub const Handlers = struct {
            ctx: T,
            onOpen: fn (T, *This) void,
            onHandshake: fn (T, *This, bool, uws.us_bun_verify_error_t) void,
            onWrite: fn (T, *This, []const u8) void,
            onRead: fn (T, *This, []const u8) void,
            onClose: fn (T) void,
        };
        pub fn init(ssl_options: JSC.API.ServerConfig.SSLConfig, is_client: bool, handlers: Handlers) ?This {
            BoringSSL.load();

            const ctx_opts: uws.us_bun_socket_context_options_t = JSC.API.ServerConfig.SSLConfig.asUSockets(ssl_options);
            // Create SSL context using uSockets to match behavior of node.js
            const ctx = uws.create_ssl_context_from_bun_options(ctx_opts) orelse return null; // invalid options
            const ssl = BoringSSL.SSL_new(ctx) orelse bun.outOfMemory();
            if (is_client) {
                // Set the renegotiation mode to explicit so that we can renegotiate on the client side if needed (better performance than ssl_renegotiate_freely)
                BoringSSL.SSL_set_renegotiate_mode(ssl, BoringSSL.ssl_renegotiate_explicit);
                BoringSSL.SSL_set_connect_state(ssl);
            } else {
                // Set the renegotiation mode to never so that we can't renegotiate on the server side (security reasons)
                BoringSSL.SSL_set_renegotiate_mode(ssl, BoringSSL.ssl_renegotiate_never);
                BoringSSL.SSL_set_accept_state(ssl);
            }
            const input = BoringSSL.BIO_new(BoringSSL.BIO_s_mem()) orelse bun.outOfMemory();
            const output = BoringSSL.BIO_new(BoringSSL.BIO_s_mem()) orelse bun.outOfMemory();
            // Set the EOF return value to -1 so that we can detect when the BIO is empty using BIO_ctrl_pending
            BoringSSL.BIO_set_mem_eof_return(input, -1);
            BoringSSL.BIO_set_mem_eof_return(output, -1);

            BoringSSL.SSL_set_bio(ssl, input, output);

            return .{
                .handlers = handlers,
                .flags = .{.is_client},
                .ctx = ctx,
                .ssl = ssl,
                .input = input,
                .output = output,
            };
        }

        pub fn start(this: *This) void {
            // trigger the onOpen callback so the user can configure the SSL connection before first handshake
            this.handlers.onOpen(this.handlers.ctx, this);
            // start the handshake
            this.handleTraffic();
        }

        fn triggerHandshakeCallback(this: *This, success: bool, result: uws.us_bun_verify_error_t) void {
            // trigger the handshake callback
            this.handlers.onHandshake(this.handlers.ctx, this, success, result);
        }

        fn triggerWannaWriteCallback(this: *This, data: []const u8) void {
            // trigger the onWrite callback
            this.handlers.onWrite(this.handlers.ctx, this, data);
        }

        fn triggerReadCallback(this: *This, data: []const u8) void {
            // trigger the onRead callback
            this.handlers.onRead(this.handlers.ctx, this, data);
        }

        fn triggerCloseCallback(this: *This) void {
            // trigger the onClose callback
            this.handlers.onClose(this.handlers.ctx);
        }

        fn getVerifyError(this: *This) uws.us_bun_verify_error_t {
            if (this.flags.received_ssl_shutdown == true) {
                return .{};
            }
            return uws.us_bun_verify_error_t(this.ssl);
        }
        /// Update the handshake state
        /// Returns true if we can call handleReading
        fn updateHandshakeState(this: *This) bool {
            if (BoringSSL.SSL_is_init_finished(this.ssl)) {
                // handshake already completed nothing to do here
                if (BoringSSL.SSL_get_shutdown(this.ssl) & BoringSSL.SSL_RECEIVED_SHUTDOWN) {
                    // we received a shutdown
                    this.flags.received_ssl_shutdown = true;
                    this.triggerCloseCallback();
                }
                return false;
            }

            const result = BoringSSL.SSL_do_handshake(this.ssl);

            if (BoringSSL.SSL_get_shutdown(this.ssl) & BoringSSL.SSL_RECEIVED_SHUTDOWN) {
                this.flags.received_ssl_shutdown = true;
                this.flags.handshake_state = HandshakeState.HANDSHAKE_COMPLETED;
                this.triggerHandshakeCallback(false, this.getVerifyError());
                this.triggerCloseCallback();
                return false;
            }

            if (result <= 0) {
                const err = BoringSSL.SSL_get_error(this.ssl, result);
                // as far as I know these are the only errors we want to handle
                if (err != BoringSSL.SSL_ERROR_WANT_READ and err != BoringSSL.SSL_ERROR_WANT_WRITE) {
                    this.flags.handshake_state = HandshakeState.HANDSHAKE_COMPLETED;

                    this.flags.handshake_state = HandshakeState.HANDSHAKE_COMPLETED;
                    this.triggerHandshakeCallback(true, this.getVerifyError());

                    // clear per thread error queue if it may contain something
                    if (err == BoringSSL.SSL_ERROR_SSL or err == BoringSSL.SSL_ERROR_SYSCALL) {
                        BoringSSL.ERR_clear_error();
                    }
                    return true;
                }
                this.flags.handshake_state = HandshakeState.HANDSHAKE_PENDING;
                // ensure that we'll cycle through internal openssl's state
                this.writeData("");
                return true;
            }

            // handshake completed
            this.flags.handshake_state = HandshakeState.HANDSHAKE_COMPLETED;
            this.triggerHandshakeCallback(true, this.getVerifyError());

            // ensure that we'll cycle through internal openssl's state
            this.writeData("");

            return true;
        }

        /// Handle the end of a renegotiation if it was pending
        /// This function is called when we receive a SSL_ERROR_ZERO_RETURN or successfully read data
        fn handleEndOfRenegociation(this: *This) void {
            if (this.flags.handshake_state == HandshakeState.HANDSHAKE_RENEGOTIATION_PENDING) {
                // renegotiation ended successfully call on_handshake
                this.flags.handshake_state = HandshakeState.HANDSHAKE_COMPLETED;
                this.triggerHandshakeCallback(true, this.getVerifyError());
            }
        }

        /// Handle reading data
        /// Returns true if we can call handleWriting
        fn handleReading(this: *This) bool {
            // handle reading
            var buffer: [16384]u8 = undefined;
            var read: usize = 0;
            // read data from the input BIO
            while (BoringSSL.BIO_ctrl_pending(this.input) > 0) {
                const available = buffer[read..];
                const just_read = BoringSSL.SSL_read(this.ssl, available.ptr, available.len);

                if (just_read <= 0) {
                    const err = BoringSSL.SSL_get_error(this.ssl, just_read);
                    if (err != BoringSSL.SSL_ERROR_WANT_READ and err != BoringSSL.SSL_ERROR_WANT_WRITE) {
                        if (err == BoringSSL.SSL_ERROR_WANT_RENEGOTIATE) {
                            this.flags.handshake_state = HandshakeState.HANDSHAKE_RENEGOTIATION_PENDING;
                            this.flags.handshake_state = HandshakeState.HANDSHAKE_RENEGOTIATION_PENDING;
                            if (!BoringSSL.SSL_renegotiate(this.ssl)) {
                                this.flags.handshake_state = HandshakeState.HANDSHAKE_COMPLETED;
                                // we failed to renegotiate
                                this.triggerHandshakeCallback(false, this.getVerifyError());
                                this.triggerCloseCallback();
                                return false;
                            }
                            // ok, we are done here, we need to call SSL_read again
                            // this dont mean that we are done with the handshake renegotiation
                            // we need to call SSL_read again
                            continue;
                        } else if (err == BoringSSL.SSL_ERROR_ZERO_RETURN) {
                            // zero return can be EOF/FIN, if we have data just signal on_data and close
                            this.flags.received_ssl_shutdown = true;
                            this.handleEndOfRenegociation();
                        }

                        // flush the reading
                        if (read > 0) {
                            this.triggerReadCallback(buffer[0..read]);
                        }
                        BoringSSL.ERR_clear_error();
                        this.triggerCloseCallback();
                        return false;
                    } else {
                        // we wanna read/write just break
                        break;
                    }
                }

                this.handleEndOfRenegociation();

                read += just_read;
                if (read == buffer.len) {
                    // we filled the buffer
                    this.triggerReadCallback(buffer[0..read]);
                    read = 0;
                }
            }
            // we finished reading
            if (read > 0) {
                this.triggerReadCallback(buffer[0..read]);
            }
            return true;
        }

        fn handleWriting(this: *This) void {
            var buffer: [16384]u8 = undefined;
            while (true) {
                // read data from the output BIO
                const pending = BoringSSL.BIO_ctrl_pending(this.output);
                if (pending <= 0) {
                    // no data to write
                    break;
                }
                // limit the read to the buffer size
                const len = @min(pending, buffer.len);
                const pending_buffer = buffer[0..len];
                const read = BoringSSL.BIO_read(this.output, pending_buffer.ptr, len);
                if (read > 0) {
                    this.triggerWannaWriteCallback(buffer[0..read]);
                }
            }
        }

        fn handleTraffic(this: *This) void {
            if (this.updateHandshakeState()) {
                if (this.handleReading()) {
                    // we may have data to write
                    this.handleWriting();
                }
            }
        }

        // Receive data from the network (encrypted data)
        pub fn receiveData(this: *This, data: []const u8) void {
            const written = BoringSSL.BIO_write(this.input, data.ptr, @as(c_int, @intCast(data.len)));
            if (written > -1) {
                this.handleTraffic();
            }
        }

        // Send data to the network (unencrypted data)
        pub fn writeData(this: *This, data: []const u8) usize {
            if (data.len == 0) {
                // just cycle through internal openssl's state
                _ = BoringSSL.SSL_write(this.ssl, data.ptr, @as(c_int, @intCast(data.len)));
                this.handleTraffic();
                return 0;
            }
            const written = BoringSSL.SSL_write(this.ssl, data.ptr, @as(c_int, @intCast(data.len)));
            if (written <= 0) {
                const err = BoringSSL.SSL_get_error(this.ssl, written);
                if (err == BoringSSL.SSL_ERROR_WANT_READ or err == BoringSSL.SSL_ERROR_WANT_WRITE) {
                    // we wanna read/write
                    this.handleTraffic();
                    return 0;
                }
                // some bad error happened here we must close
                BoringSSL.ERR_clear_error();
                this.triggerCloseCallback();
                return 0;
            }
            this.handleTraffic();
            return @intCast(written);
        }

        pub fn deinit(this: *This) void {
            // Free everything
            _ = BoringSSL.SSL_free(this.ssl);
            _ = BoringSSL.BIO_free(this.input);
            _ = BoringSSL.BIO_free(this.output);
            _ = BoringSSL.SSL_CTX_free(this.ctx);
        }
    };
}
