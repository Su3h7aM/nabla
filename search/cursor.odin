package search

import "core:fmt"
import "core:hash"
import "core:strconv"
import "core:strings"

// cursor_make issues the opaque cursor a result carries, "<generation>.<offset>.<hash>",
// where hash is the fnv64a of root as 16 lowercase hex digits. The token is a
// short check, not a secret: it names no path, and it lets cursor_parse refuse
// a cursor from another root or an older generation. Anyone can compute the
// hash from a root path, so it is not authentication. The caller owns the text,
// allocated with allocator; allocation failure is the only error.
@(require_results)
cursor_make :: proc(offset, generation: int, root: string, allocator := context.allocator) -> (cursor: string, err: Error) {
	root_buffer: [16]u8
	// Two signed 64-bit decimals, two dots, and the 16-digit hash fit in 64 bytes.
	buffer: [64]u8
	text := fmt.bprintf(buffer[:], "%d.%d.%s", generation, offset, root_hash_text(root, root_buffer[:]))
	return strings.clone(text, allocator)
}

// cursor_parse reads a cursor the caller passed back into its resume offset.
// An empty cursor starts from the first row. Anything cursor_make did not issue
// for this root is Invalid_Cursor: not exactly three dot-separated fields, a
// generation or offset that is not canonical decimal, or a hash that is not
// root's. A cursor whose generation differs from current is Stale_Cursor.
// Parsing allocates nothing and the cursor borrows the caller; allocator is
// unused and kept so the call matches cursor_make.
@(require_results)
cursor_parse :: proc(cursor, root: string, generation: int, allocator := context.allocator) -> (offset: int, err: Error) {
	if cursor == "" {
		return 0, nil
	}
	generation_text, generation_sep, rest := strings.partition(cursor, ".")
	offset_text, offset_sep, hash_text := strings.partition(rest, ".")
	if generation_sep == "" || offset_sep == "" {
		return 0, Error(Error_Code.Invalid_Cursor)
	}
	claimed_generation, generation_ok := parse_nat(generation_text)
	parsed, parsed_ok := parse_nat(offset_text)
	if !generation_ok || !parsed_ok {
		return 0, Error(Error_Code.Invalid_Cursor)
	}
	// Equality with the canonical hash text also enforces exactly 16 lowercase
	// hex digits, and it rejects any third dot left in hash_text.
	root_buffer: [16]u8
	if hash_text != root_hash_text(root, root_buffer[:]) {
		return 0, Error(Error_Code.Invalid_Cursor)
	}
	if claimed_generation != generation {
		return 0, Error(Error_Code.Stale_Cursor)
	}
	return parsed, nil
}

// root_hash_text writes the fnv64a of root into buffer as 16 lowercase hex
// digits and returns them. buffer must hold 16 bytes; the result borrows it.
@(private, require_results)
root_hash_text :: proc(root: string, buffer: []byte) -> string {
	return fmt.bprintf(buffer, "%016x", hash.fnv64a(transmute([]byte)root))
}

// page_split bounds one page of total rows at offset with limit, where zero
// or below means all. An offset outside 0..total is clamped into it. It
// returns the slice bounds and whether rows remain after the page.
@(private, require_results)
page_split :: proc(total, offset, limit: int) -> (start, end: int, has_more: bool) {
	start = clamp(offset, 0, total)
	end = total
	if limit > 0 && limit <= total - start {
		end = start + limit
	}
	return start, end, end < total
}

// parse_nat reads a canonical non-negative decimal integer: ASCII digits only,
// so no sign or underscore, no leading zero unless the value is exactly "0",
// and a value that fits int. It returns ok false for anything else.
@(private, require_results)
parse_nat :: proc(text: string) -> (value: int, ok: bool) {
	if len(text) == 0 || (len(text) > 1 && text[0] == '0') {
		return 0, false
	}
	for ch in text {
		if ch < '0' || ch > '9' {
			return 0, false
		}
	}
	number, parse_ok := strconv.parse_u64(text, 10)
	if !parse_ok || number > u64(max(int)) {
		return 0, false
	}
	return int(number), true
}

// broaden_query drops the leading word of a multi-word pattern, the retry a
// zero-hit query runs before the fuzzy pass. It borrows text and reports
// whether a shorter query exists.
@(private, require_results)
broaden_query :: proc(text: string) -> (shortened: string, ok: bool) {
	rest := strings.trim_space(text)
	word_end := 0
	for word_end < len(rest) && rest[word_end] != ' ' && rest[word_end] != '\t' {
		word_end += 1
	}
	if word_end >= len(rest) {
		return "", false
	}
	shortened = strings.trim_space(rest[word_end:])
	if shortened == "" {
		return "", false
	}
	return shortened, true
}
