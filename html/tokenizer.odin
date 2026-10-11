package html

import "core:strings"

Token_Kind :: enum {
	Start_Tag,
	End_Tag,
	Text,
	Comment,
	Doctype,
}

// Token is one piece of the document. Every string borrows the input.
//
// For Start_Tag and End_Tag, text is the tag name as written and attributes is
// the unparsed text between the name and the closing '>'; read it with
// next_attribute or attribute. For Text, text is the raw content. For Comment,
// text is the content between "<!--" and "-->" or "--!>". A bogus comment
// ("<!x>", "<?x>", "</ x>") holds what follows its first two bytes up to the
// next '>'. For Doctype, text is what follows "<!doctype" without leading white
// space, such as "html". self_closing is true for a start tag whose closing '>'
// is directly preceded by a '/' that is not part of an attribute, as in "<br/>"
// and `<a href="x"/>`, but not "<br/ >" or "<a href=x/>". HTML itself ignores it
// on most elements.
Token :: struct {
	kind:         Token_Kind,
	text:         string,
	attributes:   string,
	self_closing: bool,
}

// Attribute is one name and value pair of a tag. The value is raw, without
// quotes and not decoded, and is empty for a valueless attribute.
Attribute :: struct {
	name:  string,
	value: string,
}

// Tokenizer iterates over the tokens of a string. The zero value has an empty
// input and yields nothing, and it owns nothing, so it needs no destroy.
Tokenizer :: struct {
	source:   string,
	offset:   int,
	raw_name: string, // set while inside a raw text element; borrows source
}

// init prepares tokenizer to iterate over source, which must outlive every token.
init :: proc(tokenizer: ^Tokenizer, source: string) {
	tokenizer^ = {
		source = source,
	}
}

// next returns the next token, or ok false once the input is consumed.
next :: proc(tokenizer: ^Tokenizer) -> (token: Token, ok: bool) {
	for tokenizer.offset < len(tokenizer.source) {
		rest := tokenizer.source[tokenizer.offset:]

		if tokenizer.raw_name != "" {
			name := tokenizer.raw_name
			tokenizer.raw_name = ""
			end := raw_text_end(rest, name)
			tokenizer.offset += end
			if end > 0 {
				return Token{kind = .Text, text = rest[:end]}, true
			}
			continue
		}

		if rest[0] != '<' || !starts_markup(rest) {
			end := text_end(rest)
			tokenizer.offset += end
			return Token{kind = .Text, text = rest[:end]}, true
		}

		switch {
		case strings.has_prefix(rest, "<!--"):
			return read_comment(tokenizer, rest), true
		case len(rest) >= 9 && name_equal(rest[:9], "<!doctype"):
			content, consumed := read_until_gt(rest[9:])
			tokenizer.offset += 9 + consumed
			return Token{kind = .Doctype, text = strings.trim_left_space(content)}, true
		case rest[1] == '!' || rest[1] == '?':
			content, consumed := read_until_gt(rest[2:])
			tokenizer.offset += 2 + consumed
			return Token{kind = .Comment, text = content}, true
		case rest[1] == '/':
			if is_ascii_alpha(rest[2]) {
				return read_tag(tokenizer, rest, .End_Tag), true
			}
			if rest[2] == '>' {
				tokenizer.offset += 3
				continue
			}
			content, consumed := read_until_gt(rest[2:])
			tokenizer.offset += 2 + consumed
			return Token{kind = .Comment, text = content}, true
		case:
			return read_tag(tokenizer, rest, .Start_Tag), true
		}
	}
	return {}, false
}

// name_equal reports whether two tag or attribute names are equal when ASCII
// letters are compared without case. It compares bytes only: unlike
// strings.equal_fold it does no Unicode folding, so "claſs" is not "class".
name_equal :: proc(name, other: string) -> bool {
	if len(name) != len(other) {
		return false
	}
	for i in 0 ..< len(name) {
		if ascii_lower(name[i]) != ascii_lower(other[i]) {
			return false
		}
	}
	return true
}

// attribute returns the raw value of the first attribute of a start or end tag
// whose name is name_equal to name. ok is false when the tag has no such
// attribute; a valueless attribute returns "" with ok true. The value borrows
// the tag's input.
attribute :: proc(token: Token, name: string) -> (value: string, ok: bool) {
	rest := token.attributes
	for {
		attr: Attribute
		attr, rest = next_attribute(rest) or_break
		if name_equal(attr.name, name) {
			return attr.value, true
		}
	}
	return "", false
}

// next_attribute parses the first attribute out of attributes, the text of
// Token.attributes, and returns the text after it. Start with token.attributes
// and pass the returned rest back in until ok is false. The attribute and rest
// both borrow the attributes argument.
next_attribute :: proc(attributes: string) -> (attr: Attribute, rest: string, ok: bool) {
	attr, rest, ok, _ = scan_attribute(attributes)
	return
}

// scan_attribute is the one scanner of tag attributes. It skips white space and
// '/' and parses one attribute. When no attribute is left, ok is false, rest
// starts at the closing '>' or is empty, and closes_tag tells whether the
// skipped separators ended in a '/' directly before that '>'.
@(private)
scan_attribute :: proc(text: string) -> (attr: Attribute, rest: string, ok: bool, closes_tag: bool) {
	rest = text
	for len(rest) > 0 && (is_space(rest[0]) || rest[0] == '/') {
		rest = rest[1:]
	}
	if len(rest) == 0 || rest[0] == '>' {
		skipped := len(text) - len(rest)
		return {}, rest, false, len(rest) > 0 && skipped > 0 && text[skipped - 1] == '/'
	}

	// The first byte belongs to the name even when it is '=', as in the standard.
	name_end := 1
	for name_end < len(rest) && !is_space(rest[name_end]) && rest[name_end] != '/' && rest[name_end] != '>' && rest[name_end] != '=' {
		name_end += 1
	}
	attr.name = rest[:name_end]
	rest = skip_space(rest[name_end:])
	if len(rest) == 0 || rest[0] != '=' {
		return attr, rest, true, false
	}

	rest = skip_space(rest[1:])
	if len(rest) > 0 && (rest[0] == '"' || rest[0] == '\'') {
		close := strings.index_byte(rest[1:], rest[0])
		if close < 0 {
			attr.value, rest = rest[1:], ""
		} else {
			attr.value, rest = rest[1:1 + close], rest[close + 2:]
		}
		return attr, rest, true, false
	}
	value_end := 0
	for value_end < len(rest) && !is_space(rest[value_end]) && rest[value_end] != '>' {
		value_end += 1
	}
	attr.value, rest = rest[:value_end], rest[value_end:]
	return attr, rest, true, false
}

@(private)
read_comment :: proc(tokenizer: ^Tokenizer, rest: string) -> Token {
	body := rest[4:]
	// "<!-->" and "<!--->" are empty comments.
	switch {
	case strings.has_prefix(body, ">"):
		tokenizer.offset += 5
		return Token{kind = .Comment}
	case strings.has_prefix(body, "->"):
		tokenizer.offset += 6
		return Token{kind = .Comment}
	}
	from := 0
	for {
		found := strings.index(body[from:], "--")
		if found < 0 {
			tokenizer.offset += len(rest)
			return Token{kind = .Comment, text = body}
		}
		at := from + found
		terminator := 0
		switch {
		case strings.has_prefix(body[at + 2:], ">"):
			terminator = 3
		case strings.has_prefix(body[at + 2:], "!>"):
			terminator = 4
		}
		if terminator > 0 {
			tokenizer.offset += 4 + at + terminator
			return Token{kind = .Comment, text = body[:at]}
		}
		from = at + 1
	}
}

@(private)
read_tag :: proc(tokenizer: ^Tokenizer, rest: string, kind: Token_Kind) -> Token {
	start := kind == .End_Tag ? 2 : 1
	name_end := start
	for name_end < len(rest) && !is_space(rest[name_end]) && rest[name_end] != '/' && rest[name_end] != '>' {
		name_end += 1
	}
	token := Token {
		kind = kind,
		text = rest[start:name_end],
	}

	// Scanning the attributes here, with the scanner callers use, honours quotes
	// when looking for the closing '>'.
	remaining := rest[name_end:]
	for {
		_, after, more, closes_tag := scan_attribute(remaining)
		remaining = after
		if !more {
			token.self_closing = kind == .Start_Tag && closes_tag
			break
		}
	}

	attributes_end := len(rest) - len(remaining)
	token.attributes = rest[name_end:attributes_end]
	tokenizer.offset += attributes_end
	if len(remaining) > 0 {
		tokenizer.offset += 1 // the '>'
	}
	if kind == .Start_Tag && is_raw_text_element(token.text) {
		tokenizer.raw_name = token.text
	}
	return token
}

// is_raw_text_element reports whether the content of the element is text up to
// its end tag: script and style (raw text), textarea and title (escapable raw
// text), the obsolete xmp, iframe, noembed, and noframes, and plaintext, which
// has no end tag.
@(private)
is_raw_text_element :: proc(name: string) -> bool {
	names := [?]string{"script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes", "plaintext"}
	for raw_name in names {
		if name_equal(name, raw_name) {
			return true
		}
	}
	return false
}

// raw_text_end returns the length of the raw text of an element, which ends at
// the first "</name" followed by white space, '/', '>', or the end of the input.
@(private)
raw_text_end :: proc(rest: string, name: string) -> int {
	if name_equal(name, "plaintext") {
		return len(rest)
	}
	from := 0
	for {
		found := strings.index(rest[from:], "</")
		if found < 0 {
			return len(rest)
		}
		at := from + found
		after := at + 2 + len(name)
		if after <= len(rest) && name_equal(rest[at + 2:after], name) {
			if after == len(rest) || is_space(rest[after]) || rest[after] == '/' || rest[after] == '>' {
				return at
			}
		}
		from = at + 2
	}
}

// text_end returns the length of the text at the start of rest, which ends at
// the next '<' that starts markup. rest[0] is always part of the text, even a
// '<' that does not start markup.
@(private)
text_end :: proc(rest: string) -> int {
	from := 1
	for {
		found := strings.index_byte(rest[from:], '<')
		if found < 0 {
			return len(rest)
		}
		at := from + found
		if starts_markup(rest[at:]) {
			return at
		}
		from = at + 1
	}
}

// starts_markup reports whether rest, which begins with '<', begins a tag, a
// comment, or a doctype rather than literal text. A lone "</" at the end of the
// input is text, as in the standard.
@(private)
starts_markup :: proc(rest: string) -> bool {
	if len(rest) < 2 {
		return false
	}
	switch rest[1] {
	case '/':
		return len(rest) > 2
	case '!', '?':
		return true
	}
	return is_ascii_alpha(rest[1])
}

@(private)
read_until_gt :: proc(rest: string) -> (content: string, consumed: int) {
	end := strings.index_byte(rest, '>')
	if end < 0 {
		return rest, len(rest)
	}
	return rest[:end], end + 1
}

@(private)
skip_space :: proc(text: string) -> string {
	rest := text
	for len(rest) > 0 && is_space(rest[0]) {
		rest = rest[1:]
	}
	return rest
}

@(private)
is_space :: proc(char: u8) -> bool {
	return char == ' ' || char == '\t' || char == '\n' || char == '\f' || char == '\r'
}

@(private)
is_ascii_alpha :: proc(char: u8) -> bool {
	return (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z')
}

@(private)
ascii_lower :: proc(char: u8) -> u8 {
	return char >= 'A' && char <= 'Z' ? char + ('a' - 'A') : char
}
