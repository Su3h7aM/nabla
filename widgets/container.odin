package widgets

import "nabla:layout"

Container :: struct {
	id:    layout.Id,
	style: layout.Layout_Style,
}

// container_desc builds the element descriptor for this container.
//
// Descriptor rather than a wrapper proc on purpose: `layout.element` is a
// deferred scope, and a wrapper that calls it would close the scope when the
// wrapper returns instead of when the caller's block ends. The caller opens
// the scope itself: `if layout.element(ctx, container_desc(c)) { ... }`.
container_desc :: proc(container: Container) -> layout.Element_Desc {
	return {id = container.id, layout = container.style}
}
