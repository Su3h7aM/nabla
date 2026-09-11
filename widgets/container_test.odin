#+test
#+private file
package widgets

import "core:testing"
import "nabla:layout"

@(test)
test_container_desc_carries_the_id_and_style :: proc(t: ^testing.T) {
	style := layout.Layout_Style {
		flow    = .Column,
		gap     = 3,
		padding = layout.pad_all(2),
	}
	desc := container_desc(Container{id = layout.id("panel"), style = style})
	testing.expect_value(t, desc.id, layout.id("panel"))
	testing.expect_value(t, desc.layout, style)
}
