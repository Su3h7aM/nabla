#+private
package markdown

import "base:runtime"
import "core:mem"
import "core:strings"

// Inline_Token is one run of a paragraph line with the style and link
// destination the inline parser gives it. An empty text is a token that is not
// rendered: it was a dropped bracket, or the consumed part of a delimiter run.
Inline_Token :: struct {
	text:  string,
	url:   string,
	style: Style,
}

// Delimiter_Kind is the repeated character of a delimiter run.
Delimiter_Kind :: enum u8 {
	Star,
	Underscore,
	Tilde,
}

// DELIMITER_KIND_COUNT counts the delimiter kinds, so a kind's ordinal indexes
// the openers_bottom table of one process_emphasis call.
DELIMITER_KIND_COUNT :: int(Delimiter_Kind.Tilde) + 1

// OPENERS_BOTTOM_COUNT counts the openers_bottom buckets of one delimiter kind:
// the closing run's length modulo three, and whether it can also open.
OPENERS_BOTTOM_COUNT :: 6

// AUTOLINK_SCHEME_MIN and AUTOLINK_SCHEME_MAX bound the scheme of an autolink,
// counted without the colon.
AUTOLINK_SCHEME_MIN :: 2
AUTOLINK_SCHEME_MAX :: 32

// Inline_Delimiter is one run of `*`, `_`, or `~` on the delimiter stack.
Inline_Delimiter :: struct {
	token:     int,
	kind:      Delimiter_Kind,
	active:    bool,
	can_open:  bool,
	can_close: bool,
}

// Inline_Bracket is one `[` or `![` on the bracket stack. delimiters is the
// length of the delimiter stack when it was pushed, which bounds the emphasis
// that can be processed inside it.
Inline_Bracket :: struct {
	token:      int,
	delimiters: int,
	active:     bool,
}

// Inline_Parser is the scratch state of one parse_inlines call: the tokens found
// so far, the delimiter and bracket stacks that index them, and the line the
// scanner works through.
Inline_Parser :: struct {
	tokens:       [dynamic]Inline_Token,
	delimiters:   [dynamic]Inline_Delimiter,
	brackets:     [dynamic]Inline_Bracket,
	link_matches: [dynamic]int,
	line:         string,
	position:     int,
}

// parse_inlines parses the lines of one paragraph, heading, or table cell, which
// carry no container prefix, no leading whitespace, and their trailing
// whitespace, and returns their flattened spans. Every text and url of a span is
// a view into lines, except the soft break " " and the hard break "\n", so lines
// must outlive the spans. The spans are one allocation from allocator and are
// freed with delete(spans, allocator); the only error is allocation failure, and
// it leaves nothing allocated from allocator.
@(require_results)
parse_inlines :: proc(lines: []string, allocator: mem.Allocator) -> (spans: []Span, err: mem.Allocator_Error) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD(ignore = allocator == context.temp_allocator)

	parser := Inline_Parser {
		tokens       = make([dynamic]Inline_Token, context.temp_allocator),
		delimiters   = make([dynamic]Inline_Delimiter, context.temp_allocator),
		brackets     = make([dynamic]Inline_Bracket, context.temp_allocator),
		link_matches = make([dynamic]int, context.temp_allocator),
	}

	for line, index in lines {
		last := index == len(lines) - 1
		content := strings.trim_right(line, " ")
		hard_break := len(line) - len(content) >= 2
		if last {
			// nothing follows the last line, so no whitespace of it is text
			content = strings.trim_right(content, SPACE_TAB)
		}
		backslash_break := scan_line(&parser, content, !last) or_return
		if last { continue }
		if hard_break || backslash_break {
			add_token(&parser, "\n") or_return
		} else {
			add_token(&parser, " ", {.Soft_Break}) or_return
		}
	}

	// emphasis covers the whole paragraph, across its line breaks
	process_emphasis(parser.tokens[:], parser.delimiters[:], 0)

	spans = make([]Span, span_count(parser.tokens[:]), allocator) or_return
	spans_from_tokens(spans, parser.tokens[:])
	return
}

// scan_line parses one line into tokens and reports whether it ends in the
// backslash of a hard break, which is not text. breakable_backslash is false on
// the last line of a paragraph, where a trailing backslash is literal.
@(require_results)
scan_line :: proc(parser: ^Inline_Parser, line: string, breakable_backslash: bool) -> (hard_break: bool, err: mem.Allocator_Error) {
	_ = resize(&parser.link_matches, 0)
	parser.line = line
	parser.position = 0
	for parser.position < len(line) {
		position := parser.position
		switch line[position] {
		case '\\':
			if position + 1 == len(line) {
				if breakable_backslash {
					parser.position += 1
					hard_break = true
					continue
				}
			} else if is_punctuation_byte(line[position + 1]) {
				add_token(parser, line[position + 1:position + 2]) or_return
				parser.position += 2
				continue
			}
			add_token(parser, line[position:position + 1]) or_return
			parser.position += 1
		case '`':
			content, next, ok := parse_code_span(line, position)
			if ok {
				add_token(parser, content, {.Code}) or_return
				parser.position = next
				continue
			}
			run := run_length(line, position, '`')
			add_token(parser, line[position:position + run]) or_return
			parser.position += run
		case '<':
			text, next, ok := parse_autolink(line, position)
			if ok {
				add_token(parser, text, {.Link}, text) or_return
				parser.position = next
				continue
			}
			scan_text(parser) or_return
		case '!':
			if position + 1 < len(line) && line[position + 1] == '[' {
				// an image renders as a link whose text is the alt text
				push_bracket(parser, line[position:position + 2]) or_return
				continue
			}
			scan_text(parser) or_return
		case '[':
			push_bracket(parser, line[position:position + 1]) or_return
		case ']':
			scan_close_bracket(parser) or_return
		case '*':
			scan_delimiter(parser, .Star, '*') or_return
		case '_':
			scan_delimiter(parser, .Underscore, '_') or_return
		case '~':
			scan_delimiter(parser, .Tilde, '~') or_return
		case:
			scan_text(parser) or_return
		}
	}
	return
}

// scan_text pushes the run of plain text starting at the current position, which
// ends at the next character that can start an inline.
@(require_results)
scan_text :: proc(parser: ^Inline_Parser) -> (err: mem.Allocator_Error) {
	line := parser.line
	end := parser.position + 1
	for end < len(line) && !starts_inline(line, end) { end += 1 }
	add_token(parser, line[parser.position:end]) or_return
	parser.position = end
	return
}

// starts_inline reports whether an inline construct can begin at index, which is
// the set of characters scan_text stops at.
starts_inline :: proc(line: string, index: int) -> bool {
	switch line[index] {
	case '\\', '`', '<', '[', ']', '*', '_', '~':
		return true
	case '!':
		return index + 1 < len(line) && line[index + 1] == '['
	}
	return false
}

// scan_delimiter pushes the run of repeated character at the current position,
// as a delimiter of the given kind when it can open or close, and as literal
// text otherwise.
@(require_results)
scan_delimiter :: proc(parser: ^Inline_Parser, kind: Delimiter_Kind, character: u8) -> (err: mem.Allocator_Error) {
	line := parser.line
	position := parser.position
	run := run_length(line, position, character)
	if kind == .Tilde && run > 2 {
		// a run of three or more tildes never matches
		add_token(parser, line[position:position + run]) or_return
		parser.position = position + run
		return
	}
	can_open, can_close := delimiter_flanking(line, position, run, kind)
	index := len(parser.tokens)
	add_token(parser, line[position:position + run]) or_return
	append(&parser.delimiters, Inline_Delimiter{token = index, kind = kind, active = true, can_open = can_open, can_close = can_close}) or_return
	parser.position = position + run
	return
}

// push_bracket pushes the bracket text at the current position, either `[` or
// `![`, with its bracket stack entry.
@(require_results)
push_bracket :: proc(parser: ^Inline_Parser, text: string) -> (err: mem.Allocator_Error) {
	index := len(parser.tokens)
	add_token(parser, text) or_return
	append(&parser.brackets, Inline_Bracket{token = index, delimiters = len(parser.delimiters), active = true}) or_return
	parser.position += len(text)
	return
}

// scan_close_bracket handles a `]`: it forms a link or image when the nearest
// bracket is active and followed by a link target, and pushes the `]` as literal
// text otherwise. A formed link takes every text after it up to this bracket as
// its text, and leaves no bracket that could form a link around it.
@(require_results)
scan_close_bracket :: proc(parser: ^Inline_Parser) -> (err: mem.Allocator_Error) {
	line := parser.line
	position := parser.position
	parser.position += 1
	if len(parser.brackets) == 0 {
		add_token(parser, line[position:position + 1]) or_return
		return
	}
	bracket := pop(&parser.brackets)
	if !bracket.active || parser.position >= len(line) || line[parser.position] != '(' {
		add_token(parser, line[position:position + 1]) or_return
		return
	}
	if len(parser.link_matches) == 0 {
		build_link_matches(line, &parser.link_matches) or_return
	}
	destination, next, ok := parse_link_target(line, parser.position, parser.link_matches[:])
	if !ok {
		// neither bracket is text after all
		add_token(parser, line[position:position + 1]) or_return
		return
	}
	// emphasis inside the link text cannot match emphasis outside it
	process_emphasis(parser.tokens[:], parser.delimiters[:], bracket.delimiters)
	resize(&parser.delimiters, bracket.delimiters) or_return
	// a link cannot contain a link
	for &earlier in parser.brackets { earlier.active = false }
	parser.tokens[bracket.token].text = ""
	for &token in parser.tokens[bracket.token + 1:] {
		token.style |= {.Link}
		token.url = destination
	}
	parser.position = next
	return
}

// parse_code_span parses the code span whose opening backtick run starts at
// position. The content is verbatim, and one space is stripped from each end
// when it is padded with spaces on both ends without being all spaces.
@(require_results)
parse_code_span :: proc(line: string, position: int) -> (content: string, next: int, ok: bool) {
	opening := run_length(line, position, '`')
	for index := position + opening; index < len(line); {
		if line[index] != '`' {
			index += 1
			continue
		}
		run := run_length(line, index, '`')
		if run != opening {
			index += run
			continue
		}
		content = line[position + opening:index]
		if len(content) > 2 && content[0] == ' ' && content[len(content) - 1] == ' ' && strings.trim_left(content, " ") != "" {
			content = content[1:len(content) - 1]
		}
		return content, index + run, true
	}
	return
}

// parse_autolink parses the absolute URI of `<scheme:rest>` at position and
// returns the text between the angle brackets, which is its text and its
// destination alike.
@(require_results)
parse_autolink :: proc(line: string, position: int) -> (text: string, next: int, ok: bool) {
	index := position + 1
	if index >= len(line) || !is_ascii_letter(line[index]) { return }
	start := index
	for index < len(line) && is_scheme_byte(line[index]) { index += 1 }
	if index - start < AUTOLINK_SCHEME_MIN || index - start > AUTOLINK_SCHEME_MAX { return }
	if index >= len(line) || line[index] != ':' { return }
	index += 1
	for index < len(line) {
		character := line[index]
		if character == '>' { return line[position + 1:index], index + 1, true }
		if character == '<' || character <= ' ' || character == 0x7F { return }
		index += 1
	}
	return
}

// build_link_matches records matching unescaped parentheses and the first
// destination boundary inside each pair. It also records the next unescaped
// quote of each kind, so malformed titles do not rescan the same suffix.
@(require_results)
build_link_matches :: proc(line: string, matches: ^[dynamic]int) -> (err: mem.Allocator_Error) {
	resize(matches, len(line)) or_return
	openings: [dynamic]int = make([dynamic]int, context.temp_allocator)
	defer delete(openings)
	last_single_quote, last_double_quote := -1, -1
	for index := 0; index < len(line); {
		character := line[index]
		if character == '\\' && index + 1 < len(line) && is_punctuation_byte(line[index + 1]) {
			index += 2
			continue
		}
		if character <= ' ' || character == 0x7F {
			for opening_index := len(openings) - 1; opening_index >= 0; opening_index -= 1 {
				opening := openings[opening_index]
				if matches[opening] >= 0 { break }
				matches[opening] = index
			}
		}
		switch character {
		case '(':
			matches[index] = -1
			append(&openings, index) or_return
		case ')':
			if len(openings) > 0 {
				opening := openings[len(openings) - 1]
				boundary := matches[opening]
				_ = resize(&openings, len(openings) - 1)
				matches[opening] = index
				matches[index] = boundary
			}
		case '\'':
			matches[index] = -1
			if last_single_quote >= 0 { matches[last_single_quote] = index }
			last_single_quote = index
		case '"':
			matches[index] = -1
			if last_double_quote >= 0 { matches[last_double_quote] = index }
			last_double_quote = index
		}
		index += 1
	}
	for opening in openings { matches[opening] = -1 }
	return
}

// parse_link_target parses `(destination "title")` at position, which must point
// at the `(`, and returns the destination and the position after its matching
// `)`. matches is built once for the line. The destination excludes its angle
// brackets and keeps its escapes as they are, and the title is discarded.
@(require_results)
parse_link_target :: proc(line: string, position: int, matches: []int) -> (destination: string, next: int, ok: bool) {
	if position >= len(line) || line[position] != '(' || matches[position] < 0 { return }
	closing := matches[position]
	index := position + 1
	for index < len(line) && is_space_or_tab(line[index]) { index += 1 }
	if index >= len(line) { return }
	if line[index] == '<' {
		index += 1
		start := index
		for index < len(line) && line[index] != '>' {
			if line[index] == '<' { return }
			index += 1
		}
		if index >= len(line) { return }
		destination = line[start:index]
		index += 1
	} else {
		start := index
		for index < closing {
			character := line[index]
			if character == '\\' && index + 1 < len(line) && is_punctuation_byte(line[index + 1]) {
				index += 2
				continue
			}
			if character <= ' ' || character == 0x7F { break }
			if character == '(' {
				nested_closing := matches[index]
				if nested_closing < 0 { return }
				boundary := matches[nested_closing]
				if boundary >= 0 {
					index = boundary
					break
				}
				index = nested_closing + 1
				continue
			}
			if character == ')' { break }
			index += 1
		}
		if index == start { return }
		destination = line[start:index]
	}
	spaced := false
	for index < len(line) && is_space_or_tab(line[index]) {
		index += 1
		spaced = true
	}
	if index >= len(line) { return }
	if line[index] == ')' { return destination, index + 1, true }
	if !spaced { return }
	closed := false
	switch line[index] {
	case '"', '\'':
		index, closed = skip_title(index, matches)
	case '(':
		index, closed = skip_title(index, matches)
	}
	if !closed { return }
	for index < len(line) && is_space_or_tab(line[index]) { index += 1 }
	if index >= len(line) || line[index] != ')' { return }
	return destination, index + 1, true
}

// skip_title returns the position after the title's matching closer.
@(require_results)
skip_title :: proc(position: int, matches: []int) -> (next: int, ok: bool) {
	closing := matches[position]
	if closing < 0 { return position, false }
	return closing + 1, true
}

// process_emphasis matches delimiter runs into Emphasis, Strong, and
// Strikethrough styles on the tokens strictly between them, for every delimiter
// at or above bottom, which is the start of a link text or of the paragraph.
process_emphasis :: proc(tokens: []Inline_Token, delimiters: []Inline_Delimiter, bottom: int) {
	openers_bottom: [DELIMITER_KIND_COUNT][OPENERS_BOTTOM_COUNT]int
	for kind in 0 ..< DELIMITER_KIND_COUNT {
		for bucket in 0 ..< OPENERS_BOTTOM_COUNT { openers_bottom[kind][bucket] = bottom - 1 }
	}
	closer := bottom
	for closer < len(delimiters) {
		entry := &delimiters[closer]
		closer_count := len(tokens[entry.token].text)
		if !entry.active || !entry.can_close || closer_count == 0 {
			closer += 1
			continue
		}
		bucket := (closer_count % 3) * 2 + (1 if entry.can_open else 0)
		lowest := openers_bottom[int(entry.kind)][bucket]
		found, opener, opener_count := false, 0, 0
		for candidate := closer - 1; candidate > lowest; candidate -= 1 {
			other := &delimiters[candidate]
			if !other.active || other.kind != entry.kind { continue }
			count := len(tokens[other.token].text)
			if !other.can_open || count == 0 { continue }
			if entry.kind == .Tilde {
				if count != closer_count { continue }
			} else if (other.can_close || entry.can_open) && (count + closer_count) % 3 == 0 && !(count % 3 == 0 && closer_count % 3 == 0) {
				continue
			}
			found, opener, opener_count = true, candidate, count
			break
		}
		if !found {
			// no opener up to this closer can match this kind of closer again
			openers_bottom[int(entry.kind)][bucket] = closer - 1
			if !entry.can_open { entry.active = false }
			closer += 1
			continue
		}
		other := &delimiters[opener]
		style := Style{.Emphasis}
		use := 1
		switch {
		case entry.kind == .Tilde:
			style = {.Strikethrough}
			use = closer_count
		case opener_count >= 2 && closer_count >= 2:
			style = {.Strong}
			use = 2
		}
		// delimiters are consumed from the ends that face each other
		opening_token := &tokens[other.token]
		opening_token.text = opening_token.text[:len(opening_token.text) - use]
		closing_token := &tokens[entry.token]
		closing_token.text = closing_token.text[use:]
		for index in other.token + 1 ..< entry.token { tokens[index].style |= style }
		for index in opener + 1 ..< closer { delimiters[index].active = false }
		if len(opening_token.text) == 0 { other.active = false }
		if len(closing_token.text) == 0 { entry.active = false }
	}
}

// delimiter_flanking reports whether the run of kind at position, run characters
// long, can open and close emphasis. The character before the start of a line and
// after the end of a line counts as whitespace, and any non-ASCII byte as a
// letter.
delimiter_flanking :: proc(line: string, position, run: int, kind: Delimiter_Kind) -> (can_open: bool, can_close: bool) {
	before_whitespace, before_punctuation := false, false
	if position > 0 {
		before := line[position - 1]
		before_whitespace = strings.is_ascii_space(rune(before))
		before_punctuation = is_punctuation_byte(before)
	} else {
		before_whitespace = true
	}
	after_whitespace, after_punctuation := false, false
	if position + run < len(line) {
		after := line[position + run]
		after_whitespace = strings.is_ascii_space(rune(after))
		after_punctuation = is_punctuation_byte(after)
	} else {
		after_whitespace = true
	}
	left := !after_whitespace && (!after_punctuation || before_whitespace || before_punctuation)
	right := !before_whitespace && (!before_punctuation || after_whitespace || after_punctuation)
	if kind == .Underscore {
		return left && (!right || before_punctuation), right && (!left || after_punctuation)
	}
	return left, right
}

// span_count returns the number of spans spans_from_tokens writes.
span_count :: proc(tokens: []Inline_Token) -> int {
	count := 0
	previous: Span
	for token in tokens {
		if len(token.text) == 0 { continue }
		if count == 0 || !merges_with(previous, token) { count += 1 }
		previous = Span {
			text  = token.text,
			style = token.style,
			url   = token.url,
		}
	}
	return count
}

// spans_from_tokens writes the non-empty tokens to destination, merged where
// they are adjacent in the source with one style and one destination.
spans_from_tokens :: proc(destination: []Span, tokens: []Inline_Token) {
	written := 0
	for token in tokens {
		if len(token.text) == 0 { continue }
		if written > 0 && merges_with(destination[written - 1], token) {
			destination[written - 1].text = extend_text(destination[written - 1].text, token.text)
			continue
		}
		destination[written] = Span {
			text  = token.text,
			style = token.style,
			url   = token.url,
		}
		written += 1
	}
}

// merges_with reports whether a token continues the span before it, which
// happens when the two are adjacent in the source and styled alike.
merges_with :: proc(previous: Span, token: Inline_Token) -> bool {
	adjacent := uintptr(raw_data(previous.text)) + uintptr(len(previous.text)) == uintptr(raw_data(token.text))
	return previous.style == token.style && previous.url == token.url && adjacent
}

// extend_text returns the view of left followed by right, which must be adjacent
// in memory.
extend_text :: proc(left, right: string) -> string {
	return strings.string_from_ptr(cast(^u8)raw_data(left), len(left) + len(right))
}

// add_token pushes the text with the style and url inlines give it.
@(require_results)
add_token :: proc(parser: ^Inline_Parser, text: string, style := Style{}, url := "") -> (err: mem.Allocator_Error) {
	append(&parser.tokens, Inline_Token{text = text, url = url, style = style}) or_return
	return
}

// run_length counts the characters equal to character from position on.
run_length :: proc(line: string, position: int, character: u8) -> int {
	length := 0
	for position + length < len(line) && line[position + length] == character { length += 1 }
	return length
}

is_space_or_tab :: proc(character: u8) -> bool {
	return character == ' ' || character == '\t'
}

// is_punctuation_byte reports whether character is ASCII punctuation, which
// stands in for the Unicode punctuation class.
is_punctuation_byte :: proc(character: u8) -> bool {
	switch character {
	case '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/', ':':
		return true
	case ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~':
		return true
	}
	return false
}

is_ascii_letter :: proc(character: u8) -> bool {
	return (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z')
}

is_ascii_digit :: proc(character: u8) -> bool {
	return character >= '0' && character <= '9'
}

is_scheme_byte :: proc(character: u8) -> bool {
	return is_ascii_letter(character) || is_ascii_digit(character) || character == '+' || character == '.' || character == '-'
}
