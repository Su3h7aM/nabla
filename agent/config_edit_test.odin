#+test
package agent

import "core:strings"
import "core:testing"

@(test)
test_config_model_disable_and_enable_change_only_the_disabled_field :: proc(t: ^testing.T) {
	source := `-- user comment
return {
	providers = {
		acme = {
			base_url = "https://api.acme.test", -- keep
			models = {
				chat = { context_window = 100000, disabled = false },
				mini = { thinking = false },
			},
		},
	},
}
`
	disabled, changed, err := config_model_set_disabled(source, "acme", "chat", true, context.temp_allocator)
	testing.expect_value(t, err, Config_Edit_Error.None)
	testing.expect(t, changed)
	testing.expect(t, strings.contains(disabled, "chat = { context_window = 100000, disabled = true }"))
	testing.expect(t, strings.contains(disabled, "-- user comment"))
	testing.expect(t, strings.contains(disabled, "base_url = \"https://api.acme.test\", -- keep"))

	enabled, changed_back, enable_err := config_model_set_disabled(disabled, "acme", "chat", false, context.temp_allocator)
	testing.expect_value(t, enable_err, Config_Edit_Error.None)
	testing.expect(t, changed_back)
	testing.expect(t, strings.contains(enabled, "chat = { context_window = 100000, disabled = false }"))
}

@(test)
test_config_model_disable_adds_an_entry_for_a_model_without_one :: proc(t: ^testing.T) {
	source := `return {
	providers = {
		acme = {
			models = {
				mini = { thinking = false },
			},
		},
	},
}`
	edited, changed, err := config_model_set_disabled(source, "acme", "chat", true, context.temp_allocator)
	testing.expect_value(t, err, Config_Edit_Error.None)
	testing.expect(t, changed)
	testing.expect(t, strings.contains(edited, "[\"chat\"] = { disabled = true },"))
	testing.expect(t, strings.contains(edited, "mini = { thinking = false },"))
}
