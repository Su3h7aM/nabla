// Package markdown_view declares a parsed markdown.Document into an open layout
// frame, so layout owns the wrapping. It is a foundation package: it knows
// nothing about models, sessions, or where the Markdown came from.
//
// declare turns each block into layout elements and leaves every line break to
// layout. A paragraph or heading is one wrapped text node whose runs carry the
// bold, italic, code, and link paints. A list item is a row of its marker and a
// column of its blocks, a quote is a column with a left border, a code block is
// an inset column, a thematic break is a one-row fill, and a table is a
// layout.table whose rows, border lines included, share column widths that
// layout solves and wraps cells into. No width enters the package.
//
// The caller owns the frame. Paints are added to Target.paints and hyperlink
// destinations to Target.links, both of which must outlive the draw of the
// frame's commands. Text and runs are built from the allocator given to
// declare, and layout borrows them until the frame result is released, so a
// per-frame arena or the temp allocator that is reset between frames fits.
package markdown_view
