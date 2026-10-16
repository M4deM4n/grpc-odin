package grpc

import "core:net"
import "core:time"

Transport_Error :: enum u8 {
	None,
	// No data arrived within the read poll interval; the connection is fine.
	Timeout,
	// The peer closed the connection (EOF) or it was shut down locally.
	Closed,
	// Any other failure. The connection must be abandoned.
	Failed,
}

// Transport is the byte stream a connection runs over. The default is TCP
// (tcp_transport); other implementations (e.g. TLS) can be plugged in by
// filling in these procedures.
//
// Concurrency contract, relied upon by the connection:
//   - `read` is only called by the connection's reader thread. It must
//     return .Timeout periodically (a "poll interval") when no data arrives,
//     so that the reader can notice shutdown requests.
//   - `write` is called by one thread at a time (under the write lock). It
//     writes all of buf or fails; it must not block forever on a peer that
//     stopped reading (use a send timeout and fail).
//   - `shutdown` may be called from any thread at any time, any number of
//     times, including concurrently with read/write.
//   - `close` is called exactly once, by the reader thread, after it has
//     stopped reading and while it holds the write lock.
Transport :: struct {
	data:     rawptr,
	read:     proc(data: rawptr, buf: []u8) -> (n: int, err: Transport_Error),
	write:    proc(data: rawptr, buf: []u8) -> Transport_Error,
	shutdown: proc(data: rawptr),
	close:    proc(data: rawptr),
}

// Default socket timeouts.
DEFAULT_READ_POLL :: 250 * time.Millisecond
DEFAULT_WRITE_TIMEOUT :: 30 * time.Second

// tcp_transport wraps a connected TCP socket. It disables Nagle's algorithm
// (gRPC is latency sensitive and writes whole frames) and sets the read poll
// and write timeouts. The socket handle is stored in the data pointer, so
// no allocation is needed.
tcp_transport :: proc(sock: net.TCP_Socket, read_poll := DEFAULT_READ_POLL, write_timeout := DEFAULT_WRITE_TIMEOUT) -> (t: Transport, ok: bool) {
	if net.set_option(sock, .TCP_Nodelay, true) != nil {
		return {}, false
	}
	if net.set_option(sock, .Receive_Timeout, read_poll) != nil {
		return {}, false
	}
	if net.set_option(sock, .Send_Timeout, write_timeout) != nil {
		return {}, false
	}
	return {
			data = rawptr(uintptr(sock)),
			read = tcp_read,
			write = tcp_write,
			shutdown = tcp_shutdown,
			close = tcp_close,
		},
		true
}

@(private = "file")
socket_of :: #force_inline proc "contextless" (data: rawptr) -> net.TCP_Socket {
	return net.TCP_Socket(uintptr(data))
}

@(private = "file")
tcp_read :: proc(data: rawptr, buf: []u8) -> (int, Transport_Error) {
	n, err := net.recv_tcp(socket_of(data), buf)
	if err != nil {
		if err == .Timeout {
			return 0, .Timeout
		}
		if n > 0 {
			return n, .None
		}
		return 0, .Closed
	}
	if n == 0 {
		return 0, .Closed
	}
	return n, .None
}

@(private = "file")
tcp_write :: proc(data: rawptr, buf: []u8) -> Transport_Error {
	buf := buf
	for len(buf) > 0 {
		n, err := net.send_tcp(socket_of(data), buf)
		if err != nil || n <= 0 {
			// Including send timeouts: after one the socket state is
			// unspecified (notably on Windows), so the connection is dead.
			return .Failed
		}
		buf = buf[n:]
	}
	return .None
}

@(private = "file")
tcp_shutdown :: proc(data: rawptr) {
	net.shutdown(socket_of(data), .Both)
}

@(private = "file")
tcp_close :: proc(data: rawptr) {
	net.close(socket_of(data))
}
