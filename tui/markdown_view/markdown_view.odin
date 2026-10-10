package markdown_view

import "core:mem"
import "core:strconv"
import "core:strings"

import "nabla:layout"
import "nabla:markdown"
import "nabla:term"
import "nabla:text"
import "nabla:tui"

// Theme is the terminal style of each element. The zero value styles nothing and
// allows no links.
Theme :: struct {
	// base is the style under every element, so a document can be declared on a
	// colored background. The styles below are merged over it. The zero value adds
	// nothing.
	base:         term.Style,
	// code styles text_body code and code blocks, link styles link text, and both
	// are merged over the style of the span's other flags.
	code:         term.Style,
	link:         term.Style,
	// dim styles decoration: quote bars, rules, table borders, code info
	// strings, and the destination shown after link text.
	dim:          term.Style,
	// headings holds the style of levels 1 to 6.
	headings:     [6]term.Style,
	table_header: term.Style,
	// link_schemes are the URL schemes that become terminal hyperlinks, compared
	// without case. Any other link stays text.
	link_schemes: []string,
}

// Target is the open layout frame a document is declared into.
Target :: struct {
	ctx:    ^layout.Context,
	paints: ^tui.Paints,
	// links is the frame's hyperlink table (term.Frame_Buffer.links). The
	// destinations are views into the document's source.
	links:  ^[dynamic]string,
}

CODE_INSET :: 2
QUOTE_INSET :: 2
BULLET_MARKER :: "• "
ORDERED_MARKER_SUFFIX :: ". "
LINK_URL_PREFIX :: " ("
LINK_URL_SUFFIX :: ")"
TABLE_CELL_PADDING :: 1
// ORDERED_NUMBER_DIGITS holds any i64 in decimal with its sign.
ORDERED_NUMBER_DIGITS :: 20
SPACES :: "                    "

@(private)
Declarer :: struct {
	target:    Target,
	theme:     Theme,
	allocator: mem.Allocator,
}

// declare adds the blocks of document to the open element of target. A document
// without blocks adds nothing. The text, runs, and marker strings come from
// allocator and have no destroy: pass the temp allocator or an arena that lives
// until the frame result is released. The only error is an allocation failure,
// after which the frame holds a partial document.
@(require_results)
declare :: proc(target: Target, document: markdown.Document, theme: Theme, allocator := context.temp_allocator) -> mem.Allocator_Error {
	declarer := Declarer {
		target    = target,
		theme     = theme,
		allocator = allocator,
	}
	return declare_blocks(&declarer, document.blocks, false)
}

@(private)
TEXT_STYLE :: layout.Text_Style {
	size = 1,
	wrap = .Words,
}

// column_style is the column that holds blocks. Its width grows so that the
// rows and cells inside resolve against a definite width.
@(private)
column_style :: proc(gap: f32 = 0) -> layout.Layout_Style {
	return {flow = .Column, sizing = {width = layout.grow(), height = layout.fit()}, align = .Stretch, gap = gap}
}

@(private, require_results)
declare_blocks :: proc(declarer: ^Declarer, blocks: []markdown.Block, tight: bool) -> mem.Allocator_Error {
	gap: f32 = 0 if tight else 1
	if layout.element(declarer.target.ctx, layout.Element_Desc{layout = column_style(gap)}) {
		for block in blocks {
			declare_block(declarer, block) or_return
		}
	}
	return nil
}

@(private, require_results)
declare_block :: proc(declarer: ^Declarer, block: markdown.Block) -> mem.Allocator_Error {
	switch value in block {
	case markdown.Paragraph:
		declare_inline(declarer, value.spans, declarer.theme.base, .Start) or_return
	case markdown.Heading:
		heading := style_merge(declarer.theme.base, declarer.theme.headings[clamp(value.level - 1, 0, 5)])
		declare_inline(declarer, value.spans, heading, .Start) or_return
	case markdown.Code_Block:
		declare_code_block(declarer, value) or_return
	case markdown.Quote:
		declare_quote(declarer, value) or_return
	case markdown.List:
		declare_list(declarer, value) or_return
	case markdown.Table:
		declare_table(declarer, value) or_return
	case markdown.Thematic_Break:
		rule := tui.Paint {
			style = decoration_style(declarer.theme),
			fill  = "─",
		}
		id := tui.paint(declarer.target.paints, rule) or_return
		layout.content(
			declarer.target.ctx,
			layout.Element_Desc{layout = {sizing = {width = layout.grow(), height = layout.fixed(1)}}, paint = {background = id}},
		)
	}
	return nil
}

// Inline collects the pieces of one text node: its string is the pieces joined and
// each run paints one stretch of it.
@(private)
Inline :: struct {
	pieces: [dynamic]string,
	runs:   [dynamic]layout.Text_Run,
	last:   tui.Paint,
}

@(private, require_results)
text_body_add :: proc(declarer: ^Declarer, text_body: ^Inline, value: string, paint: tui.Paint) -> mem.Allocator_Error {
	if value == "" {
		return nil
	}
	append(&text_body.pieces, value) or_return
	if count := len(text_body.runs); count > 0 && text_body.last == paint {
		text_body.runs[count - 1].length += len(value)
		return nil
	}
	id := tui.paint(declarer.target.paints, paint) or_return
	append(&text_body.runs, layout.Text_Run{length = len(value), paint = id}) or_return
	text_body.last = paint
	return nil
}

// declare_inline adds spans as one wrapped text node. base is merged under the
// style of every span.
@(private, require_results)
declare_inline :: proc(declarer: ^Declarer, spans: []markdown.Span, base: term.Style, align: layout.Text_Align) -> mem.Allocator_Error {
	text_body := Inline {
		pieces = make([dynamic]string, declarer.allocator),
		runs   = make([dynamic]layout.Text_Run, declarer.allocator),
	}
	defer delete(text_body.pieces)
	for span, index in spans {
		if span.text == "\n" {
			text_body_add(declarer, &text_body, span.text, tui.Paint{style = base}) or_return
			continue
		}
		is_link := .Link in span.style
		link: term.Link_Id
		if is_link && safe_link_url(span.url, declarer.theme.link_schemes) {
			link = link_id(declarer, span.url) or_return
		}
		text_body_add(declarer, &text_body, span.text, tui.Paint{style = span_style(declarer.theme, span.style, base), link = link}) or_return
		if is_link && link_group_end(spans, index) && !link_text_is_url(spans, index) {
			dim := tui.Paint {
				style = decoration_style(declarer.theme),
				link  = link,
			}
			text_body_add(declarer, &text_body, LINK_URL_PREFIX, dim) or_return
			text_body_add(declarer, &text_body, span.url, dim) or_return
			text_body_add(declarer, &text_body, LINK_URL_SUFFIX, dim) or_return
		}
	}
	if len(text_body.runs) == 0 {
		return nil
	}
	joined := strings.concatenate(text_body.pieces[:], declarer.allocator) or_return
	style := TEXT_STYLE
	style.align = align
	layout.text(declarer.target.ctx, layout.Text_Desc{text = joined, runs = text_body.runs[:], style = style, paint = text_body.runs[0].paint})
	return nil
}

// link_id returns the frame's id for uri, adding it to the table the first time.
@(private, require_results)
link_id :: proc(declarer: ^Declarer, uri: string) -> (id: term.Link_Id, err: mem.Allocator_Error) {
	links := declarer.target.links
	for link, index in links {
		if link == uri {
			return term.Link_Id(index + 1), nil
		}
	}
	append(links, uri) or_return
	return term.Link_Id(len(links^)), nil
}

@(private)
span_style :: proc(theme: Theme, flags: markdown.Style, base: term.Style) -> term.Style {
	style := base
	if .Strong in flags {
		style.modifiers += {.Bold}
	}
	if .Emphasis in flags {
		style.modifiers += {.Italic}
	}
	if .Strikethrough in flags {
		style.modifiers += {.Strikethrough}
	}
	if .Code in flags {
		style = style_merge(style, theme.code)
	}
	if .Link in flags {
		style = style_merge(style, theme.link)
	}
	return style
}

// style_merge returns base with the colors over sets and the modifiers of both.
@(private)
style_merge :: proc(base, over: term.Style) -> term.Style {
	style := base
	if over.foreground != nil {
		style.foreground = over.foreground
	}
	if over.background != nil {
		style.background = over.background
	}
	style.modifiers += over.modifiers
	return style
}

// decoration_style is the theme's dim style over its base.
@(private)
decoration_style :: proc(theme: Theme) -> term.Style {
	return style_merge(theme.base, theme.dim)
}

@(private)
link_group_end :: proc(spans: []markdown.Span, index: int) -> bool {
	if index + 1 >= len(spans) {
		return true
	}
	next := spans[index + 1]
	return .Link not_in next.style || next.url != spans[index].url
}

// link_text_is_url reports whether the link group starting at index spells its own
// destination, which needs no destination shown after it.
@(private)
link_text_is_url :: proc(spans: []markdown.Span, index: int) -> bool {
	url := spans[index].url
	offset := 0
	for i := index; i < len(spans); i += 1 {
		span := spans[i]
		if .Link not_in span.style || span.url != url {
			break
		}
		if len(span.text) > len(url) - offset || span.text != url[offset:offset + len(span.text)] {
			return false
		}
		offset += len(span.text)
	}
	return offset == len(url)
}

// safe_link_url reports whether url may become a terminal hyperlink: one of
// schemes, and only printable ASCII, so the URL cannot end the escape sequence
// carrying it.
@(private)
safe_link_url :: proc(url: string, schemes: []string) -> bool {
	colon := strings.index_byte(url, ':')
	if colon < 0 {
		return false
	}
	allowed := false
	for scheme in schemes {
		allowed ||= strings.equal_fold(url[:colon], scheme)
	}
	if !allowed {
		return false
	}
	for character in transmute([]u8)url {
		if character < '!' || character > '~' {
			return false
		}
	}
	return true
}

@(private, require_results)
declare_code_block :: proc(declarer: ^Declarer, block: markdown.Code_Block) -> mem.Allocator_Error {
	body := strings.join(block.lines, "\n", declarer.allocator) or_return
	if block.info == "" && body == "" {
		return nil
	}
	ctx := declarer.target.ctx
	inset := column_style()
	inset.padding.left = CODE_INSET
	if layout.element(ctx, layout.Element_Desc{layout = inset}) {
		if block.info != "" {
			dim := tui.paint(declarer.target.paints, tui.Paint{style = decoration_style(declarer.theme)}) or_return
			layout.text(ctx, layout.Text_Desc{text = block.info, style = TEXT_STYLE, paint = dim})
		}
		if body != "" {
			code := tui.paint(declarer.target.paints, tui.Paint{style = style_merge(declarer.theme.base, declarer.theme.code)}) or_return
			layout.text(ctx, layout.Text_Desc{text = body, style = {size = 1, wrap = .Characters}, paint = code})
		}
	}
	return nil
}

@(private, require_results)
declare_quote :: proc(declarer: ^Declarer, quote: markdown.Quote) -> mem.Allocator_Error {
	bar := tui.Paint {
		style = decoration_style(declarer.theme),
		border = tui.Border{vertical = "│"},
	}
	id := tui.paint(declarer.target.paints, bar) or_return
	box := column_style()
	box.padding.left = QUOTE_INSET
	element := layout.Element_Desc {
		layout = box,
		paint = {border = {paint = id, width = layout.Edges{left = 1}}},
	}
	if layout.element(declarer.target.ctx, element) {
		declare_blocks(declarer, quote.blocks, false) or_return
	}
	return nil
}

@(private, require_results)
declare_list :: proc(declarer: ^Declarer, list: markdown.List) -> mem.Allocator_Error {
	number_width := 0
	if list.ordered {
		buffer: [ORDERED_NUMBER_DIGITS]byte
		for index in 0 ..< len(list.items) {
			number_width = max(number_width, len(strconv.write_int(buffer[:], i64(list.start + index), 10)))
		}
	}
	ctx := declarer.target.ctx
	gap: f32 = 0 if list.tight else 1
	if layout.element(ctx, layout.Element_Desc{layout = column_style(gap)}) {
		for item, index in list.items {
			marker := BULLET_MARKER
			if list.ordered {
				marker = ordered_marker(list.start + index, number_width, declarer.allocator) or_return
			}
			marker_columns := text.text_columns(marker)
			if layout.element(ctx, layout.Element_Desc{layout = {flow = .Row, sizing = {width = layout.grow(), height = layout.fit()}}}) {
				paint := tui.paint(declarer.target.paints, tui.Paint{style = declarer.theme.base}) or_return
				layout.text(
					ctx,
					layout.Text_Desc {
						text = marker,
						style = {size = 1, wrap = .None},
						paint = paint,
						sizing = {width = layout.fixed(layout.Scalar(marker_columns)), height = layout.fit()},
					},
				)
				declare_blocks(declarer, item, list.tight) or_return
			}
		}
	}
	return nil
}

// ordered_marker formats an item number right-aligned in width digits, followed by
// the marker suffix.
@(private, require_results)
ordered_marker :: proc(value, width: int, allocator: mem.Allocator) -> (string, mem.Allocator_Error) {
	buffer: [ORDERED_NUMBER_DIGITS]byte
	number := strconv.write_int(buffer[:], i64(value), 10)
	spaces := SPACES
	padding := spaces[:clamp(width - len(number), 0, len(spaces))]
	return strings.concatenate({padding, number, ORDERED_MARKER_SUFFIX}, allocator)
}

@(private, require_results)
declare_table :: proc(declarer: ^Declarer, table: markdown.Table) -> mem.Allocator_Error {
	if len(table.alignments) == 0 {
		return nil
	}
	// A column is as wide as its widest cell and its two paddings, and shrinks
	// to one content column.
	columns := make([]layout.Column_Desc, len(table.alignments), declarer.allocator) or_return
	for &column in columns {
		column.width = layout.fit(2 * TABLE_CELL_PADDING + 1)
	}
	ctx := declarer.target.ctx
	if layout.table(ctx, layout.Element_Desc{layout = {sizing = {width = layout.fit(), height = layout.fit()}}}, columns) {
		declare_table_rule(declarer, len(columns), "┌", "┬", "┐") or_return
		for row_index := 0; row_index <= len(table.rows); row_index += 1 {
			is_header := row_index == 0
			cells := table.header if is_header else table.rows[row_index - 1]
			declare_table_row(declarer, cells, table.alignments, is_header) or_return
			if row_index < len(table.rows) {
				declare_table_rule(declarer, len(columns), "├", "┼", "┤") or_return
			}
		}
		declare_table_rule(declarer, len(columns), "└", "┴", "┘") or_return
	}
	return nil
}

// declare_table_rule declares a border line: a rule filling each column and a
// junction between and around them.
@(private, require_results)
declare_table_rule :: proc(declarer: ^Declarer, columns: int, left, middle, right: string) -> mem.Allocator_Error {
	ctx := declarer.target.ctx
	rule := tui.paint(declarer.target.paints, tui.Paint{style = decoration_style(declarer.theme), fill = "─"}) or_return
	if layout.table_row(ctx, layout.Element_Desc{layout = {align = .Stretch, sizing = {width = layout.fit(), height = layout.fixed(1)}}}) {
		for column in 0 ..< columns {
			declare_table_junction(declarer, left if column == 0 else middle) or_return
			layout.content(
				ctx,
				layout.Element_Desc{layout = {cell = true, sizing = {width = layout.fit(), height = layout.fixed(1)}}, paint = {background = rule}},
			)
		}
		declare_table_junction(declarer, right) or_return
	}
	return nil
}

@(private, require_results)
declare_table_junction :: proc(declarer: ^Declarer, glyph: string) -> mem.Allocator_Error {
	paint := tui.paint(declarer.target.paints, tui.Paint{style = decoration_style(declarer.theme), fill = glyph}) or_return
	layout.content(
		declarer.target.ctx,
		layout.Element_Desc{layout = {sizing = {width = layout.fixed(1), height = layout.fit()}}, paint = {background = paint}},
	)
	return nil
}

@(private, require_results)
declare_table_row :: proc(declarer: ^Declarer, cells: []markdown.Cell, alignments: []markdown.Alignment, header: bool) -> mem.Allocator_Error {
	ctx := declarer.target.ctx
	base := style_merge(declarer.theme.base, declarer.theme.table_header) if header else declarer.theme.base
	if layout.table_row(ctx, layout.Element_Desc{layout = {align = .Stretch, sizing = {width = layout.fit(), height = layout.fit()}}}) {
		for cell, column in cells {
			declare_table_junction(declarer, "│") or_return
			content := layout.Layout_Style {
				cell = true,
				flow = .Column,
				align = .Stretch,
				sizing = {width = layout.fit(), height = layout.fit(1)},
				padding = {left = TABLE_CELL_PADDING, right = TABLE_CELL_PADDING},
			}
			if layout.element(ctx, layout.Element_Desc{layout = content}) {
				declare_inline(declarer, cell, base, text_align(alignments[column])) or_return
			}
		}
		declare_table_junction(declarer, "│") or_return
	}
	return nil
}

@(private)
text_align :: proc(alignment: markdown.Alignment) -> layout.Text_Align {
	switch alignment {
	case .Right:
		return .End
	case .Center:
		return .Center
	case .None, .Left:
		return .Start
	}
	return .Start
}
