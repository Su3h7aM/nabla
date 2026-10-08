package agent

import "nabla:ai"

// What a model holds and what input it takes.
//
// Model_Capacity is computed once, by model_capacity, while the catalog is resolved, so no
// two features disagree about what a model can hold or accept. window is the limit. trigger is
// the input size at which a summary starts and a finished one is installed: a threshold for
// background work, not a limit on what may be sent. model_max_output is what every request
// asks the model to generate; the window is not divided between input and output.
Model_Capacity :: struct {
	window:           int,
	model_max_output: int,
	trigger:          int,
	media:            bit_set[ai.Provider_Media],
}

// CHAT_DEFAULT_CONTEXT_WINDOW is the window assumed for a model that no
// enrichment source described. It is a runtime default rather than a metadata
// source: it applies only after user configuration, provider discovery, and
// models.dev have all left the window unstated, and it never replaces a stated one.
CHAT_DEFAULT_CONTEXT_WINDOW :: 128 * 1024

// CHAT_DEFAULT_OUTPUT_TOKENS is what a request may generate for a model that states
// no maximum of its own.
CHAT_DEFAULT_OUTPUT_TOKENS :: 4096

// CHAT_COMPACT_TRIGGER_PERCENT is the share of the window at which background compaction
// starts when the model configures no compaction_trigger of its own.
CHAT_COMPACT_TRIGGER_PERCENT :: 50

// model_capacity divides one resolved model's window. Presence decides the window:
// a stated one is used as stated, including an explicit zero, which admission then
// refuses rather than quietly running with the default.
model_capacity :: proc(model: Catalog_Model) -> Model_Capacity {
	window := model.context_window.? or_else CHAT_DEFAULT_CONTEXT_WINDOW
	if window <= 0 { return {} }

	stated := model.max_output_tokens.? or_else CHAT_DEFAULT_OUTPUT_TOKENS
	if stated <= 0 { stated = CHAT_DEFAULT_OUTPUT_TOKENS }

	return {
		window = window,
		model_max_output = stated,
		trigger = model.compaction_trigger.? or_else window * CHAT_COMPACT_TRIGGER_PERCENT / 100,
		media = model_media(model),
	}
}

// MEDIA_MODALITIES names each file format by the models.dev input modality that admits it.
MEDIA_MODALITIES := [ai.Provider_Media]string {
	.PNG  = "image",
	.JPEG = "image",
	.GIF  = "image",
	.WebP = "image",
	.PDF  = "pdf",
}

// model_media returns the file formats whose modality the model lists; a model that lists none, or states nothing, takes no file.
model_media :: proc(model: Catalog_Model) -> (media: bit_set[ai.Provider_Media]) {
	for modality in model.input_modalities.? or_else nil {
		for name, format in MEDIA_MODALITIES {
			if name == modality { media += {format} }
		}
	}
	return media
}

// Chat_Calibration is the provider's count against the harness's raw estimate for one
// request of the session's current selection. The zero value is no pair: the raw estimate
// stands until the provider reports.
Chat_Calibration :: struct {
	measured:  i64, // input tokens the provider reported for the request
	estimated: i64, // the raw estimate of that same request
}

// chat_calibrated_estimate turns a raw estimate into the one admission and the compaction
// trigger both read: raw * measured / estimated, or raw itself when
// there is no usable pair. The product is computed in i64, so no realistic window overflows.
@(require_results)
chat_calibrated_estimate :: proc(calibration: Chat_Calibration, raw: int) -> int {
	if calibration.measured <= 0 || calibration.estimated <= 0 { return raw }
	return int(i64(raw) * calibration.measured / calibration.estimated)
}

// model_capacity_admits reports whether an input of this size can be sent: the window is
// known and the estimate is below it. It is the one predicate admission, compaction
// switching, and repair answer with, so what the harness will send and what it considers
// too large are the same size.
@(require_results)
model_capacity_admits :: proc(capacity: Model_Capacity, estimate: int) -> bool {
	return capacity.window > 0 && estimate < capacity.window
}
