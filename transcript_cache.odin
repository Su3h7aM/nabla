package main

import "base:runtime"
import "core:mem"
import "core:mem/virtual"

import "nabla:markdown"
import "nabla:text"

// Markdown_Cache keeps the parsed Markdown of assistant entries between frames. The
// transcript is still declared from scratch every frame; the cache only spares
// sanitizing and parsing text that has not changed. It is a memo, not a model of the
// screen: a record is valid for one (entry id, text revision) and lives only while frames
// keep asking for it, so whatever the transcript stops drawing is dropped at the next
// sweep. The zero value is an empty cache that allocates its map from
// context.allocator; markdown_cache_init names another allocator. Main thread only.
Markdown_Cache :: struct {
	records: map[u64]Markdown_Cache_Record, // keyed by Entry.id
	frame:   u64,
}

Markdown_Cache_Record :: struct {
	revision: u64,
	// frame is the last frame that asked for the record; the sweep drops it once a
	// frame passes without asking.
	frame:    u64,
	document: markdown.Document,
	// arena owns document and the cleaned text its strings borrow, so a record is
	// released or re-parsed as one unit.
	arena:    virtual.Arena,
}

// markdown_cache_init makes an empty cache whose map is allocated from allocator.
markdown_cache_init :: proc(cache: ^Markdown_Cache, allocator := context.allocator) {
	cache^ = {}
	cache.records.allocator = allocator
}

// markdown_cache_destroy releases every record and the map. A zero cache is a no-op.
markdown_cache_destroy :: proc(cache: ^Markdown_Cache) {
	for _, &record in cache.records {
		virtual.arena_destroy(&record.arena)
	}
	delete(cache.records)
	cache^ = {}
}

// markdown_cache_document returns entry's text parsed as Markdown, parsing it only when the
// entry's revision changed since the cached record. The document is owned by the cache and
// stays valid until the next call for the same entry, the sweep that drops it, or destroy.
// On an allocation error the entry has no record and the caller draws the text another way.
@(require_results)
markdown_cache_document :: proc(cache: ^Markdown_Cache, entry: ^Entry) -> (document: markdown.Document, err: mem.Allocator_Error) {
	_, record, inserted := map_entry(&cache.records, entry.id) or_return
	record.frame = cache.frame
	if !inserted && record.revision == entry.revision {
		return record.document, nil
	}

	if inserted {
		if err = virtual.arena_init_growing(&record.arena); err != nil {
			delete_key(&cache.records, entry.id)
			return {}, err
		}
	} else {
		virtual.arena_free_all(&record.arena)
	}
	allocator := virtual.arena_allocator(&record.arena)
	cleaned: string
	if cleaned, err = text.sanitize_text(string(entry.text[:]), allocator); err == nil {
		record.document, err = markdown.parse(cleaned, allocator)
	}
	if err != nil {
		virtual.arena_destroy(&record.arena)
		delete_key(&cache.records, entry.id)
		return {}, err
	}
	record.revision = entry.revision
	return record.document, nil
}

// markdown_cache_sweep ends a frame: it releases every record the frame did not ask for.
// Call it once per frame, after the whole transcript was declared.
markdown_cache_sweep :: proc(cache: ^Markdown_Cache) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	// Ids are collected first so the map is not changed while it is walked.
	stale := make([dynamic]u64, context.temp_allocator)
	for id, record in cache.records {
		if record.frame != cache.frame {
			// A record that cannot be listed stays until a later sweep lists it.
			append(&stale, id) or_break
		}
	}
	for id in stale {
		if record, found := &cache.records[id]; found {
			virtual.arena_destroy(&record.arena)
		}
		delete_key(&cache.records, id)
	}
	cache.frame += 1
}
