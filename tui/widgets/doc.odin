// Package widgets provides reusable terminal components over nabla:tui.
//
// Block and Input have scoped forms that draw in the active tui element. Their
// geometry comes from layout: Block uses the resolved outer box and expects
// layout padding to reserve its border, while Input uses the selected box and
// only computes which rows the box shows and where the caret sits in them. The
// caret's rows come from input_lines, so the box a caller draws and the rows the
// caret moves through are the same wrap.
//
// Paragraph and List retain explicit Cell_Rect forms for callers using tui's
// low-level frame-buffer API. They perform local row iteration inside that
// caller-supplied rectangle. Scoped interfaces should instead declare text and
// item rows through layout, then render each resolved node with tui.element and
// tui.text. This avoids a second layout system inside widgets.
//
// Widget model state belongs to the caller. Input owns its dynamic text buffer
// between input_init and input_destroy. List_State owns selection and scroll
// position. Widgets do not own terminal sessions, input events, or layout
// contexts.
package widgets
