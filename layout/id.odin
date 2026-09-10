package layout

import "core:hash"

@(private)
FNV64_OFFSET_BASIS :: u64(0xcbf29ce484222325)

@(private)
FNV64_PRIME :: u64(0x100000001b3)

@(private)
_id_from_hash :: proc "contextless" (hash_value: u64) -> Id {
	if hash_value == 0 {
		return Id(1)
	}
	return Id(hash_value)
}

@(private)
_hash_index :: proc "contextless" (seed, index: u64) -> u64 {
	result := seed
	for byte_index in 0 ..< 8 {
		value := byte(index >> u64(byte_index * 8))
		result = (result ~ u64(value)) * FNV64_PRIME
	}
	return result
}

@(private)
_auto_id :: proc "contextless" (parent: Id, sibling_ordinal: u64) -> Id {
	seed := u64(parent)
	seed = (seed ~ u64(0xff)) * FNV64_PRIME
	return _id_from_hash(_hash_index(seed, sibling_ordinal))
}

// id hashes `label` to a stable identifier, usable across frames and call
// sites as long as the label is spelled identically. It never collides with
// the reserved zero identifier.
id :: proc "contextless" (label: string) -> Id {
	return _id_from_hash(hash.fnv64a(transmute([]byte)label))
}

// id_index derives an identifier for one element of an indexed run: repeated
// calls with the same `label` and `index` yield the same identifier, while
// different indices stay distinct.
id_index :: proc "contextless" (label: string, index: u64) -> Id {
	label_hash := hash.fnv64a(transmute([]byte)label)
	return _id_from_hash(_hash_index(label_hash, index))
}

// id_local derives an identifier scoped to the active frame's current
// declaration: the parent's identity is folded in, so the same label under
// different parents stays distinct. It must be called during a frame.
id_local :: proc(ctx: ^Context, label: string, index: u64 = 0) -> Id {
	if ctx == nil || !_context_state(ctx)._initialized || !_context_state(ctx)._frame_open {
		when ODIN_DEBUG {
			assert(false, "layout: id_local called outside an active frame")
		}
		return 0
	}
	state := _context_state(ctx)
	if state._measuring {
		when ODIN_DEBUG {
			assert(false, "layout: measurement callback reentered the active context")
		}
		_append_diagnostic(state, .Measure_Reentered, 0)
		return 0
	}
	seed := FNV64_OFFSET_BASIS
	if len(state._scopes) > 0 {
		node := state._scopes[len(state._scopes) - 1].node
		if int(node) < len(state._node_inputs) {
			if state._nodes[node].id != 0 {
				seed = u64(state._nodes[node].id)
			} else {
				seed = u64(state._node_inputs[node].private_id)
			}
		}
	}
	label_hash := hash.fnv64a(transmute([]byte)label, seed)
	result := _id_from_hash(_hash_index(label_hash, index))
	when ODIN_DEBUG {
		_remember_debug_label(ctx, result, label)
	}
	return result
}

@(private)
_id_table_probe :: proc(state: ^_Context_State, identifier: Id) -> (slot: int, found: bool, available: bool) {
	capacity := len(state._id_table)
	if capacity == 0 || identifier == 0 {
		return 0, false, false
	}
	start := int(u64(identifier) % u64(capacity))
	for probe_offset in 0 ..< capacity {
		candidate := (start + probe_offset) % capacity
		entry := state._id_table[candidate]
		if !entry.occupied {
			return candidate, false, true
		}
		if entry.id == identifier {
			return candidate, true, true
		}
	}
	return 0, false, false
}

@(private)
_id_table_insert :: proc(state: ^_Context_State, slot: int, identifier: Id, node: Node_Handle) {
	assert(slot >= 0 && slot < len(state._id_table))
	assert(!state._id_table[slot].occupied)
	state._id_table[slot] = _Id_Table_Entry {
		id       = identifier,
		node     = node,
		label    = _debug_label_for(state, identifier),
		occupied = true,
	}
	state._id_table_count += 1
	_update_high_water(state, .Id_Table, state._id_table_count)
}

@(private)
_debug_label_for :: proc(state: ^_Context_State, identifier: Id) -> string {
	when ODIN_DEBUG {
		for entry in state._debug_label_entries {
			if entry.id == identifier {
				return entry.label
			}
		}
	}
	return ""
}

@(private)
_remember_debug_label :: proc(ctx: ^Context, identifier: Id, label: string) {
	when !ODIN_DEBUG {
		return
	}
	if ctx == nil || len(label) == 0 {
		return
	}
	state := _context_state(ctx)
	if !state._initialized || !state._frame_open || !state._options.debug_labels {
		return
	}
	for entry in state._debug_label_entries {
		if entry.id == identifier {
			return
		}
	}
	if len(state._debug_label_entries) >= cap(state._debug_label_entries) || len(label) > cap(state._debug_labels) - len(state._debug_labels) {
		return
	}
	start := len(state._debug_labels)
	for value in transmute([]byte)label {
		ok := _try_append(&state._debug_labels, value)
		assert(ok)
	}
	stored_label := string(state._debug_labels[start:])
	ok := _try_append(&state._debug_label_entries, _Debug_Label_Entry{id = identifier, label = stored_label})
	assert(ok)
	_update_high_water(state, .Debug_Labels, len(state._debug_labels))
}
