package httpclient

import "core:mem"
import "core:net"
import "core:strings"

// tls_client_ctx_new builds a verifying client context. Without a trusted store
// nothing can be verified, so the call fails instead of continuing.
tls_client_ctx_new :: proc(ca_file: string, allocator: mem.Allocator) -> (ctx: ^SSL_CTX, err: Error) {
	method := TLS_client_method()
	if method == nil { return nil, .TLS_Config }
	ctx = SSL_CTX_new(method)
	if ctx == nil { return nil, .TLS_Config }
	if SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION) == 0 {
		SSL_CTX_free(ctx)
		return nil, .TLS_Config
	}
	SSL_CTX_set_verify(ctx, VERIFY_PEER, nil)
	SSL_CTX_set_verify_depth(ctx, 10)
	if ca_file != "" {
		path := strings.clone_to_cstring(ca_file, allocator)
		defer delete(path, allocator)
		if SSL_CTX_load_verify_locations(ctx, path, nil) != 1 {
			SSL_CTX_free(ctx)
			return nil, .TLS_Trust
		}
	} else if SSL_CTX_set_default_verify_paths(ctx) != 1 {
		SSL_CTX_free(ctx)
		return nil, .TLS_Trust
	}
	return ctx, .None
}

// tls_set_peer_identity binds the handshake to the requested endpoint. SNI is
// routing information, so it carries only the DNS name; an IP endpoint is
// verified through OpenSSL's IP rules instead.
tls_set_peer_identity :: proc(ssl: ^SSL, host: string, allocator: mem.Allocator) -> Error {
	name, is_ip := host_without_port(host)
	if name == "" { return .TLS_Hostname }
	c_name := strings.clone_to_cstring(name, allocator)
	defer delete(c_name, allocator)
	if is_ip {
		param := SSL_get0_param(ssl)
		if param == nil || X509_VERIFY_PARAM_set1_ip_asc(param, c_name) != 1 { return .TLS_Hostname }
		return .None
	}
	if SSL_set_tlsext_host_name(ssl, c_name) != 1 { return .TLS_Hostname }
	if SSL_set1_host(ssl, c_name) != 1 { return .TLS_Hostname }
	return .None
}

// ssl_peer_closed reports an unordered peer close. OpenSSL 3 reports a missing
// close_notify as an SSL error rather than an EOF, and the queue is drained so a
// stale error can never be attributed to this operation.
ssl_peer_closed :: proc() -> bool {
	closed := false
	for raw := ERR_get_error(); raw != 0; raw = ERR_get_error() {
		if (raw & ERR_REASON_MASK) == SSL_R_UNEXPECTED_EOF_WHILE_READING { closed = true }
	}
	return closed
}

// host_without_port returns the name alone, because a name that keeps its port
// can never match a certificate.
host_without_port :: proc(host: string) -> (name: string, is_ip: bool) {
	parsed, _, ok := host_and_port(host)
	if !ok { return "", false }
	return parsed, net.parse_address(parsed) != nil
}
