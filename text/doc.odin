// Package text measures and lays out terminal text: grapheme clusters, display
// width, measurement, truncation, wrapping, and break scanning. It is a
// foundation package, so it knows nothing about terminals, rendering, models, or
// HTTP, and it draws nothing itself.
//
// The Unicode rules are core's. core:unicode/utf8 provides the UAX#29
// grapheme-cluster iterator and the normalized East Asian width this package
// reuses through the Grapheme, Grapheme_Iterator, and grapheme_* aliases, so a
// caller never imports core:unicode/utf8 directly. What this package adds is the
// column arithmetic over that traversal.
//
// Width is policy the caller supplies in a Width_Profile, never discovered from
// the environment: the tab stop, what a cluster the profile cannot draw becomes,
// and whether an emoji-presentation sequence is one cell or two. Measurement,
// truncation, and drawing all run the same traversal, so a string that measures
// N columns also draws as N columns.
//
// text_columns and truncate_text count and cut cells, measure_text reports the
// same count as a result with an error, break_text finds the next break
// opportunity, and Wrap_Iterator splits one line into cell-bounded pieces.
//
// Every procedure borrows its input and allocates nothing, so there is no handle
// to acquire or release and no state shared between calls: a result is a plain
// value or a slice of the input, and the procedures run on any thread. A failure
// is a status, never a panic: a cluster the policy cannot draw follows the
// profile and reports Invalid_Text, and measure_text returns Measure_Error.
package text
