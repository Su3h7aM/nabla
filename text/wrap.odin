package text

Wrap_Status :: enum u8 {
	OK,
	Done,
	Invalid_Text,
}

// Wrap_Iterator splits one source line into cell-bounded pieces. It borrows the
// source, allocates nothing, prefers the last fitting ASCII space, and keeps a
// grapheme cluster whole when the first cluster is wider than the bound.
Wrap_Iterator :: struct {
	_rest:    string,
	_width:   int,
	_profile: Width_Profile,
	_done:    bool,
}

wrap_iterator_make :: proc(value: string, width: int, profile: Width_Profile = DEFAULT_WIDTH_PROFILE) -> Wrap_Iterator {
	return {_rest = value, _width = width, _profile = profile}
}

wrap_next :: proc(iterator: ^Wrap_Iterator) -> (line: string, status: Wrap_Status) {
	if iterator == nil || iterator._done {
		return "", .Done
	}
	for len(iterator._rest) > 0 && iterator._rest[0] == ' ' {
		iterator._rest = iterator._rest[1:]
	}
	if len(iterator._rest) == 0 || iterator._width <= 0 {
		iterator._done = true
		return "", .OK
	}

	fitted := 0
	last_space := 0
	columns := 0
	display := display_iterator_make(iterator._rest, iterator._profile)
	for {
		cluster, display_status := display_next(&display)
		if display_status == .Done {
			break
		}
		if display_status == .Invalid_Text {
			iterator._done = true
			return "", .Invalid_Text
		}
		if columns + cluster.width > iterator._width {
			if columns == 0 {
				fitted = cluster.end
			}
			break
		}
		columns += cluster.width
		fitted = cluster.end
		if cluster.text == " " {
			last_space = cluster.end
		}
	}
	if fitted == 0 {
		iterator._done = true
		return "", .OK
	}
	if fitted == len(iterator._rest) {
		line = iterator._rest
		iterator._rest = ""
		iterator._done = true
		return line, .OK
	}

	end := fitted
	next := fitted
	if last_space > 0 {
		end = last_space - 1
		next = last_space
		for next < len(iterator._rest) && iterator._rest[next] == ' ' {
			next += 1
		}
	}
	line = iterator._rest[:end]
	iterator._rest = iterator._rest[next:]
	if len(iterator._rest) == 0 {
		iterator._done = true
	}
	return line, .OK
}
