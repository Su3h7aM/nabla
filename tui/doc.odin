// Package tui joins Nabla's pure layout results, normalized terminal events,
// text policy, terminal-cell composition, and full-frame presentation.
//
// The package is a set of caller-driven data transformations. It owns no
// application loop, clock, scheduler, retained widget tree, or render rate.
// A caller may render from event handlers or at a fixed cadence. Every v1
// render requested by the caller rebuilds layout and the complete cell frame;
// cross-frame diff presentation is not part of the canonical path.
// Terminal presentation reserves the bottom-right cell to avoid an autowrap
// scroll. Composition may populate that logical cell, but the v1 full-frame
// encoder intentionally does not emit it.
//
// Cell_Buffer borrows caller-owned Cell storage. Cell grapheme strings are
// also borrowed and must remain valid until the corresponding terminal frame
// has been presented. init performs no allocation, accepts zero-sized grids,
// and leaves the destination and storage unchanged on failure.
//
// Layout owns geometry and renderer-neutral commands. TUI owns projection,
// clipping into terminal cells, command composition, and durable interaction
// facts keyed by layout.Id. Terminal I/O occurs only when the caller passes a
// completed frame to tty.present.
package tui
