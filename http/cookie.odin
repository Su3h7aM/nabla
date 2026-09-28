package http

import "core:io"
import "core:strconv"
import "core:strings"
import "core:time"

Cookie_Same_Site :: enum {
	Unspecified,
	None,
	Strict,
	Lax,
}

Cookie :: struct {
	_raw:         string,
	name:         string,
	value:        string,
	domain:       Maybe(string),
	expires_gmt:  Maybe(time.Time),
	max_age_secs: Maybe(int),
	path:         Maybe(string),
	http_only:    bool,
	partitioned:  bool,
	secure:       bool,
	same_site:    Cookie_Same_Site,
}

// cookie_write writes cookie as its Set-Cookie field line.
cookie_write :: proc(writer: io.Writer, cookie: Cookie) -> io.Error {
	// odinfmt:disable
	io.write_string(writer, "set-cookie: ")         or_return
	write_escaped_newlines(writer, cookie.name)     or_return
	io.write_byte(writer, '=')                      or_return
	write_escaped_newlines(writer, cookie.value)    or_return

	if domain, ok := cookie.domain.(string); ok {
		io.write_string(writer, "; Domain=")        or_return
		write_escaped_newlines(writer, domain)      or_return
	}

	if expires, ok := cookie.expires_gmt.(time.Time); ok {
		io.write_string(writer, "; Expires=")       or_return
		date_write(writer, expires)                 or_return
	}

	if max_age, ok := cookie.max_age_secs.(int); ok {
		io.write_string(writer, "; Max-Age=")       or_return
		io.write_int(writer, max_age)               or_return
	}

	if path, ok := cookie.path.(string); ok {
		io.write_string(writer, "; Path=")          or_return
		write_escaped_newlines(writer, path)        or_return
	}

	switch cookie.same_site {
	case .None:   io.write_string(writer, "; SameSite=None")   or_return
	case .Lax:    io.write_string(writer, "; SameSite=Lax")    or_return
	case .Strict: io.write_string(writer, "; SameSite=Strict") or_return
	case .Unspecified: // no-op.
	}
	// odinfmt:enable

	if cookie.secure {
		io.write_string(writer, "; Secure") or_return
	}

	if cookie.partitioned {
		io.write_string(writer, "; Partitioned") or_return
	}

	if cookie.http_only {
		io.write_string(writer, "; HttpOnly") or_return
	}

	return nil
}

// cookie_string returns cookie as its Set-Cookie field line, owned by the
// caller's allocator.
cookie_string :: proc(cookie: Cookie, allocator := context.allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, 0, 20, allocator)

	cookie_write(strings.to_writer(&builder), cookie)

	return strings.to_string(builder)
}

// TODO: check specific whitespace requirements in RFC.
//
// Allocations are done to check case-insensitive attributes but they are deleted right after.
// So, all the returned strings (inside cookie) are slices into the given value string.
cookie_parse :: proc(value: string, allocator := context.allocator) -> (cookie: Cookie, ok: bool) {
	remaining := value

	equals := strings.index_byte(remaining, '=')
	if equals < 1 { return }

	cookie._raw = value
	cookie.name = remaining[:equals]
	remaining = remaining[equals + 1:]

	semicolon := strings.index_byte(remaining, ';')
	switch semicolon {
	case -1:
		cookie.value = remaining
		ok = true
		return
	case 0:
		return
	case:
		cookie.value = remaining[:semicolon]
		remaining = remaining[semicolon + 1:]
	}

	parse_part :: proc(cookie: ^Cookie, part: string, allocator := context.temp_allocator) -> (ok: bool) {
		equals := strings.index_byte(part, '=')
		switch equals {
		case -1:
			key := strings.to_lower(part, allocator)
			defer delete(key, allocator)

			switch key {
			case "httponly":
				cookie.http_only = true
			case "partitioned":
				cookie.partitioned = true
			case "secure":
				cookie.secure = true
			case:
				return
			}
		case 0:
			return
		case:
			key := strings.to_lower(part[:equals], allocator)
			defer delete(key, allocator)

			value := part[equals + 1:]

			switch key {
			case "domain":
				cookie.domain = value
			case "expires":
				cookie.expires_gmt = cookie_date_parse(value) or_return
			case "max-age":
				cookie.max_age_secs = strconv.parse_int(value, 10) or_return
			case "path":
				cookie.path = value
			case "samesite":
				switch value {
				case "lax", "Lax", "LAX":
					cookie.same_site = .Lax
				case "none", "None", "NONE":
					cookie.same_site = .None
				case "strict", "Strict", "STRICT":
					cookie.same_site = .Strict
				case:
					return
				}
			case:
				return
			}
		}
		return true
	}

	for semicolon = strings.index_byte(remaining, ';'); semicolon != -1; semicolon = strings.index_byte(remaining, ';') {
		part := strings.trim_left_space(remaining[:semicolon])
		remaining = remaining[semicolon + 1:]
		parse_part(&cookie, part, allocator) or_return
	}

	part := strings.trim_left_space(remaining)
	if part == "" {
		ok = true
		return
	}

	parse_part(&cookie, part, allocator) or_return
	ok = true
	return
}

// cookie_date_parse reads a cookie date as RFC 6265 5.1.1 defines it.
cookie_date_parse :: proc(value: string) -> (instant: time.Time, ok: bool) {

	iter_delim :: proc(value: ^string) -> (token: string, ok: bool) {
		start := -1
		start_loop: for character, index in transmute([]byte)value^ {
			switch character {
			case 0x09, 0x20 ..= 0x2F, 0x3B ..= 0x40, 0x5B ..= 0x60, 0x7B ..= 0x7E:
			case:
				start = index
				break start_loop
			}
		}

		if start == -1 {
			return
		}

		token = value[start:]
		length := len(token)
		end_loop: for character, index in transmute([]byte)token {
			switch character {
			case 0x09, 0x20 ..= 0x2F, 0x3B ..= 0x40, 0x5B ..= 0x60, 0x7B ..= 0x7E:
				length = index
				break end_loop
			}
		}

		ok = true

		token = token[:length]
		value^ = value[start + length:]
		return
	}

	parse_digits :: proc(value: string, min, max: int, trailing_ok: bool) -> (int, bool) {
		count: int
		for character in transmute([]byte)value {
			if character <= 0x2f || character >= 0x3a {
				break
			}
			count += 1
		}

		if count < min || count > max {
			return 0, false
		}

		if !trailing_ok && len(value) != count {
			return 0, false
		}

		return strconv.parse_int(value[:count], 10)
	}

	parse_time :: proc(token: string) -> (clock: Time, ok: bool) {
		hours, match1, tail := strings.partition(token, ":")
		if match1 != ":" { return }
		minutes, match2, seconds := strings.partition(tail, ":")
		if match2 != ":" { return }

		clock.hours = parse_digits(hours, 1, 2, false) or_return
		clock.minutes = parse_digits(minutes, 1, 2, false) or_return
		clock.seconds = parse_digits(seconds, 1, 2, true) or_return

		ok = true
		return
	}

	parse_month :: proc(token: string) -> (month: int) {
		if len(token) < 3 {
			return
		}

		lower: [3]byte
		for &character, index in lower {
			#no_bounds_check original := token[index]
			switch original {
			case 'A' ..= 'Z':
				character = original + 32
			case:
				character = original
			}
		}

		switch string(lower[:]) {
		case "jan":
			return 1
		case "feb":
			return 2
		case "mar":
			return 3
		case "apr":
			return 4
		case "may":
			return 5
		case "jun":
			return 6
		case "jul":
			return 7
		case "aug":
			return 8
		case "sep":
			return 9
		case "oct":
			return 10
		case "nov":
			return 11
		case "dec":
			return 12
		case:
			return
		}
	}

	Time :: struct {
		hours, minutes, seconds: int,
	}

	clock: Maybe(Time)
	day_of_month, month, year: Maybe(int)

	remaining := value
	for token in iter_delim(&remaining) {
		if _, has_time := clock.?; !has_time {
			if time_of_day, tok := parse_time(token); tok {
				clock = time_of_day
				continue
			}
		}

		if _, has_day_of_month := day_of_month.?; !has_day_of_month {
			if day, dok := parse_digits(token, 1, 2, true); dok {
				day_of_month = day
				continue
			}
		}

		if _, has_month := month.?; !has_month {
			if parsed_month := parse_month(token); parsed_month > 0 {
				month = parsed_month
				continue
			}
		}

		if _, has_year := year.?; !has_year {
			if parsed_year, yrok := parse_digits(token, 2, 4, true); yrok {

				if parsed_year >= 70 && parsed_year <= 99 {
					parsed_year += 1900
				} else if parsed_year >= 0 && parsed_year <= 69 {
					parsed_year += 2000
				}

				year = parsed_year
				continue
			}
		}
	}

	time_of_day := clock.? or_return
	parsed_year := year.? or_return

	if parsed_year < 1601 {
		return
	}

	instant = time.datetime_to_time(
		parsed_year,
		month.? or_return,
		day_of_month.? or_return,
		time_of_day.hours,
		time_of_day.minutes,
		time_of_day.seconds,
	) or_return

	ok = true
	return
}

/*
Retrieves the cookie with the given `key` out of the requests `Cookie` header.

If the same key is in the header multiple times the last one is returned.
*/
request_cookie_get :: proc(request: ^Request, key: string) -> (value: string, ok: bool) {
	cookies := headers_get_unsafe(request.headers, "cookie") or_return

	for cookie_key, cookie_value in request_cookies_iter(&cookies) {
		if key == cookie_key { return cookie_value, true }
	}

	return
}

/*
Allocates a map with the given allocator and puts all cookie pairs from the requests `Cookie` header into it.

If the same key is in the header multiple times the last one is returned.
*/
request_cookies :: proc(request: ^Request, allocator := context.temp_allocator) -> (result: map[string]string) {
	result.allocator = allocator

	cookie_header := headers_get_unsafe(request.headers, "cookie") or_else ""
	for key, value in request_cookies_iter(&cookie_header) {
		// Don't overwrite, the iterator goes from right to left and we want the last.
		if key in result { continue }

		result[key] = value
	}

	return
}

/*
Iterates the cookies from right to left.
*/
request_cookies_iter :: proc(remaining: ^string) -> (key: string, value: string, ok: bool) {
	end := len(remaining)
	equals := -1
	for i := end - 1; i >= 0; i -= 1 {
		character := remaining[i]
		start := i == 0
		separator := start || character == ' ' && remaining[i - 1] == ';'
		if separator {
			defer end = i - 1

			// Invalid.
			if equals < 0 {
				continue
			}

			offset := 0 if start else 1

			key = remaining[i + offset:equals]
			value = remaining[equals + 1:end]

			remaining^ = remaining[:i - offset]

			return key, value, true
		} else if character == '=' {
			equals = i
		}
	}

	return
}
