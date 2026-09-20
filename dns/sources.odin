// Local name sources: the hosts file and the system resolver configuration.
//
// The DNS exchange in this package answers names the network knows. These
// two procedures answer what the machine already knows without asking the
// network: the hosts file first, then the configured nameservers. Keeping
// them here makes this package the single place DNS answers come from; the
// callers state only which servers to ask and how long to wait.
package dns

import "core:mem"
import "core:net"
import "core:os"
import "core:strings"

// hosts_lookup consults the hosts file before any nameserver, so local names
// resolve without one.
hosts_lookup :: proc(hostname: string, allocator: mem.Allocator) -> (address: net.Address, found: bool) {
	handle, open_err := os.open(net.dns_configuration.hosts_file)
	if open_err != nil { return nil, false }
	defer os.close(handle)

	hosts, ok := net.parse_hosts(os.to_stream(handle), allocator)
	defer {
		for entry in hosts { delete(entry.name, allocator) }
		delete(hosts, allocator)
	}
	if !ok { return nil, false }

	var_ip4: net.IP4_Address
	var_ip6: net.IP6_Address
	has_ip4, has_ip6 := false, false
	for entry in hosts {
		if !strings.equal_fold(entry.name, hostname) { continue }
		#partial switch value in entry.addr {
		case net.IP4_Address:
			if !has_ip4 {
				var_ip4 = value
				has_ip4 = true
			}
		case net.IP6_Address:
			if !has_ip6 {
				var_ip6 = value
				has_ip6 = true
			}
		}
	}
	if has_ip4 { return var_ip4, true }
	if has_ip6 { return var_ip6, true }
	return nil, false
}

// system_nameservers reads the caller's nameservers from the system resolver
// configuration. The result is owned by the caller.
system_nameservers :: proc(allocator: mem.Allocator) -> ([]net.Endpoint, bool) {
	contents, read_err := os.read_entire_file(net.dns_configuration.resolv_conf, allocator)
	if read_err != nil { return nil, false }
	defer delete(contents, allocator)
	return net.parse_resolv_conf(string(contents), allocator), true
}
