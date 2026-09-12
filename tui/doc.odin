// Package tui is the drawing layer for full-screen terminal applications. It
// consumes nabla:term (frame grid and presentation), nabla:text (width and
// break rules), and nabla:layout (layout-to-cell projection), and adds:
//
//   - Drawing over term.Frame_Buffer: init, put, fill, draw_text
//     (draw.odin), and rect geometry with rows/cols (geometry.odin,
//     project.odin).
//   - The layout.Services binding to text (measure.odin).
//
// The nabla:tui/widgets subpackage builds reusable components — Block,
// Paragraph, List, Input — on top of those operations.
//
// Events, styles, colors, and the terminal session belong to nabla:input and
// nabla:term; tui is not a facade over them.
package tui
