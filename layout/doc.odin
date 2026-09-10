// Package layout provides an immediate-mode, renderer-independent layout and
// presentation solver: bounded caller-owned storage, lexical declarations,
// deterministic identity, normal-flow solving, text measurement and wrapping,
// overlays, clips, paint order, renderer-neutral commands, pure result queries,
// diagnostics, and borrowed frame results.
//
// The public layout boundary is deliberately pure. Measurement and line
// breaking callbacks are supplied per frame through Services; pointer history,
// hover, focus, capture, scrolling, transitions, and application routing
// belong to the caller or the TUI integration. Layout publishes geometry and
// renderer-neutral commands, not terminal I/O or retained widgets.
//
// Read this package comment as the canonical composition guide. In particular,
// `frame` and `element` use Odin's deferred lexical scopes: the declaration
// block is the tree, and leaving that block is the solve/publication point.
// Frame results and query output are borrowed until the next frame, destroy,
// or reserve.
//
// # Canonical composition
//
// A context is initialized once, services are bound before each frame, the
// current tree is declared lexically, and result is called after the block:
//
//     ctx: layout.Context
//     options := layout.Options{
//         capacities = layout.Capacities{
//             nodes = 128,
//             children = 256,
//             clips = 32,
//             commands = 256,
//             text_lines = 128,
//             overlays = 16,
//             measure_cache = 128,
//             id_table = 128,
//             depth = 32,
//             diagnostics = 64,
//             measured_words = 256,
//         },
//         cull = .Visible,
//     }
//     init_error := layout.init(&ctx, options)
//     if init_error != nil {
//         // Handle layout.Context_Data_Error or runtime.Allocator_Error.
//         return
//     }
//     defer layout.destroy(&ctx)
//
//     for running {
//         layout.set_services(&ctx, layout.Services{
//             measure_text           = tui.ascii_measure_proc,
//             measure_text_user_data = &measure_context,
//             break_text             = tui.ascii_break_proc,
//             break_text_user_data   = &break_context,
//         })
//
//         if layout.frame(&ctx, viewport) {
//             if layout.element(&ctx, layout.Element_Desc{
//                 id = layout.id("root"),
//                 layout = layout.Layout_Style{
//                     flow = .Column,
//                     sizing = layout.Sizing{
//                         width = layout.grow(),
//                         height = layout.grow(),
//                     },
//                     padding = layout.pad_all(8),
//                     gap = 6,
//                 },
//             }) {
//                 layout.text(&ctx, layout.Text_Desc{
//                     id = layout.id("title"),
//                     text = title,
//                     style = layout.Text_Style{
//                         size = 18,
//                         wrap = .None,
//                     },
//                     sizing = layout.Sizing{
//                         width = layout.fit(),
//                         height = layout.fit(),
//                     },
//                 })
//                 layout.content(&ctx, layout.Element_Desc{
//                     id = layout.id("body"),
//                     layout = layout.Layout_Style{
//                         sizing = layout.Sizing{
//                             width = layout.grow(),
//                             height = layout.grow(),
//                         },
//                     },
//                     content = layout.Content{},
//                 })
//             }
//         }
//
//         frame_result, frame_error := layout.result(&ctx)
//         if frame_error != .None {
//             // No partial result is published. Inspect layout.diagnostics(&ctx).
//             continue
//         }
//         node, found := layout.lookup(frame_result, layout.id("body"))
//         if found {
//             // Project node.outer and frame_result.commands into the renderer.
//             _ = node
//         }
//     }
//
// `init` owns allocator-backed storage and `destroy` releases it. For a fixed
// path, allocate or otherwise obtain caller-owned storage and bind it instead:
//
//     storage := make([]byte, layout.storage_size(options.capacities))
//     fixed_error := layout.init_from_buffer(&ctx, options, storage)
//     if fixed_error != nil {
//         return
//     }
//     defer layout.destroy(&ctx)
//
// The fixed storage must remain alive and at a stable address for the whole
// context lifetime. `init_from_buffer` never frees, replaces, or grows it.
//
// # Deferred lexical solve
//
// `frame` does not solve immediately. When it returns true, it opens a frame
// scope and its body is the only place where declarations for that frame are
// made. Odin runs the deferred frame cleanup when the enclosing `if` statement
// is left; that cleanup closes the scope, performs measurement and layout, and
// publishes the complete result. The caller must call `result` after every
// frame block to observe either publication or the Frame_Error.
//
//     if layout.frame(&ctx, viewport) {
//         // Declarations are visited in lexical order.
//         layout.content(&ctx, first)
//         if layout.element(&ctx, parent) {
//             layout.content(&ctx, child)
//         }
//         layout.content(&ctx, last)
//     }
//     frame_result, frame_error := layout.result(&ctx)
//
// `element` follows the same rule: a successful call declares the element and
// opens a child scope whose deferred cleanup occurs at the closing `}`. A
// failed call opens no scope, so declarations guarded by it are skipped. Use
// `content` for a leaf that has no children and `text` for a text leaf. Do not
// call `result` while a frame is open or from a measurement callback.
//
// Leaving the frame block is the deferred solve point, not the call to
// `frame`. This distinction matters for lifetimes: service callbacks and their
// user data must remain valid through the end of the declaration block because
// the solver invokes them while the deferred cleanup is running.
//
// # Axes, sizing, and centering
//
// `Layout_Style.flow` chooses the main axis:
//
//   - `.Row` lays children along X and uses Y as the cross axis.
//   - `.Column` lays children along Y and uses X as the cross axis.
//
// `justify` distributes children on the main axis. `align` positions or sizes
// children on the cross axis. There is no universal child-level `center`
// property. To center a child in a definite viewport, make the parent fill the
// viewport, use `justify = .Center` and `align = .Center`, and let the child
// use fit sizing:
//
//     if layout.frame(&ctx, viewport) {
//         if layout.element(&ctx, layout.Element_Desc{
//             layout = layout.Layout_Style{
//                 flow = .Column,
//                 sizing = layout.Sizing{
//                     width = layout.grow(),
//                     height = layout.grow(),
//                 },
//                 justify = .Center,
//                 align = .Center,
//             },
//         }) {
//             layout.content(&ctx, layout.Element_Desc{
//                 id = layout.id("centered"),
//                 layout = layout.Layout_Style{
//                     sizing = layout.Sizing{
//                         width = layout.fit(),
//                         height = layout.fit(),
//                     },
//                 },
//             })
//         }
//     }
//
// The sizing constructors express the axis contract:
//
//   - `fit(minimum, maximum)` sizes from content and clamps the result.
//   - `grow(weight, minimum, maximum)` consumes available main-axis space;
//     `maximum = 0` means unbounded.
//   - `fixed(value)` requests an exact scalar before constraints are applied.
//   - `percent(fraction, minimum, maximum)` is relative to a definite parent
//     axis. An indefinite parent axis is diagnosed rather than guessed.
//
// `min` and `max` constrain the corresponding axis. `padding` reduces the
// content box available to children, `gap` separates normal-flow children,
// `aspect` supplies a ratio when one axis is otherwise determined, and
// `justify`/`align` operate after the relevant sizes are resolved. A row's
// `justify` therefore has no effect on Y, and a column's `align` has no effect
// on Y. Use `pad_all` or `pad_xy` for explicit padding; use `radius_all` for a
// uniform paint radius.
//
// # Content zero value
//
// `Content{}` is the intentional zero value for an element with no content.
// It is inert: it emits no image or custom payload, performs no allocation,
// and does not request an image load. A caller may still use the element's
// layout, paint, clip, overlay, hit, and user fields. Choose `Image_Content`
// or `Custom_Content` only when the element has corresponding renderer data.
// Text is declared separately with `text`; its string and custom payloads are
// borrowed rather than copied into an owning retained tree.
//
// # Result and query lifetime
//
// `Frame_Result` is a borrowed view of the context's published tables. Its
// slices, the `Frame_Result` returned by `result`, and borrowed query payloads
// are valid only for the lifetime shown below. A failed next frame invalidates
// the prior view and publishes no replacement. Copy anything that must survive
// a frame boundary into caller-owned storage.
//
// | Value | Owner | Valid until |
// |---|---|---|
// | `Context` | Caller; layout stores its internal state | `destroy` or reinitialization |
// | Allocator-backed context storage | Layout, using the allocator supplied to `init` | `destroy`; `reserve` replaces it |
// | Fixed context storage | Caller | `destroy` or reinitialization; keep it stable |
// | `Options` and `Capacities` | Caller; copied by `init` | The call that supplied them |
// | `Services` callbacks and `*_user_data` | Caller; borrowed by the active solve | End of that frame's deferred solve |
// | Ordinary text and custom payloads | Caller; layout borrows them | Next `frame`, `destroy`, or `reserve` |
// | `.Static` text | Caller; immutable and address-stable | `invalidate_metrics` or `destroy` |
// | `Frame_Result` slices and query views | Layout context | Next `frame`, `destroy`, or `reserve` |
// | `diagnostics` result | Layout context | Next `frame`, `destroy`, or `reserve` |
//
// `set_services` binds the measurement and break callbacks for one frame only;
// `init` does not retain them. A later frame can safely provide different
// callback data. `measure_text_user_data` and `break_text_user_data` need only
// outlive the frame in which they are supplied, but they must remain valid for
// the deferred solve, not merely for the call to `set_services` or `frame`.
//
// Call `invalidate_metrics(ctx, generation)` outside a frame when font metrics,
// width policy, terminal resize behavior, or another caller-owned measurement
// input changes. The generation invalidates cached measurements; it does not
// extend the lifetime of borrowed text or callback data.
//
// # Publication and errors
//
// A frame publishes only a complete result. Scope imbalance, missing required
// text services, invalid text, a stalled breaker, a failed measurement, or
// structural pool exhaustion prevents publication. `result` returns the
// corresponding `Frame_Error`, and `diagnostics` provides the non-fatal
// declaration and solver details. There is no valid partial `Frame_Result`.
//
// Pure queries such as `lookup`, `node`, `clip_of`, `hit_test`, `hit_stack`,
// `ancestor_path`, and command iteration consume a completed result and do not
// own or extend its lifetime. `visible_commands` walks `Render_Command` values
// in published paint order and culls by command bounds; effective clip
// intersection remains a downstream consumer policy. Caller-provided output
// for `hit_stack` and `ancestor_path` is never silently grown or truncated:
// their `complete` value reports whether the supplied output was large enough.
// Query views and iterators borrow the result until the next frame, destroy, or
// reserve.
package layout
