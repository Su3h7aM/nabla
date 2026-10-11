package web

import "base:runtime"
import "core:encoding/entity"
import "core:strconv"
import "core:strings"
import "core:unicode"
import html "nabla:html"
import http "nabla:http"

// These boilerplate words follow the unlikely-candidate idea from Mozilla Readability.
@(private)
MARKDOWN_BOILERPLATE_WORDS :: [14]string {
	"nav",
	"navbar",
	"menu",
	"dropdown",
	"sidebar",
	"breadcrumb",
	"breadcrumbs",
	"toc",
	"banner",
	"cookie",
	"popup",
	"modal",
	"share",
	"social",
}

@(private)
MARKDOWN_PERMALINK_SYMBOLS :: [4]string{"#", "¶", "§", "🔗"}

@(private)
Markdown_Node :: struct {
	token:        html.Token,
	parent:       int,
	end:          int,
	dropped:      bool,
	item_started: bool,
	link_kind:    Markdown_Link_Kind,
	block:        bool,
	void:         bool,
	items:        int, // list items opened directly under this node
	position:     int, // index of this list item among its parent's items
}

@(private)
Markdown_Link_Kind :: enum {
	Text,
	Destination,
	Omit,
}

@(private)
Markdown_Output :: struct {
	builder:     strings.Builder,
	plain:       bool,
	breaks:      int,
	space:       bool,
	line_start:  bool,
	hashes:      int,
	hash_offset: int,
	nodes:       []Markdown_Node,
	index:       int,
	cell:        bool,
	digits:      int, // digits written since line start, none before them
}

@(private)
markdown_is :: proc(node: Markdown_Node, name: string) -> bool {
	return html.name_equal(node.token.text, name)
}

@(private)
markdown_void :: proc(name: string) -> bool {
	for candidate in ([]string{"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}) {
		if html.name_equal(name, candidate) { return true }
	}
	return false
}

@(private)
markdown_drop :: proc(token: html.Token, keep_noscript: bool) -> bool {
	if _, ok := html.attribute(token, "hidden"); ok { return true }
	if value, ok := html.attribute(token, "aria-hidden"); ok && html.name_equal(strings.trim_space(value), "true") { return true }
	if !keep_noscript && html.name_equal(token.text, "noscript") { return true }
	for name in ([]string{"head", "title", "script", "style", "template", "svg", "math", "iframe", "object", "embed", "canvas", "nav", "aside", "footer", "form", "button", "select", "textarea"}) {
		if html.name_equal(token.text, name) { return true }
	}
	return false
}

@(private)
markdown_boilerplate :: proc(token: html.Token) -> bool {
	words := MARKDOWN_BOILERPLATE_WORDS
	for attribute in ([]string{"class", "id"}) {
		value, _ := html.attribute(token, attribute)
		start := 0
		for character, offset in value {
			if character != '-' && character != '_' && !unicode.is_space(character) { continue }
			for word in words { if html.name_equal(value[start:offset], word) { return true } }
			start = offset + 1
			for start < len(value) && value[start] & 0xc0 == 0x80 { start += 1 }
		}
		for word in words { if html.name_equal(value[start:], word) { return true } }
	}
	return false
}

@(private)
markdown_block :: proc(name: string) -> bool {
	for candidate in ([]string{"p", "div", "section", "main", "article", "body", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "dl", "dt", "dd", "blockquote", "pre", "table", "hr"}) {
		if html.name_equal(name, candidate) { return true }
	}
	return false
}

@(private, require_results)
markdown_parse :: proc(source: string, keep_noscript: bool, allocator: runtime.Allocator) -> (nodes: [dynamic]Markdown_Node, err: runtime.Allocator_Error) {
	nodes = make([dynamic]Markdown_Node, allocator) or_return
	transferred := false
	defer if !transferred { delete(nodes) }
	stack := make([dynamic]int, allocator) or_return
	defer delete(stack)
	tokenizer: html.Tokenizer
	html.init(&tokenizer, source)
	for {
		token := html.next(&tokenizer) or_break
		if token.kind == .End_Tag {
			for position := len(stack) - 1; position >= 0; position -= 1 {
				if html.name_equal(nodes[stack[position]].token.text, token.text) {
					for index in stack[position:] { nodes[index].end = len(nodes) }
					resize(&stack, position) or_return
					break
				}
			}
			continue
		}
		if token.kind != .Text && token.kind != .Start_Tag { continue }
		start_tag := token.kind == .Start_Tag
		block := start_tag && markdown_block(token.text)
		void := start_tag && markdown_void(token.text)
		table_part := start_tag && (html.name_equal(token.text, "tr") || html.name_equal(token.text, "td") || html.name_equal(token.text, "th"))
		// Only tags that can imply an end tag scan the open elements.
		if block || table_part {
			// Optional end tags close only within their containing list or table.
			for position := len(stack) - 1; position >= 0; position -= 1 {
				open := nodes[stack[position]].token.text
				closes := html.name_equal(open, "p") && block
				closes ||= html.name_equal(token.text, "li") && html.name_equal(open, "li")
				closes ||=
					(html.name_equal(token.text, "dt") || html.name_equal(token.text, "dd")) && (html.name_equal(open, "dt") || html.name_equal(open, "dd"))
				closes ||= html.name_equal(token.text, "tr") && html.name_equal(open, "tr")
				closes ||=
					(html.name_equal(token.text, "td") || html.name_equal(token.text, "th")) && (html.name_equal(open, "td") || html.name_equal(open, "th"))
				if closes {
					for index in stack[position:] { nodes[index].end = len(nodes) }
					resize(&stack, position) or_return
					break
				}
				if html.name_equal(open, "ul") ||
				   html.name_equal(open, "ol") ||
				   html.name_equal(open, "dl") ||
				   html.name_equal(open, "table") ||
				   html.name_equal(open, "tr") { break }
			}
		}
		parent := -1
		if len(stack) > 0 { parent = stack[len(stack) - 1] }
		dropped := start_tag && markdown_drop(token, keep_noscript)
		if parent >= 0 { dropped ||= nodes[parent].dropped }
		position := 0
		if parent >= 0 && start_tag && html.name_equal(token.text, "li") {
			position = nodes[parent].items
			nodes[parent].items += 1
		}
		index := len(nodes)
		append(
			&nodes,
			Markdown_Node{token = token, parent = parent, end = index + 1, dropped = dropped, block = block, void = void, position = position},
		) or_return
		if start_tag && !void {
			append(&stack, index) or_return
		}
	}
	for index in stack { nodes[index].end = len(nodes) }
	transferred = true
	return nodes, nil
}

@(private)
markdown_break :: proc(output: ^Markdown_Output, count: int) {
	output.breaks = max(output.breaks, count)
	output.space = false
}

@(private, require_results)
markdown_heading_finish :: proc(output: ^Markdown_Output, delimiter: bool) -> bool {
	if delimiter && output.hashes > 0 && output.hashes <= 6 {
		old_length := len(output.builder.buf)
		if !write(&output.builder, "\\") { return false }
		copy(output.builder.buf[output.hash_offset + 1:], output.builder.buf[output.hash_offset:old_length])
		output.builder.buf[output.hash_offset] = '\\'
	}
	output.hashes = 0
	return true
}

@(private, require_results)
markdown_flush :: proc(output: ^Markdown_Output) -> bool {
	if output.breaks > 0 { if !markdown_heading_finish(output, true) { return false } }
	if output.breaks > 0 { output.digits = 0 }
	if output.breaks > 0 || len(output.builder.buf) == 0 { output.line_start = true }
	if len(output.builder.buf) > 0 {
		existing := 0
		for position := len(output.builder.buf) - 1; position >= 0 && output.builder.buf[position] == '\n'; position -= 1 { existing += 1 }
		for _ in 0 ..< max(output.breaks - existing, 0) { if !write(&output.builder, "\n") { return false } }
		if output.breaks == 0 && output.space { if !write(&output.builder, " ") { return false } }
	}
	output.breaks = 0
	output.space = false
	if len(output.builder.buf) == 0 || output.builder.buf[len(output.builder.buf) - 1] == '\n' {
		if !markdown_prefix(output) { return false }
	}
	return true
}

@(private, require_results)
markdown_markup :: proc(output: ^Markdown_Output, text: string) -> bool {
	if output.plain { return true }
	if !markdown_heading_finish(output, false) || !markdown_flush(output) || !write(&output.builder, text) { return false }
	output.line_start = false
	output.digits = 0
	return true
}

@(private, require_results)
markdown_end_markup :: proc(output: ^Markdown_Output, text: string) -> bool {
	// Trailing HTML whitespace belongs outside inline Markdown delimiters.
	if output.plain { return true }
	if !markdown_heading_finish(output, false) || !write(&output.builder, text) { return false }
	output.line_start = false
	output.digits = 0
	return true
}

@(private)
markdown_reference :: proc(text: string) -> bool {
	if len(text) < 3 || text[0] != '&' { return false }
	if text[1] == '#' {
		start := 2
		hexadecimal := start < len(text) && (text[start] == 'x' || text[start] == 'X')
		if hexadecimal { start += 1 }
		// CommonMark permits at most seven decimal or six hexadecimal digits.
		digits := 0
		for start + digits < len(text) {
			character := text[start + digits]
			if character == ';' { return digits > 0 && digits <= (hexadecimal ? 6 : 7) }
			if character < '0' || character > '9' {
				if !hexadecimal { return false }
				if _, ok := hex_value(character); !ok { return false }
			}
			digits += 1
			if digits > (hexadecimal ? 6 : 7) { return false }
		}
		return false
	}
	for end := 2; end < len(text) && end <= ENTITY_MAX + 1; end += 1 {
		if text[end] == ';' {
			_, _, ok := entity.xml_decode_entity(text[1:end])
			return ok
		}
		if text[end] < '0' || text[end] > '9' {
			if !(text[end] >= 'A' && text[end] <= 'Z' || text[end] >= 'a' && text[end] <= 'z') { return false }
		}
	}
	return false
}

@(private)
markdown_space :: proc(character: rune) -> bool {
	return character == ' ' || character == '\t' || character == '\r' || character == '\n' || character == '\f' || character == '\u00a0'
}

// markdown_only reports whether text starts with mark and holds nothing but mark and collapsed whitespace.
@(private)
markdown_only :: proc(text: string, mark: byte) -> bool {
	if len(text) == 0 || text[0] != mark { return false }
	for character in text {
		if character != rune(mark) && !markdown_space(character) { return false }
	}
	return true
}

@(private)
markdown_alphanumeric :: proc(character: byte) -> bool {
	return character >= '0' && character <= '9' || character >= 'A' && character <= 'Z' || character >= 'a' && character <= 'z'
}

@(private, require_results)
markdown_text :: proc(output: ^Markdown_Output, text: string, allocator: runtime.Allocator, escape := true, decode := true) -> bool {
	if !decode || strings.index_byte(text, '&') < 0 { return markdown_text_write(output, text, escape) }
	decoded, err := strings.builder_make(allocator)
	if err != nil { return false }
	defer strings.builder_destroy(&decoded)
	if !entities_write(&decoded, text) { return false }
	return markdown_text_write(output, strings.to_string(decoded), escape)
}

@(private, require_results)
markdown_text_write :: proc(output: ^Markdown_Output, value: string, escape: bool) -> bool {
	for character, offset in value {
		if markdown_space(character) {
			if !markdown_heading_finish(output, true) { return false }
			output.space = true
			output.digits = 0
			continue
		}
		if character != '#' && !markdown_heading_finish(output, false) { return false }
		if !markdown_flush(output) { return false }
		digits := output.digits
		output.digits = 0
		if character >= '0' && character <= '9' && (output.line_start || digits > 0) { output.digits = digits + 1 }
		if !output.plain && escape && character == '#' && (output.line_start || output.hashes > 0) {
			if output.hashes == 0 { output.hash_offset = len(output.builder.buf) }
			output.hashes += 1
		}
		// Inline delimiters and HTML openings are escaped; block markers only at line start.
		if !output.plain && escape {
			line_start := output.line_start
			next_byte: byte
			if offset + 1 < len(value) { next_byte = value[offset + 1] }
			marker_space := next_byte == 0 || next_byte == ' ' || next_byte == '\t' || next_byte == '\r' || next_byte == '\n'
			// CommonMark: "-" and "=" runs make thematic breaks and setext underlines, "+" and "-" followed by white space start a list.
			block_marker :=
				character == '>' ||
				((character == '-' || character == '+') && marker_space) ||
				(character == '-' && markdown_only(value[offset:], '-')) ||
				(character == '=' && markdown_only(value[offset:], '=')) ||
				((character == '.' || character == ')') && digits >= 1 && digits <= 9 && marker_space)
			// Underscores inside a word never open or close emphasis.
			intraword :=
				character == '_' &&
				offset > 0 &&
				offset + 1 < len(value) &&
				markdown_alphanumeric(value[offset - 1]) &&
				markdown_alphanumeric(value[offset + 1])
			angle_markup :=
				character == '<' &&
				(next_byte >= 'A' && next_byte <= 'Z' || next_byte >= 'a' && next_byte <= 'z' || next_byte == '/' || next_byte == '!' || next_byte == '?')
			strike_marker := character == '~' && (next_byte == '~' || offset > 0 && value[offset - 1] == '~')
			if (character == '&' && markdown_reference(value[offset:])) ||
			   character == '*' ||
			   (character == '_' && !intraword) ||
			   character == '`' ||
			   character == '[' ||
			   character == ']' ||
			   character == '\\' ||
			   angle_markup ||
			   strike_marker ||
			   (block_marker && (line_start || character == '.' || character == ')')) {
				if !write(&output.builder, "\\") { return false }
			}
		}
		end := offset + 1
		for end < len(value) && value[end] & 0xc0 == 0x80 { end += 1 }
		if !write(&output.builder, value[offset:end]) { return false }
		output.line_start = false
	}
	return true
}

@(private, require_results)
markdown_contents :: proc(nodes: []Markdown_Node, start, end: int, builder: ^strings.Builder, raw: bool) -> bool {
	for index := start; index < end; index += 1 {
		node := nodes[index]
		if node.dropped { index = node.end - 1; continue }
		if node.token.kind == .Text {
			if !entities_write(builder, node.token.text) { return false }
		} else if markdown_is(node, "br") {
			if !write(builder, raw ? "\n" : " ") { return false }
		} else if !raw && node.block {
			if !write(builder, " ") { return false }
		}
	}
	return true
}

@(private)
markdown_backticks :: proc(text: string) -> int {
	longest, run := 0, 0
	for character in text {
		if character == '`' { run += 1; longest = max(longest, run) } else { run = 0 }
	}
	return longest
}

@(private)
markdown_language :: proc(token: html.Token) -> string {
	classes, _ := html.attribute(token, "class")
	for len(classes) > 0 {
		classes = strings.trim_left_space(classes)
		end := 0
		for end < len(classes) && classes[end] != ' ' && classes[end] != '\t' && classes[end] != '\n' && classes[end] != '\r' { end += 1 }
		word := classes[:end]
		if strings.has_prefix(word, "language-") {
			language := word[len("language-"):]
			for character in language {
				if character == '`' || unicode.is_space(character) { return "" }
			}
			return language
		}
		classes = classes[end:]
	}
	return ""
}

@(private, require_results)
markdown_raw_write :: proc(output: ^Markdown_Output, text: string) -> bool {
	rest := text
	for len(rest) > 0 {
		end := strings.index_byte(rest, '\n')
		if end < 0 { end = len(rest) }
		if end > 0 {
			if !markdown_flush(output) || !write(&output.builder, rest[:end]) { return false }
		}
		if end == len(rest) { break }
		if !write(&output.builder, "\n") { return false }
		rest = rest[end + 1:]
	}
	return true
}

@(private, require_results)
markdown_code :: proc(output: ^Markdown_Output, nodes: []Markdown_Node, index: int, allocator: runtime.Allocator, inline_code := false) -> bool {
	node := nodes[index]
	builder, err := strings.builder_make(allocator)
	if err != nil { return false }
	defer strings.builder_destroy(&builder)
	if !markdown_contents(nodes, index + 1, node.end, &builder, true) { return false }
	text := strings.to_string(builder)
	block := markdown_is(node, "pre") && !inline_code
	// The HTML parser drops one newline directly after <pre>.
	if block { text = strings.trim_prefix(strings.trim_prefix(text, "\r"), "\n") }
	normalized := Markdown_Output {
		plain = true,
	}
	defer strings.builder_destroy(&normalized.builder)
	if !block {
		normalized.builder, err = strings.builder_make(allocator)
		if err != nil { return false }
		if !markdown_text(&normalized, text, allocator, decode = false) { return false }
		text = strings.to_string(normalized.builder)
	}
	if block { markdown_break(output, 2) }
	if !markdown_heading_finish(output, false) { return false }
	if !markdown_flush(output) { return false }
	if output.plain {
		if !markdown_raw_write(output, text) { return false }
	} else {
		length := max(markdown_backticks(text) + 1, 1)
		if block { length = max(length, 3) }
		for _ in 0 ..< length { if !write(&output.builder, "`") { return false } }
		if block {
			language := markdown_language(node.token)
			for child in nodes[index + 1:node.end] {
				if language == "" && child.token.kind == .Start_Tag && markdown_is(child, "code") { language = markdown_language(child.token) }
			}
			if !write(&output.builder, language) || !write(&output.builder, "\n") { return false }
		} else if strings.has_prefix(text, "`") || strings.has_suffix(text, "`") || strings.has_prefix(text, " ") || strings.has_suffix(text, " ") {
			if !write(&output.builder, " ") { return false }
		}
		if !markdown_raw_write(output, text) { return false }
		if block {
			if !strings.has_suffix(text, "\n") && !write(&output.builder, "\n") { return false }
			if !markdown_flush(output) { return false }
		} else if strings.has_prefix(text, "`") || strings.has_suffix(text, "`") || strings.has_prefix(text, " ") || strings.has_suffix(text, " ") {
			if !write(&output.builder, " ") { return false }
		}
		for _ in 0 ..< length { if !write(&output.builder, "`") { return false } }
	}
	if block { markdown_break(output, 2) }
	output.line_start = false
	return true
}

@(private, require_results)
markdown_destination :: proc(token: html.Token, name, base_url: string, allocator: runtime.Allocator) -> (destination: string, err: runtime.Allocator_Error) {
	raw, _ := html.attribute(token, name)
	builder := strings.builder_make(allocator) or_return
	defer strings.builder_destroy(&builder)
	if !entities_write(&builder, raw) { return "", .Out_Of_Memory }
	value := strings.trim_space(strings.to_string(builder))
	if value == "" || (len(value) >= len("javascript:") && html.name_equal(value[:len("javascript:")], "javascript:")) { return "", nil }
	return http.url_resolve(base_url, value, allocator)
}

@(private, require_results)
markdown_url_write :: proc(output: ^Markdown_Output, destination: string) -> bool {
	for character, index in destination {
		switch character {
		case '&':
			if markdown_reference(destination[index:]) && !write(&output.builder, "\\") { return false }
			if !write(&output.builder, "&") { return false }
		case '(':
			if !write(&output.builder, "%28") { return false }
		case ')':
			if !write(&output.builder, "%29") { return false }
		case ' ':
			if !write(&output.builder, "%20") { return false }
		case '\\':
			if !write(&output.builder, "%5C") { return false }
		case '\n', '\r', '\t':
		case:
			end := index + 1
			for end < len(destination) && destination[end] & 0xc0 == 0x80 { end += 1 }
			if !write(&output.builder, destination[index:end]) { return false }
		}
	}
	return true
}

@(private, require_results)
markdown_table :: proc(output: ^Markdown_Output, nodes: []Markdown_Node, index: int, base_url: string, allocator: runtime.Allocator) -> bool {
	rows, err := make([dynamic]int, allocator)
	if err != nil { return false }
	defer delete(rows)
	columns := -1
	regular := true
	for child := index + 1; child < nodes[index].end; child += 1 {
		if nodes[child].dropped { child = nodes[child].end - 1; continue }
		if markdown_is(nodes[child], "table") { child = nodes[child].end - 1; continue }
		if !markdown_is(nodes[child], "tr") || nodes[child].token.kind != .Start_Tag { continue }
		if _, append_err := append(&rows, child); append_err != nil { return false }
		count := 0
		for cell := child + 1; cell < nodes[child].end; cell += 1 {
			if nodes[cell].dropped { cell = nodes[cell].end - 1; continue }
			if nodes[cell].token.kind != .Start_Tag { continue }
			if markdown_is(nodes[cell], "td") || markdown_is(nodes[cell], "th") {
				count += 1
				if _, ok := html.attribute(nodes[cell].token, "colspan"); ok { regular = false }
				if _, ok := html.attribute(nodes[cell].token, "rowspan"); ok { regular = false }
				cell = nodes[cell].end - 1
			}
		}
		if columns < 0 { columns = count } else if columns != count { regular = false }
	}
	markdown_break(output, 2)
	for row, row_number in rows {
		if !markdown_flush(output) { return false }
		if regular && !output.plain && !write(&output.builder, "| ") { return false }
		count := 0
		for cell := row + 1; cell < nodes[row].end; cell += 1 {
			if nodes[cell].dropped { cell = nodes[cell].end - 1; continue }
			if nodes[cell].token.kind != .Start_Tag { continue }
			if !markdown_is(nodes[cell], "td") && !markdown_is(nodes[cell], "th") { continue }
			if count > 0 {
				separator := " | "
				if output.plain { separator = " " }
				if !write(&output.builder, separator) { return false }
			}
			cell_builder, cell_err := strings.builder_make(allocator)
			if cell_err != nil { return false }
			cell_output := Markdown_Output {
				builder = cell_builder,
				plain   = output.plain,
			}
			ok := markdown_walk(&cell_output, nodes, cell + 1, nodes[cell].end, base_url, allocator, true) == nil
			if ok {
				for character, offset in strings.to_string(cell_output.builder) {
					if character == '|' && !output.plain { ok = write(&output.builder, "\\"); if !ok { break } }
					end := offset + 1
					for end < len(cell_output.builder.buf) && cell_output.builder.buf[end] & 0xc0 == 0x80 { end += 1 }
					ok = write(&output.builder, strings.to_string(cell_output.builder)[offset:end])
					if !ok { break }
				}
			}
			strings.builder_destroy(&cell_output.builder)
			if !ok { return false }
			count += 1
			cell = nodes[cell].end - 1
		}
		if regular && !output.plain && !write(&output.builder, " |") { return false }
		markdown_break(output, 1)
		if row_number == 0 && regular && !output.plain {
			if !markdown_flush(output) || !write(&output.builder, "|") { return false }
			for _ in 0 ..< columns { if !write(&output.builder, " --- |") { return false } }
			markdown_break(output, 1)
		}
	}
	markdown_break(output, 2)
	return true
}

@(private)
markdown_item :: proc(nodes: []Markdown_Node, index: int) -> int {
	ancestor := index
	for ancestor >= 0 {
		if markdown_is(nodes[ancestor], "li") { return ancestor }
		ancestor = nodes[ancestor].parent
	}
	return -1
}

@(private)
markdown_item_marker :: proc(nodes: []Markdown_Node, index: int, buffer: []byte) -> string {
	parent := nodes[index].parent
	if parent < 0 || !markdown_is(nodes[parent], "ol") { return "- " }
	start := 1
	if value, ok := html.attribute(nodes[parent].token, "start"); ok { start = strconv.parse_int(value) or_else 1 }
	number := strconv.write_int(buffer, i64(start + nodes[index].position), 10)
	buffer[len(number)] = '.'
	buffer[len(number) + 1] = ' '
	return string(buffer[:len(number) + 2])
}

@(private, require_results)
markdown_prefix :: proc(output: ^Markdown_Output) -> bool {
	if output.cell || len(output.nodes) == 0 { return true }
	nodes := output.nodes
	item := markdown_item(nodes, output.index)
	if output.plain {
		if item >= 0 { nodes[item].item_started = true }
		return true
	}
	depth, quotes := 0, 0
	parent := output.index
	for parent >= 0 {
		if markdown_is(nodes[parent], "ul") || markdown_is(nodes[parent], "ol") { depth += 1 }
		if markdown_is(nodes[parent], "blockquote") { quotes += 1 }
		parent = nodes[parent].parent
	}
	for _ in 0 ..< quotes { if !write(&output.builder, "> ") { return false } }
	if item >= 0 {
		for _ in 0 ..< max(depth - 1, 0) { if !write(&output.builder, "    ") { return false } }
		buffer: [32]byte
		marker := markdown_item_marker(nodes, item, buffer[:])
		if nodes[item].item_started {
			for _ in 0 ..< len(marker) { if !write(&output.builder, " ") { return false } }
		} else {
			if !write(&output.builder, marker) { return false }
			nodes[item].item_started = true
		}
	}
	return true
}

@(private, require_results)
markdown_close :: proc(output: ^Markdown_Output, nodes: []Markdown_Node, index: int, base_url: string, allocator: runtime.Allocator) -> bool {
	node := nodes[index]
	if node.dropped { return true }
	if node.block {
		count := 2
		if markdown_is(node, "li") || markdown_is(node, "dt") || markdown_is(node, "dd") { count = 1 }
		if (markdown_is(node, "ul") || markdown_is(node, "ol")) && node.parent >= 0 && markdown_is(nodes[node.parent], "li") { count = 1 }
		markdown_break(output, count)
	} else if markdown_is(node, "strong") || markdown_is(node, "b") {return markdown_end_markup(output, "**")
	} else if markdown_is(node, "em") || markdown_is(node, "i") {return markdown_end_markup(output, "*")
	} else if markdown_is(node, "del") || markdown_is(node, "s") {return markdown_end_markup(output, "~~")
	} else if markdown_is(node, "a") && node.link_kind == .Destination && !output.plain {
		destination, err := markdown_destination(node.token, "href", base_url, allocator)
		if err != nil { return false }
		defer delete(destination, allocator)
		if destination != "" { return markdown_end_markup(output, "](") && markdown_url_write(output, destination) && write(&output.builder, ")") }
	}
	return true
}

// html_to_markdown returns the first title and readable content from the first main
// element or role=main, otherwise the first article, body, or whole document.
// Hidden and non-content subtrees are omitted. Boilerplate class/id words are
// matched as whole tokens separated by whitespace, hyphens, or underscores; the
// selected container is exempt. When the selection yields no text, a second pass
// ignores main and article and reads noscript content, which a browser without
// scripting would show. It tolerates incomplete HTML using
// the html tokenizer's syntax, not a browser DOM or CSS visibility rules. plain_text
// uses the same walk without Markdown delimiters or link destinations. Whitespace
// is collapsed outside preformatted text and results are trimmed. Both strings are
// owned by allocator; delete them with that allocator. On allocation failure both
// are empty and err reports the allocator failure. Calls share no mutable state.
@(require_results)
html_to_markdown :: proc(
	source, base_url: string,
	plain_text: bool,
	allocator := context.allocator,
) -> (
	title, content: string,
	err: runtime.Allocator_Error,
) {
	rendered := markdown_render(source, base_url, plain_text, false, allocator) or_return
	if rendered == "" {
		delete(rendered, allocator)
		rendered = markdown_render(source, base_url, plain_text, true, allocator) or_return
	}
	title, err = html_title(source, allocator)
	if err != nil { delete(rendered, allocator); return "", "", err }
	return title, rendered, nil
}

// markdown_render converts one selection of source. The fallback pass ignores
// main and article and keeps noscript content, for pages whose body is built by
// script and whose real text sits in noscript or outside main.
@(private, require_results)
markdown_render :: proc(
	source, base_url: string,
	plain_text, fallback: bool,
	allocator: runtime.Allocator,
) -> (
	content: string,
	err: runtime.Allocator_Error,
) {
	nodes := markdown_parse(source, fallback, allocator) or_return
	defer delete(nodes)
	output := Markdown_Output {
		builder = strings.builder_make(allocator) or_return,
		plain   = plain_text,
	}
	defer strings.builder_destroy(&output.builder)
	selected := -1
	priority := 0
	for node, index in nodes {
		if node.token.kind != .Start_Tag { continue }
		if node.dropped { continue }
		rank := 0
		if markdown_is(node, "body") { rank = 1 }
		if markdown_is(node, "article") { rank = 2 }
		role, _ := html.attribute(node.token, "role")
		if markdown_is(node, "main") || html.name_equal(strings.trim_space(role), "main") { rank = 3 }
		if rank > priority && (rank == 1 || !fallback) { selected, priority = index, rank }
	}
	start, end := 0, len(nodes)
	if selected >= 0 { start, end = selected + 1, nodes[selected].end }
	// Selection precedes the heuristic so the selected container cannot be discarded.
	for index := start; index < end; index += 1 {
		if nodes[index].dropped { index = nodes[index].end - 1; continue }
		if nodes[index].token.kind == .Start_Tag && markdown_boilerplate(nodes[index].token) {
			for child := index; child < nodes[index].end; child += 1 { nodes[child].dropped = true }
			index = nodes[index].end - 1
		}
	}
	err = markdown_walk(&output, nodes[:], start, end, base_url, allocator, false)
	if err != nil { return "", err }
	if !markdown_heading_finish(&output, true) { return "", .Out_Of_Memory }
	return strings.clone(strings.trim_space(strings.to_string(output.builder)), allocator)
}
// html_title returns the first title with entities decoded and whitespace collapsed,
// or an empty string when none exists. The caller owns the string with allocator.
// Allocation failures return an empty string and the allocator error.
@(require_results)
html_title :: proc(source: string, allocator := context.allocator) -> (string, runtime.Allocator_Error) {
	return html_metadata(source, .Title, allocator)
}

// html_description returns the first meta name=description content, otherwise the
// first meta property=og:description content, with entities decoded and whitespace
// collapsed. It returns an empty string when neither is present. The caller owns
// the string with allocator. Allocation failures return an empty string and error.
@(require_results)
html_description :: proc(source: string, allocator := context.allocator) -> (string, runtime.Allocator_Error) {
	return html_metadata(source, .Description, allocator)
}

@(private)
HTML_Metadata :: enum {
	Title,
	Description,
}

@(private, require_results)
html_metadata :: proc(source: string, kind: HTML_Metadata, allocator: runtime.Allocator) -> (value: string, err: runtime.Allocator_Error) {
	output := Markdown_Output {
		builder = strings.builder_make(allocator) or_return,
		plain   = true,
	}
	defer strings.builder_destroy(&output.builder)
	tokenizer: html.Tokenizer
	html.init(&tokenizer, source)
	inside := false
	open_graph: Maybe(string)
	for {
		token := html.next(&tokenizer) or_break
		switch kind {
		case .Title:
			if !inside {
				if token.kind == .Start_Tag && html.name_equal(token.text, "title") { inside = true }
				continue
			}
			if token.kind == .End_Tag && html.name_equal(token.text, "title") {
				return strings.clone(strings.trim_space(strings.to_string(output.builder)), allocator)
			}
			if token.kind == .Text && !markdown_text(&output, token.text, allocator) { return "", .Out_Of_Memory }
		case .Description:
			if token.kind != .Start_Tag || !html.name_equal(token.text, "meta") { continue }
			content := html.attribute(token, "content") or_continue
			name, _ := html.attribute(token, "name")
			if html.name_equal(strings.trim_space(name), "description") {
				if !markdown_text(&output, content, allocator) { return "", .Out_Of_Memory }
				return strings.clone(strings.trim_space(strings.to_string(output.builder)), allocator)
			}
			property, _ := html.attribute(token, "property")
			if html.name_equal(strings.trim_space(property), "og:description") {
				if _, found := open_graph.?; !found { open_graph = content }
			}
		}
	}
	if kind == .Description {
		if content, found := open_graph.?; found {
			if !markdown_text(&output, content, allocator) { return "", .Out_Of_Memory }
		}
	}
	return strings.clone(strings.trim_space(strings.to_string(output.builder)), allocator)
}

@(private)
markdown_decorative_image :: proc(token: html.Token) -> bool {
	alt, present := html.attribute(token, "alt")
	// HTML assigns an empty alt attribute to decorative images.
	return present && alt == ""
}

@(private)
markdown_data_url :: proc(source: string) -> bool {
	value := strings.trim_space(source)
	return len(value) >= len("data:") && html.name_equal(value[:len("data:")], "data:")
}

@(private, require_results)
markdown_image :: proc(output: ^Markdown_Output, token: html.Token, base_url: string, allocator: runtime.Allocator) -> (err: runtime.Allocator_Error) {
	if markdown_decorative_image(token) { return nil }
	alt, _ := html.attribute(token, "alt")
	source, _ := html.attribute(token, "src")
	// Data URLs are embedded payloads, not useful destinations in readable text.
	if markdown_data_url(source) {
		if alt != "" && !markdown_text(output, alt, allocator) { return .Out_Of_Memory }
		return nil
	}
	destination := markdown_destination(token, "src", base_url, allocator) or_return
	defer delete(destination, allocator)
	if destination == "" { return nil }
	if markdown_data_url(destination) {
		if alt != "" && !markdown_text(output, alt, allocator) { return .Out_Of_Memory }
		return nil
	}
	if !markdown_markup(output, "![") || !markdown_text(output, alt, allocator) || !markdown_markup(output, "](") { return .Out_Of_Memory }
	if !output.plain && (!markdown_url_write(output, destination) || !write(&output.builder, ")")) { return .Out_Of_Memory }
	return nil
}

@(private)
markdown_same_page_fragment :: proc(destination, base_url: string) -> bool {
	if strings.index_byte(destination, '#') < 0 { return false }
	link := http.url_parse(destination)
	base := http.url_parse(base_url)
	link_path := link.path if link.path != "" else "/"
	base_path := base.path if base.path != "" else "/"
	return html.name_equal(link.scheme, base.scheme) && html.name_equal(link.host, base.host) && link_path == base_path && link.query == base.query
}

@(private)
markdown_permalink_symbol :: proc(text: string) -> bool {
	symbols := MARKDOWN_PERMALINK_SYMBOLS
	for symbol in symbols { if text == symbol { return true } }
	return false
}

@(private)
markdown_in_heading :: proc(nodes: []Markdown_Node, index: int) -> bool {
	parent := nodes[index].parent
	for parent >= 0 {
		name := nodes[parent].token.text
		if len(name) == 2 && (name[0] == 'h' || name[0] == 'H') && name[1] >= '1' && name[1] <= '6' { return true }
		parent = nodes[parent].parent
	}
	return false
}

@(private, require_results)
markdown_link :: proc(
	nodes: []Markdown_Node,
	index: int,
	base_url: string,
	allocator: runtime.Allocator,
) -> (
	kind: Markdown_Link_Kind,
	destination: string,
	err: runtime.Allocator_Error,
) {
	visible := Markdown_Output {
		builder = strings.builder_make(allocator) or_return,
		plain   = true,
	}
	defer strings.builder_destroy(&visible.builder)
	has_image := false
	for child := index + 1; child < nodes[index].end; child += 1 {
		node := nodes[child]
		if node.dropped { child = node.end - 1; continue }
		if node.token.kind == .Text {
			if !markdown_text(&visible, node.token.text, allocator) { return .Text, "", .Out_Of_Memory }
		} else if markdown_is(node, "img") && !markdown_decorative_image(node.token) {
			source, _ := html.attribute(node.token, "src")
			alt, _ := html.attribute(node.token, "alt")
			if markdown_data_url(source) {
				if !markdown_text(&visible, alt, allocator) { return .Text, "", .Out_Of_Memory }
				continue
			}
			image_source := markdown_destination(node.token, "src", base_url, allocator) or_return
			if markdown_data_url(image_source) {
				if !markdown_text(&visible, alt, allocator) { delete(image_source, allocator); return .Text, "", .Out_Of_Memory }
			} else { has_image ||= image_source != "" }
			delete(image_source, allocator)
		} else if node.block || markdown_is(node, "br") {
			visible.space = true
		}
	}
	text := strings.trim_space(strings.to_string(visible.builder))
	if text == "" && !has_image { return .Omit, "", nil }
	destination = markdown_destination(nodes[index].token, "href", base_url, allocator) or_return
	if destination == "" { return .Text, destination, nil }
	if !has_image && markdown_in_heading(nodes, index) && markdown_permalink_symbol(text) && markdown_same_page_fragment(destination, base_url) {
		return .Omit, destination, nil
	}
	return .Destination, destination, nil
}

@(private, require_results)
markdown_walk :: proc(
	output: ^Markdown_Output,
	nodes: []Markdown_Node,
	start, end: int,
	base_url: string,
	allocator: runtime.Allocator,
	cell: bool,
) -> (
	err: runtime.Allocator_Error,
) {
	stack := make([dynamic]int, allocator) or_return
	defer delete(stack)
	for index := start; index < end; index += 1 {
		for len(stack) > 0 && nodes[stack[len(stack) - 1]].end <= index {
			if cell && nodes[stack[len(stack) - 1]].block {
				output.space = true
			} else if !markdown_close(output, nodes[:], stack[len(stack) - 1], base_url, allocator) { return .Out_Of_Memory }
			resize(&stack, len(stack) - 1) or_return
		}
		output.nodes, output.index, output.cell = nodes, index, cell
		node := nodes[index]
		if node.dropped { index = node.end - 1; continue }
		if node.token.kind == .Text {
			if !markdown_text(output, node.token.text, allocator) { return .Out_Of_Memory }
			continue
		}
		if markdown_is(node, "pre") || markdown_is(node, "code") {
			if !markdown_code(output, nodes[:], index, allocator, cell) { return .Out_Of_Memory }
			index = node.end - 1
			continue
		}
		if markdown_is(node, "table") && !cell {
			if !markdown_table(output, nodes[:], index, base_url, allocator) { return .Out_Of_Memory }
			index = node.end - 1
			continue
		}
		if markdown_is(node, "br") {
			if cell { output.space = true } else { markdown_break(output, 1) }
			continue
		}
		if node.block && !cell {
			count := 2
			if markdown_is(node, "li") || markdown_is(node, "dt") || markdown_is(node, "dd") { count = 1 }
			if (markdown_is(node, "ul") || markdown_is(node, "ol")) && node.parent >= 0 && markdown_is(nodes[node.parent], "li") { count = 1 }
			item := markdown_item(nodes, index)
			if item >= 0 && item != index && !nodes[item].item_started { count = 0 }
			markdown_break(output, count)
		}
		if len(node.token.text) == 2 && (node.token.text[0] == 'h' || node.token.text[0] == 'H') && node.token.text[1] >= '1' && node.token.text[1] <= '6' {
			for _ in 0 ..< int(node.token.text[1] - '0') { if !markdown_markup(output, "#") { return .Out_Of_Memory } }
			if !markdown_markup(output, " ") { return .Out_Of_Memory }
		} else if markdown_is(node, "hr") {if !markdown_markup(output, "---") { return .Out_Of_Memory }; markdown_break(output, 2)
		} else if markdown_is(node, "strong") || markdown_is(node, "b") {if !markdown_markup(output, "**") { return .Out_Of_Memory }
		} else if markdown_is(node, "em") || markdown_is(node, "i") {if !markdown_markup(output, "*") { return .Out_Of_Memory }
		} else if markdown_is(node, "del") || markdown_is(node, "s") {if !markdown_markup(output, "~~") { return .Out_Of_Memory }
		} else if markdown_is(node, "a") {
			kind, destination, link_err := markdown_link(nodes, index, base_url, allocator)
			if link_err != nil { return link_err }
			nodes[index].link_kind = kind
			if kind == .Omit { delete(destination, allocator); index = node.end - 1; continue }
			if kind == .Destination && !markdown_markup(output, "[") { delete(destination, allocator); return .Out_Of_Memory }
			delete(destination, allocator)
		} else if markdown_is(node, "img") {
			err = markdown_image(output, node.token, base_url, allocator)
			if err != nil { return err }
		}
		if !node.void { append(&stack, index) or_return }
	}
	for len(stack) > 0 {
		if cell && nodes[stack[len(stack) - 1]].block {
			output.space = true
		} else if !markdown_close(output, nodes[:], stack[len(stack) - 1], base_url, allocator) { return .Out_Of_Memory }
		resize(&stack, len(stack) - 1) or_return
	}
	return nil
}
