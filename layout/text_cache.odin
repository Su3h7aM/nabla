package layout

import "core:mem"

// TEXT_ITEMS_PER_BUCKET sets the hash bucket count: a chain stays short while
// a full pool still visits enough items per probe to find stale ones.
@(private)
TEXT_ITEMS_PER_BUCKET :: 32

// TEXT_ITEM_MAX_AGE is the number of solves an item may go unused before a
// probe that walks past it frees it.
@(private)
TEXT_ITEM_MAX_AGE :: 2

// _Word_Span is the byte length of a record and whether it stands for a Words
// segment that has no words, which wraps to one line holding the segment as
// written. They share a word so the record stays small.
@(private)
_Word_Span :: bit_field u32 {
	length:   u32  | 31,
	wordless: bool | 1,
}

/*
One word of a text node.

Intrinsic sizing already has to visit every word to find the shrink floor, so
it records each word's advance here and wrapping consumes the record instead of
re-measuring. Offsets are relative to the node's own text, so the records stay
valid for any string with the same content.

`separator_width` is the advance of the whole gap between the word and the next
word of its segment, folded in here so packing a line is a running sum with no
lookups at all.

A text that breaks only at newlines or characters keeps one record per hard
segment instead: `offset` and `length` span the segment, `width` and `baseline`
are its measurement, so an unbroken segment becomes a line with no lookup.
`next` is the handle of the following word of the same text, or the next free
word while the record is on the free list. Handle zero is none; handle `n`
names `words[n - 1]`.
*/
@(private)
_Measured_Word :: struct {
	offset:          i32,
	next:            i32,
	span:            _Word_Span,
	width:           Scalar,
	separator_width: Scalar,
	baseline:        Scalar,
	// Index of the hard segment this word belongs to, so wrapping can find
	// segment boundaries without rescanning the string for newlines.
	segment:         i32,
}

/*
Everything the solve needs from measuring one text, independent of width.
*/
@(private)
_Text_Summary :: struct {
	widest:              f64,
	longest_unbreakable: f64,
	natural_line_height: f64,
	segment_count:       int,
	// First record of the text and the number of records: the words of a Words
	// text plus one record for each of its segments without words, the hard
	// segments of a Newlines or Characters text. Empty for Wrap.None.
	word_head:           i32,
	word_count:          int,
	// The line a text of one hard segment wraps to when it fits: its byte range,
	// size, and baseline. `line_fit_width` is the available width that keeps
	// all of it on that line, zero when the text never breaks inside a segment.
	line_start:          int,
	line_end:            int,
	line_fit_width:      f64,
	line_width:          Scalar,
	line_baseline:       Scalar,
}

/*
A cached text, keyed by `_text_identity_key`.

`next` chains the items of one hash bucket, or the free items while the item is
on the free list. Handle zero is none; handle `n` names `items[n - 1]`.
*/
@(private)
_Text_Item :: struct {
	key:        u64,
	generation: u32,
	next:       i32,
	summary:    _Text_Summary,
}

/*
Texts measured by earlier frames, with their words.

Items and words live in fixed pools carved from the context's storage, each
with a free list, and persist until evicted or `invalidate_metrics`. A pool
that is full only means the text is measured again next frame.
*/
@(private)
_Text_Cache :: struct {
	buckets:    []i32,
	items:      []_Text_Item,
	words:      []_Measured_Word,
	item_free:  i32,
	word_free:  i32,
	// Slots handed out at least once; slots below it are live or on a free list.
	item_top:   int,
	word_top:   int,
	item_count: int,
	word_count: int,
	// Most words held at once since the last clear, including words of a text
	// that was then freed because it did not fit.
	word_peak:  int,
}

@(private, require_results)
_text_bucket_count :: proc "contextless" (items: int) -> int {
	return items / TEXT_ITEMS_PER_BUCKET + (1 if items % TEXT_ITEMS_PER_BUCKET != 0 else 0)
}

// _text_cache_clear forgets every item and word without touching the pools.
@(private)
_text_cache_clear :: proc(cache: ^_Text_Cache) {
	mem.zero_slice(cache.buckets)
	cache.item_free = 0
	cache.word_free = 0
	cache.item_top = 0
	cache.word_top = 0
	cache.item_count = 0
	cache.word_count = 0
	cache.word_peak = 0
}

@(private, require_results)
_text_cache_bucket :: proc(cache: ^_Text_Cache, key: u64) -> ^i32 {
	return &cache.buckets[key % u64(len(cache.buckets))]
}

/*
Return the handle of the item for `key`, or zero, and refresh its generation.

Items on the way to the match that are older than `TEXT_ITEM_MAX_AGE`
generations are freed.
*/
@(private, require_results)
_text_cache_find :: proc(cache: ^_Text_Cache, key: u64, generation: u32) -> i32 {
	if len(cache.buckets) == 0 {
		return 0
	}
	link := _text_cache_bucket(cache, key)
	for link^ != 0 {
		handle := link^
		item := &cache.items[handle - 1]
		if item.key == key {
			item.generation = generation
			return handle
		}
		if generation - item.generation > TEXT_ITEM_MAX_AGE {
			link^ = item.next
			_text_cache_free_words(cache, item.summary.word_head)
			item.next = cache.item_free
			cache.item_free = handle
			cache.item_count -= 1
			continue
		}
		link = &item.next
	}
	return 0
}

/*
Store a summary under `key` and return its handle, or zero when the item pool
is full.

The cache takes the summary's words in either case: on failure they are freed.
Call `_text_cache_find` for the same key first, so that stale items in the
bucket are freed before the pool is judged full.
*/
@(private)
_text_cache_insert :: proc(cache: ^_Text_Cache, key: u64, generation: u32, summary: _Text_Summary) -> i32 {
	handle: i32
	if cache.item_free != 0 {
		handle = cache.item_free
		cache.item_free = cache.items[handle - 1].next
	} else if cache.item_top < len(cache.items) {
		cache.item_top += 1
		handle = i32(cache.item_top)
	} else {
		_text_cache_free_words(cache, summary.word_head)
		return 0
	}
	bucket := _text_cache_bucket(cache, key)
	cache.items[handle - 1] = _Text_Item {
		key        = key,
		generation = generation,
		next       = bucket^,
		summary    = summary,
	}
	bucket^ = handle
	cache.item_count += 1
	return handle
}

// _text_cache_alloc_word returns a free word and its handle, or zero when the pool is full.
@(private)
_text_cache_alloc_word :: proc(cache: ^_Text_Cache) -> (handle: i32, word: ^_Measured_Word) {
	if cache.word_free != 0 {
		handle = cache.word_free
		cache.word_free = cache.words[handle - 1].next
	} else if cache.word_top < len(cache.words) {
		cache.word_top += 1
		handle = i32(cache.word_top)
	} else {
		return 0, nil
	}
	cache.word_count += 1
	cache.word_peak = max(cache.word_peak, cache.word_count)
	word = &cache.words[handle - 1]
	word^ = {}
	return handle, word
}

// _text_cache_append_word links a new word at the tail of a summary's list and
// returns it, or nil when the pool is full.
@(private)
_text_cache_append_word :: proc(cache: ^_Text_Cache, summary: ^_Text_Summary, tail: ^i32) -> ^_Measured_Word {
	handle, word := _text_cache_alloc_word(cache)
	if word == nil {
		return nil
	}
	if tail^ == 0 {
		summary.word_head = handle
	} else {
		cache.words[tail^ - 1].next = handle
	}
	tail^ = handle
	summary.word_count += 1
	return word
}

// _text_cache_free_words returns the words chained from `head` to the free list.
@(private)
_text_cache_free_words :: proc(cache: ^_Text_Cache, head: i32) {
	handle := head
	for handle != 0 {
		word := &cache.words[handle - 1]
		following := word.next
		word.next = cache.word_free
		cache.word_free = handle
		cache.word_count -= 1
		handle = following
	}
}
