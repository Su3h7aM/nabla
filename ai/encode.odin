package ai

import "core:io"
import "core:mem"
import "core:strings"

// The OpenAI adapters write a request body as bytes rather than building a JSON value
// and writing that out. A conversation is mostly text the request carries again: the
// instruction prefix, every tool schema, every tool result, and every response record
// the endpoint sent. A value built from that text is cloned and freed on every send,
// while the text itself rarely changed.
//
// What repeats is kept. A slot is one text and the exact bytes it was written as, and
// every string the adapters put on the wire passes through one: a quoted literal, a
// tool's parameters, or a response record's items. The cache is an accelerator and
// never a source of truth, because bytes are reused only when the text they were
// written for is the text the request carries now. A body encoded with a cache is
// therefore byte for byte the body encoded without one: the cache decides how much
// work repeats, never what is sent.
//
// A zero cache holds nothing and needs no initialization. One cache is walked by one
// encode at a time, so a caller that encodes on a second thread passes a cache of its own
// or none at all.
Provider_Encode_Cache :: struct {
	// allocator is what everything this cache holds was allocated with. The first encode
	// that fills it fixes one, and every later encode and the destroy use it, so a cache
	// never mixes two allocators and cannot free what another allocated.
	allocator:  mem.Allocator,
	slots:      [dynamic]Encode_Slot,
	// body_bytes is how large the last body this cache encoded was. The next body carries
	// nearly the same bytes, so this is what it is given room for to start with. It is a
	// size to guess with, never a fact the encoding depends on: a body that outgrows it is
	// written all the same.
	body_bytes: int,
}

// How much larger than the body before it a body is expected to be. Between two requests a
// conversation grows by one turn: the messages and records the turn added, which are small
// next to the history that already sits in the cache. A body that outgrows the room it was
// given pays one grow, and doubling carries it past the rest of the turn.
@(private = "package")
ENCODE_BODY_GROWTH_DIVISOR :: 8

// The floor under that growth, for the first body after a small one and for a cache whose
// body_bytes is still zero.
@(private = "package")
ENCODE_BODY_GROWTH_FLOOR :: 4096

// Encode_Slot is one text and the bytes it was written as.
@(private = "package")
Encode_Slot :: struct {
	// text is the request text these bytes were written for, owned here.
	text:    string,
	// bytes is what that text was written as: a quoted literal, a tool's
	// parameters, or one response record's items.
	bytes:   strings.Builder,
	// kind is what those bytes are. A text means one thing in one position and
	// another in another, so bytes written as one kind never answer for another,
	// even where the texts are equal.
	kind:    Encode_Text_Kind,
	// written says bytes was written for text. A slot that was never written holds
	// nothing, which is not the same as being written for empty text.
	written: bool,
	// ok is the verdict the check at this position gave for text: a tool schema is
	// an object the wire can carry, a response record's items are replayable. It is
	// a property of the text, so it holds for as long as the text does.
	ok:      bool,
}

// Encode_Text_Kind is what the bytes written for one text are.
@(private = "package")
Encode_Text_Kind :: enum {
	// Literal is a request's text as the JSON string it goes on the wire as.
	Literal,
	// Parameters is a tool's own schema, as the object the wire carries.
	Parameters,
	// Record is one response record the endpoint sent, as the items it replays as.
	Record,
}

// Encode_Cursor walks a cache in step with one request. The adapters take a slot for
// every text they write, in the order the request carries them, so the n-th text of
// this request meets the n-th text of the previous one.
@(private = "package")
Encode_Cursor :: struct {
	cache: ^Provider_Encode_Cache,
	next:  int,
}

@(private = "package")
encode_cursor :: proc(cache: ^Provider_Encode_Cache, allocator := context.allocator) -> Encode_Cursor {
	// The allocator a cache is first filled with becomes its own: everything it holds
	// answers with it for the rest of the session, so a later encode that is handed a
	// different allocator cannot free what another provided.
	if cache != nil && cache.allocator.procedure == nil {
		cache.allocator = allocator
		cache.slots.allocator = allocator
	}
	return Encode_Cursor{cache = cache}
}

// encode_slot_for returns the slot this text is written to and whether it already holds
// the bytes for it. A slot that holds another text, or the same text written as something
// else, is released before it is written again. A nil slot means there is no cache: the
// caller writes the bytes itself.
@(private = "package")
encode_slot_for :: proc(cursor: ^Encode_Cursor, text: string, kind: Encode_Text_Kind) -> (slot: ^Encode_Slot, hit: bool) {
	if cursor.cache == nil { return nil, false }
	allocator := cursor.cache.allocator
	slots := &cursor.cache.slots
	if cursor.next >= len(slots) {
		append(slots, Encode_Slot{})
		strings.builder_init(&slots[len(slots) - 1].bytes, allocator)
	}
	slot = &slots[cursor.next]
	cursor.next += 1
	if slot.written && slot.kind == kind && slot.text == text { return slot, true }
	if slot.written {
		delete(slot.text, allocator)
		strings.builder_reset(&slot.bytes)
		slot.text = ""
		slot.written = false
		slot.ok = false
	}
	slot.kind = kind
	return slot, false
}

// encode_slot_store records the text a slot's bytes were written for. The bytes it
// holds now answer for that text from here on.
@(private = "package")
encode_slot_store :: proc(cursor: ^Encode_Cursor, slot: ^Encode_Slot, text: string) {
	slot.text = strings.clone(text, cursor.cache.allocator)
	slot.written = true
}

// encode_finish drops the slots this request did not reach. A request that carries less
// than the one before it leaves nothing behind.
@(private = "package")
encode_finish :: proc(cursor: ^Encode_Cursor) {
	if cursor.cache == nil { return }
	slots := &cursor.cache.slots
	for i := cursor.next; i < len(slots); i += 1 { encode_slot_destroy(&slots[i], cursor.cache.allocator) }
	resize(slots, cursor.next)
}

// encode_body_make starts one request body. Most of a body is bytes this cache already
// holds, so the size of the body before it is a close guess at this one's: starting there
// is one allocation instead of the sequence a builder takes to double its way up.
@(private = "package")
encode_body_make :: proc(cursor: ^Encode_Cursor, allocator: mem.Allocator) -> strings.Builder {
	hint := cursor.cache == nil ? 0 : cursor.cache.body_bytes
	if hint <= 0 { return strings.builder_make(allocator) }
	return strings.builder_make_len_cap(0, hint + hint / ENCODE_BODY_GROWTH_DIVISOR + ENCODE_BODY_GROWTH_FLOOR, allocator)
}

// encode_body_store records how large the body just written was. The next body starts from
// it, so what a growing conversation costs is the new turn's bytes rather than all of it.
@(private = "package")
encode_body_store :: proc(cursor: ^Encode_Cursor, body: ^strings.Builder) {
	if cursor.cache == nil { return }
	cursor.cache.body_bytes = len(body.buf)
}

@(private = "package")
encode_slot_destroy :: proc(slot: ^Encode_Slot, allocator: mem.Allocator) {
	delete(slot.text, allocator)
	strings.builder_destroy(&slot.bytes)
	slot^ = {}
}

// Provider_Encode_Cache_Destroy releases everything the cache holds. A zero cache holds
// nothing, so destroying one is harmless.
Provider_Encode_Cache_Destroy :: proc(cache: ^Provider_Encode_Cache) {
	if cache == nil { return }
	for &slot in cache.slots { encode_slot_destroy(&slot, cache.allocator) }
	delete(cache.slots)
	cache^ = {}
}

// --- writing one body --------------------------------------------------------

// encode_write_raw writes bytes that are the body's own: punctuation, a field name, a
// number. Text the request carries goes through encode_write_text, so what is reused and
// what is written is visible where it is written.
@(private = "package")
encode_write_raw :: proc(body: ^strings.Builder, text: string) {
	strings.write_string(body, text)
}

// encode_write_field starts one field of the object being written, adding the comma the
// previous field needs. Names are literals this package writes, so they are never
// escaped, and they are written in the order the standard library's writer would sort
// them in: a body is stable across requests and across processes.
@(private = "package")
encode_write_field :: proc(body: ^strings.Builder, first: ^bool, name: string) {
	if !first^ { strings.write_byte(body, ',') }
	first^ = false
	strings.write_byte(body, '"')
	strings.write_string(body, name)
	encode_write_raw(body, "\":")
}

// encode_write_literal_string writes a JSON string this package chose, such as a role
// or a name for a value it decided. Nothing in it needs escaping.
@(private = "package")
encode_write_literal_string :: proc(body: ^strings.Builder, text: string) {
	strings.write_byte(body, '"')
	strings.write_string(body, text)
	strings.write_byte(body, '"')
}

@(private = "package")
encode_write_int :: proc(body: ^strings.Builder, value: int) {
	strings.write_int(body, value)
}

@(private = "package")
encode_write_bool :: proc(body: ^strings.Builder, value: bool) {
	strings.write_string(body, value ? "true" : "false")
}

// encode_write_quoted writes text as the JSON string it is, with the standard
// library's own escaping, so the bytes are the ones a parsed value would be written as.
@(private = "package")
encode_write_quoted :: proc(builder: ^strings.Builder, text: string) {
	io.write_quoted_string(strings.to_writer(builder), text, '"', nil, true)
}

// encode_write_text writes the JSON string a request's text goes on the wire as,
// reusing the slot that already holds it. Text that did not change is copied rather
// than written again.
@(private = "package")
encode_write_text :: proc(cursor: ^Encode_Cursor, body: ^strings.Builder, text: string) {
	slot, hit := encode_slot_for(cursor, text, .Literal)
	if slot == nil {
		encode_write_quoted(body, text)
		return
	}
	if !hit {
		encode_write_quoted(&slot.bytes, text)
		slot.ok = true
		encode_slot_store(cursor, slot, text)
	}
	strings.write_string(body, strings.to_string(slot.bytes))
}
