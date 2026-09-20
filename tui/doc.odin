// Package tui renders immediate-mode terminal interfaces from completed
// nabla:layout frames. layout owns sizing, positioning, padding, clipping, and
// responsiveness. tui projects that geometry to terminal cells and writes a
// caller-owned nabla:term.Frame_Buffer using nabla:text width rules.
//
// The preferred API is scoped. Bind layout_services for terminal text,
// declare and solve the layout tree, then render the same hierarchy through
// frame and element:
//
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
//                 style = {size = 1, color = layout.rgba(255, 255, 255, 255), wrap = .Words},
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
//     if tui.frame(&ui, solved, cells) {
//         if tui.element(&ui, {id = panel_id}) {
//             widgets.draw_block(&ui, panel)
//             if tui.element(&ui, {id = body_id}) {
//                 tui.text(&ui, body_style)
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
// return, break, and continue. Context uses fixed inline scope storage,
// allocates nothing, and has a valid zero value.
//
// text draws the resolved lines emitted by layout.text, so layout owns wrapping
// and line placement while nabla:text supplies width measurement.
//
// put, fill, and draw_text are overloaded. Their Frame_Buffer forms are the
// explicit-rectangle escape hatch for small renderers and existing code. Their
// Context forms draw in the active scope. fill_at, put_at, and draw_text_at let
// custom widgets address a smaller absolute rectangle while retaining the
// active layout clip.
//
// The widgets subpackage owns reusable UI behavior and caller-owned widget
// state. Events remain in nabla:input. Terminal sessions, styles, colors,
// buffers, cursors, and presentation remain in nabla:term. tui is not a facade
// over those packages.
package tui
