// Package tui renders immediate-mode terminal interfaces from completed
// nabla:layout frames. layout owns sizing, positioning, padding, clipping, and
// responsiveness. tui projects that geometry to terminal cells and writes a
// caller-owned nabla:term.Frame_Buffer using nabla:text width rules.
//
// The preferred API is scoped. Bind layout_services for terminal text,
// declare and solve the layout tree, then render the same hierarchy through
// frame and element:
//
//     paints: tui.Paints
//     defer delete(paints)
//     body_paint, _ := tui.paint(&paints, {style = {foreground = term.Indexed_Color(7)}})
//     layout.set_services(&layout_ctx, tui.layout_services(&measure_context))
//     if layout.frame(&layout_ctx, viewport) {
//         if layout.element(&layout_ctx, layout.Element_Desc{
//             id = panel_id,
//             layout = {
//                 sizing = {layout.grow(), layout.grow()},
//                 padding = layout.pad_all(1),
//             },
//         }) {
//             layout.text(&layout_ctx, layout.Text_Desc{
//                 id = body_id,
//                 text = body,
//                 style = {size = 1, wrap = .Words},
//                 paint = body_paint,
//                 sizing = {layout.grow(), layout.fit()},
//             })
//         }
//     }
//     solved, layout_error := layout.result(&layout_ctx)
//     if layout_error != .None {
//         return
//     }
//
//     ui: tui.Context
//     if tui.frame(&ui, solved, cells, paints = paints[:]) {
//         if tui.element(&ui, {id = panel_id}) {
//             widgets.draw_block(&ui, panel)
//             if tui.element(&ui, {id = body_id}) {
//                 tui.text(&ui)
//             }
//         }
//     }
//     rendered, render_error := tui.result(&ui)
//     if render_error == .None {
//         term.present(session, rendered.buffer, profile, rendered.cursor, output)
//     }
//
// The render hierarchy must match the solved layout hierarchy. element selects
// by stable Id; element_node selects a Node_Handle while traversing the result.
// Both select either the resolved outer or inner box and apply the node's
// effective clip. Their deferred cleanup closes on every block exit, including
// return, break, and continue. Context keeps only the active scope and
// resolves its ancestors from the layout result, so it nests as deep as layout
// does, allocates nothing, and has a valid zero value.
//
// text draws the resolved lines emitted by layout.text, so layout owns wrapping
// and line placement while nabla:text supplies width measurement.
//
// Layout carries a layout.Paint id on every command it emits and never reads it.
// tui resolves the id in a Paints table the caller fills while declaring the
// frame: paint appends a Paint (terminal style, fill grapheme, border glyphs,
// hyperlink) and returns the id to put in a Text_Desc, Paint_Style, or
// Image_Content. Id 0 is never returned and makes layout emit no command. The
// table is cleared each frame and must outlive the draw of that frame's
// commands. draw_commands paints every command of a solved frame into a cell
// rectangle without the scoped API.
//
// put, fill, and draw_text are overloaded. Their Frame_Buffer forms are the
// explicit-rectangle escape hatch for small renderers and existing code. Their
// Context forms draw in the active scope. fill_at, put_at, and draw_text_at let
// custom widgets address a smaller absolute rectangle while retaining the
// active layout clip.
//
// draw_image fills a cell rect with the placeholder cells of a term.Image_Id, which the
// terminal shows as the image placed at the rect's size (term.graphics_transmit,
// term.graphics_place). The image is then ordinary cells that clip and scroll like text;
// a rect clipped at its left edge draws nothing, since each row names column 0.
//
// Screen owns the frame lifecycle of one terminal so a program need not keep
// its own buffers. screen_init binds an allocator; each frame calls
// screen_begin for a blanked term.Frame_Buffer of the viewport's size, draws
// into it, sets its links, and calls screen_present. screen_present writes only
// the cells that changed since the last presented frame, grows its output
// scratch when term.present asks, and remembers the frame on success. A failed
// present, or screen_invalidate (after a resize or any outside write to the
// terminal), makes the next frame a full one. The zero Screen is inert, and
// screen_destroy releases everything.
//
// The widgets subpackage owns reusable UI behavior and caller-owned widget
// state. Events remain in nabla:input. Terminal sessions, styles, colors,
// buffers, cursors, and presentation remain in nabla:term. tui is not a facade
// over those packages.
package tui
