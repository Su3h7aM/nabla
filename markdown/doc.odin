// Package markdown parses the Markdown that people and language models write
// into a tree of blocks with styled inline text, for a renderer to draw. It is a
// foundation package, so it knows nothing about terminals, rendering, models, or
// HTTP.
//
// The syntax is a practical subset of CommonMark with GitHub's tables and
// strikethrough: ATX and setext headings, paragraphs, fenced and indented code,
// block quotes, bullet and ordered lists, thematic breaks, pipe tables, code
// spans, emphasis, strong emphasis, strikethrough, inline links, autolinks,
// backslash escapes, and hard line breaks. HTML, link reference definitions,
// and entity references are not recognized and stay literal text. Code spans
// and links do not cross a line ending, and a tab that indentation only partly
// covers is dropped whole. Anything the parser does not recognize is text, so
// every input parses.
//
// Inline markup is flattened into Spans, each a run of text with a Style
// bit_set, because a renderer draws runs of styled text rather than a tree.
//
// parse allocates the slices of the tree from the allocator it is given and
// allocates no strings: every string in a Document is a view into the source,
// which must outlive the document. destroy frees the tree; with an arena, free
// the arena instead. The procedures share no state and run on any thread.
package markdown
