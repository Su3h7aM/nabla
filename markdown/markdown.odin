package markdown

import "core:mem"

// Document is a parsed Markdown text: its top-level blocks in source order.
// Every slice in the tree is allocated from allocator, and every string is a
// view into the source passed to parse, so the source must outlive the
// document. The zero value is an empty document, and destroying it does nothing.
Document :: struct {
	blocks:    []Block,
	allocator: mem.Allocator,
}

Block :: union {
	Paragraph,
	Heading,
	Code_Block,
	Quote,
	List,
	Table,
	Thematic_Break,
}

Paragraph :: struct {
	spans: []Span,
}

// Heading is an ATX (`# Title`) or setext (`Title` over `===`) heading; level
// runs from 1 to 6.
Heading :: struct {
	level: int,
	spans: []Span,
}

// Code_Block holds the lines of a fenced or indented code block verbatim, without
// line endings, and the info string of a fence (empty for indented code).
Code_Block :: struct {
	info:  string,
	lines: []string,
}

Quote :: struct {
	blocks: []Block,
}

// List is a bullet or ordered list. Each item is the blocks it contains. start is
// the number of the first ordered item. A tight list has no blank line between
// its items or inside them, so a renderer may draw its paragraphs without
// spacing.
List :: struct {
	items:   [][]Block,
	start:   int,
	ordered: bool,
	tight:   bool,
}

// Table is a GFM pipe table. The header and every row hold exactly one cell per
// entry of alignments: a short row is padded with empty cells and a long one is
// cut.
Table :: struct {
	alignments: []Alignment,
	header:     []Cell,
	rows:       [][]Cell,
}

Cell :: []Span

Alignment :: enum u8 {
	None,
	Left,
	Center,
	Right,
}

Thematic_Break :: struct {}

// Span is a run of inline text with one style. Nested inline markup is
// flattened: `**a *b***` yields "a " as Strong and "b" as Strong and Emphasis.
// A span inside a link carries the Link flag and the link destination in url.
// The text of a span holds a line feed only for a hard line break, whose text
// is exactly "\n"; a soft line break is a span holding one space.
Span :: struct {
	text:  string,
	style: Style,
	url:   string,
}

Style_Flag :: enum u8 {
	Emphasis,
	Strong,
	Strikethrough,
	Code,
	Link,
}

Style :: bit_set[Style_Flag;u8]

// destroy frees every slice of document with the allocator it was parsed with
// and resets it to the zero value. The source it borrows is not touched.
destroy :: proc(document: ^Document) {
	blocks_destroy(document.blocks, document.allocator)
	document^ = {}
}

@(private)
blocks_destroy :: proc(blocks: []Block, allocator: mem.Allocator) {
	for block in blocks {
		block_destroy(block, allocator)
	}
	delete(blocks, allocator)
}

@(private)
block_destroy :: proc(block: Block, allocator: mem.Allocator) {
	switch value in block {
	case Paragraph:
		delete(value.spans, allocator)
	case Heading:
		delete(value.spans, allocator)
	case Code_Block:
		delete(value.lines, allocator)
	case Quote:
		blocks_destroy(value.blocks, allocator)
	case List:
		items_destroy(value.items, allocator)
	case Table:
		delete(value.alignments, allocator)
		cells_destroy(value.header, allocator)
		rows_destroy(value.rows, allocator)
	case Thematic_Break:
	}
}

@(private)
items_destroy :: proc(items: [][]Block, allocator: mem.Allocator) {
	for item in items {
		blocks_destroy(item, allocator)
	}
	delete(items, allocator)
}

@(private)
rows_destroy :: proc(rows: [][]Cell, allocator: mem.Allocator) {
	for row in rows {
		cells_destroy(row, allocator)
	}
	delete(rows, allocator)
}

@(private)
cells_destroy :: proc(cells: []Cell, allocator: mem.Allocator) {
	for cell in cells {
		delete(cell, allocator)
	}
	delete(cells, allocator)
}
