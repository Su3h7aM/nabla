#+test
#+private file
package main

import "core:mem"
import "core:testing"

import "nabla:markdown"

@(test)
test_markdown_cache_reuses_renders_sweeps_and_destroys :: proc(t: ^testing.T) {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)

	cache: Markdown_Cache
	markdown_cache_init(&cache, mem.Allocator{mem.tracking_allocator_proc, &tracker})
	defer markdown_cache_destroy(&cache)
	entry := Entry {
		id   = 1,
		kind = .Assistant,
	}
	entry.text = make([dynamic]u8, 13, context.temp_allocator)
	copy(entry.text[:], "# hello world")

	first, first_error := markdown_cache_document(&cache, &entry)
	if !testing.expect(t, first_error == nil, "the initial presentation should render") { return }
	second, second_error := markdown_cache_document(&cache, &entry)
	if !testing.expect(t, second_error == nil, "the cached presentation should be available") { return }
	testing.expect(t, raw_data(first.blocks) == raw_data(second.blocks), "a cache hit should return the same document")

	entry.revision += 1
	entry.text = make([dynamic]u8, 13, context.temp_allocator)
	copy(entry.text[:], "# newer words")
	changed, changed_error := markdown_cache_document(&cache, &entry)
	if !testing.expect(t, changed_error == nil, "a changed revision should parse") { return }
	heading, is_heading := changed.blocks[0].(markdown.Heading)
	if !testing.expect(t, is_heading && len(heading.spans) == 1, "the new text should be parsed") { return }
	testing.expect_value(t, heading.spans[0].text, "newer words")

	other := Entry {
		id   = 2,
		kind = .Assistant,
	}
	other.text = make([dynamic]u8, 1, context.temp_allocator)
	other.text[0] = 'x'
	_, other_error := markdown_cache_document(&cache, &other)
	if !testing.expect(t, other_error == nil, "the second entry should render") { return }
	markdown_cache_sweep(&cache)
	_, kept := cache.records[entry.id]
	_, also_kept := cache.records[other.id]
	testing.expect(t, kept && also_kept, "entries asked for during the frame should survive its sweep")

	_, next_error := markdown_cache_document(&cache, &entry)
	if !testing.expect(t, next_error == nil, "the requested entry should remain available") { return }
	markdown_cache_sweep(&cache)
	_, kept = cache.records[entry.id]
	_, also_kept = cache.records[other.id]
	testing.expect(t, kept && !also_kept, "the sweep should keep asked-for entries and drop absent entries")

	markdown_cache_destroy(&cache)
	testing.expect_value(t, len(tracker.allocation_map), 0)
}

@(test)
test_markdown_cache_destroy_accepts_zero :: proc(t: ^testing.T) {
	cache: Markdown_Cache
	markdown_cache_destroy(&cache)
	testing.expect(t, cache.records == nil, "a zero cache should remain inert")
}
