package client

import "core:mem"
import "core:net"
import "core:strings"

import "nabla:dns"

// resolve_addresses returns every usable address for hostname, IPv4 before
// IPv6: the A records in answer order, then the AAAA records. The hosts file
// is consulted before any nameserver, so local names resolve without one.
// Cancellation ends the lookup; every other failure only empties the result,
// and the caller reports an empty result as unresolvable. Resolution runs on
// the calling thread, so an interrupted lookup owns nothing that outlives it.
resolve_addresses :: proc(hostname: string, options: Options, allocator: mem.Allocator) -> (addresses: [dynamic]net.Address, err: Error) {
	addresses.allocator = allocator
	if host, ok := dns.hosts_lookup(hostname, allocator); ok {
		append(&addresses, host)
		return addresses, .None
	}
	if !net.validate_hostname(hostname) { return addresses, .None }

	servers := options.nameservers
	owned := false
	if len(servers) == 0 {
		loaded, loaded_ok := dns.system_nameservers(allocator)
		if !loaded_ok { return addresses, .None }
		servers = loaded
		owned = true
	}
	defer if owned { delete(servers, allocator) }
	if len(servers) == 0 { return addresses, .None }

	probe := options.probe
	for kind in ([2]net.DNS_Record_Type{net.DNS_Record_Type.DNS_TYPE_A, net.DNS_Record_Type.DNS_TYPE_AAAA}) {
		records, query_err := dns.lookup(
			hostname,
			kind,
			dns.Options{servers = servers, interrupt = {check = dns_interrupt_check, user_data = &probe}},
			allocator,
		)
		if query_err == .Cancelled {
			delete(addresses)
			return nil, error_from_stop(stop_from_wait(probe_now(options.probe)))
		}
		if query_err != .None { continue }
		defer net.destroy_dns_records(records, allocator)
		for record in records {
			#partial switch value in record {
			case net.DNS_Record_IP4:
				append(&addresses, value.address)
			case net.DNS_Record_IP6:
				append(&addresses, value.address)
			}
		}
	}
	return addresses, .None
}

// dns_interrupt_check adapts the request probe to the resolver's stop policy:
// any probe state but Ready stops the lookup. The resolver reports the stop
// as Cancelled, and the caller re-reads its own probe for the specific cause.
dns_interrupt_check :: proc(user_data: rawptr) -> bool {
	probe := (^Probe)(user_data)
	return probe_now(probe^) != .Ready
}

// host_and_port splits an authority into its name and port. A bracketed IPv6
// literal carries its port outside the brackets; any other authority with more
// than one colon is a bare IPv6 literal with no port.
host_and_port :: proc(authority: string) -> (host: string, port: int, ok: bool) {
	if authority == "" { return "", 0, false }
	if authority[0] == '[' {
		end := strings.index_byte(authority, ']')
		if end < 0 { return "", 0, false }
		host = authority[1:end]
		rest := authority[end + 1:]
		if rest == "" { return host, 0, true }
		if rest[0] != ':' { return "", 0, false }
		port, ok = parse_port(rest[1:])
		return
	}
	colons := 0
	for byte in authority { if byte == ':' { colons += 1 } }
	if colons > 1 { return authority, 0, true }
	if colon := strings.index_byte(authority, ':'); colon >= 0 {
		port, ok = parse_port(authority[colon + 1:])
		return authority[:colon], port, ok
	}
	return authority, 0, true
}

parse_port :: proc(text: string) -> (int, bool) {
	if text == "" { return 0, false }
	port := 0
	for byte in text {
		if byte < '0' || byte > '9' { return 0, false }
		port = port * 10 + int(byte - '0')
		if port > 65535 { return 0, false }
	}
	return port, port > 0
}
