// Minimal OpenSSL 3 bindings. They cover the client transport and the local TLS
// server used by the test fixture.
package httpclient

import "core:c"

foreign import lib {"system:ssl", "system:crypto"}

SSL_METHOD :: struct {}
SSL_CTX :: struct {}
SSL :: struct {}
X509_VERIFY_PARAM :: struct {}

SSL_CTRL_SET_TLSEXT_HOSTNAME :: 55
SSL_CTRL_SET_MIN_PROTO_VERSION :: 123
TLSEXT_NAMETYPE_host_name :: 0
TLS1_2_VERSION :: 0x0303

VERIFY_PEER :: 0x01
FILETYPE_PEM :: 1

SSL_ERROR_SSL :: 1
SSL_ERROR_WANT_READ :: 2
SSL_ERROR_WANT_WRITE :: 3
SSL_ERROR_SYSCALL :: 5
SSL_ERROR_ZERO_RETURN :: 6
SSL_ERROR_WANT_CONNECT :: 7
SSL_ERROR_WANT_ACCEPT :: 8

// OpenSSL 3 reports an unordered peer close as an SSL error, not an EOF.
ERR_REASON_MASK :: 0x7FFFFF
SSL_R_UNEXPECTED_EOF_WHILE_READING :: 294

foreign lib {
	TLS_client_method :: proc() -> ^SSL_METHOD ---
	TLS_server_method :: proc() -> ^SSL_METHOD ---
	SSL_CTX_new :: proc(method: ^SSL_METHOD) -> ^SSL_CTX ---
	SSL_new :: proc(ctx: ^SSL_CTX) -> ^SSL ---
	SSL_set_fd :: proc(ssl: ^SSL, fd: c.int) -> c.int ---
	SSL_connect :: proc(ssl: ^SSL) -> c.int ---
	SSL_accept :: proc(ssl: ^SSL) -> c.int ---
	SSL_get_error :: proc(ssl: ^SSL, ret: c.int) -> c.int ---
	SSL_read :: proc(ssl: ^SSL, buf: [^]byte, num: c.int) -> c.int ---
	SSL_write :: proc(ssl: ^SSL, buf: [^]byte, num: c.int) -> c.int ---
	SSL_shutdown :: proc(ssl: ^SSL) -> c.int ---
	SSL_free :: proc(ssl: ^SSL) ---
	SSL_CTX_free :: proc(ctx: ^SSL_CTX) ---
	SSL_ctrl :: proc(ssl: ^SSL, cmd: c.int, larg: c.long, parg: rawptr) -> c.long ---
	SSL_CTX_ctrl :: proc(ctx: ^SSL_CTX, cmd: c.int, larg: c.long, parg: rawptr) -> c.long ---
	SSL_CTX_set_verify :: proc(ctx: ^SSL_CTX, mode: c.int, callback: rawptr) ---
	SSL_CTX_set_verify_depth :: proc(ctx: ^SSL_CTX, depth: c.int) ---
	SSL_CTX_set_default_verify_paths :: proc(ctx: ^SSL_CTX) -> c.int ---
	SSL_CTX_load_verify_locations :: proc(ctx: ^SSL_CTX, ca_file: cstring, ca_path: cstring) -> c.int ---
	SSL_get_verify_result :: proc(ssl: ^SSL) -> c.long ---
	SSL_set1_host :: proc(ssl: ^SSL, hostname: cstring) -> c.int ---
	SSL_get0_param :: proc(ssl: ^SSL) -> ^X509_VERIFY_PARAM ---
	SSL_get_version :: proc(ssl: ^SSL) -> cstring ---
	X509_VERIFY_PARAM_set1_ip_asc :: proc(param: ^X509_VERIFY_PARAM, ip: cstring) -> c.int ---
	SSL_CTX_use_certificate_file :: proc(ctx: ^SSL_CTX, file: cstring, type: c.int) -> c.int ---
	SSL_CTX_use_PrivateKey_file :: proc(ctx: ^SSL_CTX, file: cstring, type: c.int) -> c.int ---
	SSL_CTX_check_private_key :: proc(ctx: ^SSL_CTX) -> c.int ---
	OpenSSL_version_num :: proc() -> c.ulong ---
	ERR_get_error :: proc() -> c.ulong ---
}

// SSL_set_tlsext_host_name is a macro in C.
SSL_set_tlsext_host_name :: proc(ssl: ^SSL, name: cstring) -> c.int {
	return c.int(SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, rawptr(name)))
}

SSL_CTX_set_min_proto_version :: proc(ctx: ^SSL_CTX, version: c.int) -> c.int {
	return c.int(SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, c.long(version), nil))
}
