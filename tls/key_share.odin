package tls

import "core:crypto/ecdh"

// OFFERED_GROUPS is the key exchange groups this client offers, in preference order.
// RFC 8446 section 9.1 makes secp256r1 mandatory to implement, and a peer that
// supports only it answers a share for x25519 with a HelloRetryRequest.
OFFERED_GROUPS := [2]Named_Group{.X25519, .SECP256R1}

// KEY_SHARE_MAX is the largest share this client sends: an uncompressed secp256r1
// point, which is 65 octets (RFC 8446 section 4.2.8.1).
KEY_SHARE_MAX :: 65

// SHARED_SECRET_MAX is the largest shared secret these groups produce, which is the
// x-coordinate of the shared point in both cases (RFC 8446 section 7.4.2).
SHARED_SECRET_MAX :: 32

// Key_Exchange is one group's private key and the share that carries its public half.
// The share is what a ClientHello sends and the secret is what the key schedule is
// extracted from.
Key_Exchange :: struct {
	group:   Named_Group,
	private: ecdh.Private_Key,
	share:   [KEY_SHARE_MAX]u8,
	length:  int,
}

// key_exchange_generate prepares the exchange for one group and writes the share that
// goes in a ClientHello.
key_exchange_generate :: proc(exchange: ^Key_Exchange, group: Named_Group) -> bool {
	curve: ecdh.Curve
	switch group {
	case .X25519:
		curve = .X25519
	case .SECP256R1:
		curve = .SECP256R1
	case:
		return false
	}
	if !ecdh.private_key_generate(&exchange.private, curve) { return false }

	public: ecdh.Public_Key
	ecdh.public_key_set_priv(&public, &exchange.private)
	length := ecdh.key_size(&public)
	if length > KEY_SHARE_MAX || ecdh.shared_secret_size(&public) > SHARED_SECRET_MAX { return false }
	ecdh.public_key_bytes(&public, exchange.share[:length])
	exchange.group = group
	exchange.length = length
	return true
}

// key_exchange_shared computes the shared secret with the peer's share. A share that is
// not a point of this group, or one the group refuses, yields nothing: x25519 gives no
// secret for a share of small order, and secp256r1 has no such point.
key_exchange_shared :: proc(exchange: ^Key_Exchange, peer_share: []u8, secret: []u8) -> bool {
	peer: ecdh.Public_Key
	if !ecdh.public_key_set_bytes(&peer, ecdh.curve(&exchange.private), peer_share) { return false }
	size := ecdh.shared_secret_size(&peer)
	if len(secret) < size { return false }
	return ecdh.ecdh(&exchange.private, &peer, secret[:size])
}
