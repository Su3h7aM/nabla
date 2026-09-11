#+test
#+private file
package widgets

import "core:testing"
import "nabla:layout"

@(test)
test_label_desc_carries_the_id_text_and_sizing :: proc(t: ^testing.T) {
	sizing := layout.Sizing {
		width  = layout.grow(),
		height = layout.fit(),
	}
	desc := label_desc(Label{id = layout.id("title"), text = "hello"}, sizing)
	testing.expect_value(t, desc.id, layout.id("title"))
	testing.expect_value(t, desc.text, "hello")
	testing.expect_value(t, desc.sizing, sizing)
}
