// Package widgets provides reusable terminal components over nabla:tui.
//
// block declares a bordered box inside a layout frame: `if block(&ctx, &paints,
// {...}) { children }`. The box is a layout element whose border tui.draw_commands
// draws and whose padding reserves the inset; its title and footer are overlay
// elements on the top and bottom border rows. draw_block draws the same look
// straight into a frame buffer for callers that have no layout.
//
// Input has a scoped form that draws in the active tui element. Its geometry
// comes from layout: it uses the selected box and only computes which rows the
// box shows and where the caret sits in them. The caret's rows come from
// input_lines, so the box a caller draws and the rows the caret moves through
// are the same wrap.
//
// Paragraph and List retain explicit Cell_Rect forms for callers using tui's
// low-level frame-buffer API. They perform local row iteration inside that
// caller-supplied rectangle. Scoped interfaces should instead declare text and
// item rows through layout, then render each resolved node with tui.element and
// tui.text. This avoids a second layout system inside widgets.
//
// Scroll is the one scroll model: a first visible row that either follows the
// bottom or is pinned, over a range that layout reports. List and Input keep a
// plain row offset and share scroll_reveal, the math that keeps a row visible.
// List navigation covers next, previous, first, last, page, and index.
//
// Widget model state belongs to the caller. Input owns its dynamic text buffer
// between input_init and input_destroy. List_State owns selection and scroll
// position. Widgets do not own terminal sessions, input events, or layout
// contexts.
package widgets
