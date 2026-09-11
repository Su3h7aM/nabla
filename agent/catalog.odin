package agent

// Caller-supplied provider and model descriptions: what the configuration
// loader produces and the chat path reads.
//
// Every optional field carries an explicit presence flag, so an absent value
// stays distinguishable from a present zero. That distinction is the whole
// point of the shape -- a configured context window of 0 is not the same fact
// as an unconfigured one, and neither is the same as "not reported".
//
// These are the only catalog types. The first-present merge resolver that once
// lived beside them had no second source to merge and no consumer outside its
// own tests, so it was deleted rather than carried in the merge. The fields it
// would have read are all here; adding it back is a decision for the change
// that first needs to merge two sources.

Catalog_Thinking_Source :: struct {
	present:           bool,
	blocked:           bool,
	supported_present: bool,
	supported:         bool,
	toggle_present:    bool,
	toggle:            bool,
	levels_present:    bool,
	levels:            []string,
}

Catalog_Model_Source :: struct {
	id:                        string,
	disabled_present:          bool,
	disabled:                  bool,
	display_name_present:      bool,
	display_name:              string,
	context_window_present:    bool,
	context_window:            int,
	max_output_tokens_present: bool,
	max_output_tokens:         int,
	input_modalities_present:  bool,
	input_modalities:          []string,
	output_modalities_present: bool,
	output_modalities:         []string,
	tools_present:             bool,
	tools:                     bool,
	thinking:                  Catalog_Thinking_Source,
}

Catalog_Provider_Source :: struct {
	id:               string,
	base_url_present: bool,
	base_url:         string,
	api_present:      bool,
	api:              string,
	// A literal secret, or `${NAME}` naming an environment variable. Resolved
	// only when a connection is built, so no secret is ever held here.
	api_key_present:  bool,
	api_key:          string,
	models:           []Catalog_Model_Source,
}
