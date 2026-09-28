package http

// The date field of an HTTP message (RFC 9110 5.6.1).
//
// A sender writes IMF-fixdate and nothing else. A recipient has to read two
// formats that were obsolete long before this codebase existed, because peers
// still emit them, so all three grammars live here. None of them is ISO 8601 or
// RFC 3339, and none of them may be given to a parser for either.

import "core:io"
import "core:slice"
import "core:strings"
import "core:time"

// HTTP_DATE_LENGTH is the length of an IMF-fixdate, the only format this package
// writes.
HTTP_DATE_LENGTH :: len("Fri, 05 Feb 2023 09:01:10 GMT")

// HTTP_DATE_GMT is the zone every HTTP date grammar ends with. An HTTP date is
// always UTC, so no offset is parsed and none is written.
HTTP_DATE_GMT :: "GMT"

// HTTP_DATE_CENTURY_WINDOW is how far an rfc850-date may lie in the future
// before its two-digit year is read as a past one (RFC 9110 5.6.1).
HTTP_DATE_CENTURY_WINDOW :: 50

HTTP_DATE_WEEKDAYS_SHORT := [7]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}

HTTP_DATE_WEEKDAYS_LONG := [7]string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}

HTTP_DATE_MONTHS := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

// date_write writes instant as an IMF-fixdate, the one HTTP date format a sender
// may use, with no timezone conversion: `<day-name>, <day> <month> <year>
// <hour>:<minute>:<second> GMT`.
date_write :: proc(writer: io.Writer, instant: time.Time) -> io.Error {
	year, month, day := time.date(instant)
	hour, minute, second := time.clock_from_time(instant)
	weekday := time.weekday(instant)

	io.write_string(writer, HTTP_DATE_WEEKDAYS_SHORT[weekday]) or_return
	io.write_string(writer, ", ") or_return
	write_padded_int(writer, day) or_return
	io.write_byte(writer, ' ') or_return
	io.write_string(writer, date_month_name(month)) or_return
	io.write_byte(writer, ' ') or_return
	io.write_int(writer, year) or_return
	io.write_byte(writer, ' ') or_return
	write_padded_int(writer, hour) or_return
	io.write_byte(writer, ':') or_return
	write_padded_int(writer, minute) or_return
	io.write_byte(writer, ':') or_return
	write_padded_int(writer, second) or_return
	io.write_string(writer, " GMT") or_return

	return nil
}

// date_string returns instant formatted as date_write writes it, owned by the
// caller's allocator.
date_string :: proc(instant: time.Time, allocator := context.allocator) -> string {
	builder: strings.Builder

	buffer := make([]byte, HTTP_DATE_LENGTH, allocator)
	builder.buf = slice.into_dynamic(buffer)

	date_write(strings.to_writer(&builder), instant)

	return strings.to_string(builder)
}

// date_parse reads one HTTP date in any of the three formats a recipient
// accepts. Each parser validates the shape it expects, so a text that fails one
// grammar is tried against the next rather than guessed at.
date_parse :: proc(value: string) -> (instant: time.Time, ok: bool) {
	if parsed, parsed_ok := date_parse_imf(value); parsed_ok { return parsed, true }
	if parsed, parsed_ok := date_parse_rfc850(value); parsed_ok { return parsed, true }
	return date_parse_asctime(value)
}

// date_parse_imf reads `Sun, 06 Nov 1994 08:49:37 GMT`, the format this package
// writes and the one a modern peer sends.
date_parse_imf :: proc(value: string) -> (instant: time.Time, ok: bool) {
	if len(value) != HTTP_DATE_LENGTH { return }
	if value[3] != ',' ||
	   value[7] != ' ' ||
	   value[11] != ' ' ||
	   value[16] != ' ' ||
	   value[19] != ':' ||
	   value[22] != ':' ||
	   value[25] != ' ' ||
	   value[26:] != HTTP_DATE_GMT { return }
	if !date_weekday(value[:3], HTTP_DATE_WEEKDAYS_SHORT[:]) { return }
	day, day_ok := date_digits(value[5:7])
	month, month_ok := date_month(value[8:11])
	year, year_ok := date_digits(value[12:16])
	hour, hour_ok := date_digits(value[17:19])
	minute, minute_ok := date_digits(value[20:22])
	second, second_ok := date_digits(value[23:25])
	if !day_ok || !month_ok || !year_ok || !hour_ok || !minute_ok || !second_ok { return }
	return time.datetime_to_time(year, month, day, hour, minute, second)
}

// date_parse_rfc850 reads `Sunday, 06-Nov-94 08:49:37 GMT`. Its year has two
// digits, so the century is fixed at receipt: a date that would be more than
// fifty years in the future is the most recent past year with the same last two
// digits.
date_parse_rfc850 :: proc(value: string) -> (instant: time.Time, ok: bool) {
	comma := strings.index_byte(value, ',')
	if comma < 0 || !date_weekday(value[:comma], HTTP_DATE_WEEKDAYS_LONG[:]) { return }
	// ` DD-MMM-YY HH:MM:SS GMT`
	rest := value[comma + 1:]
	if len(rest) != 23 || rest[0] != ' ' { return }
	if rest[3] != '-' || rest[7] != '-' || rest[10] != ' ' || rest[13] != ':' || rest[16] != ':' || rest[19] != ' ' || rest[20:] != HTTP_DATE_GMT { return }
	day, day_ok := date_digits(rest[1:3])
	month, month_ok := date_month(rest[4:7])
	short_year, year_ok := date_digits(rest[8:10])
	hour, hour_ok := date_digits(rest[11:13])
	minute, minute_ok := date_digits(rest[14:16])
	second, second_ok := date_digits(rest[17:19])
	if !day_ok || !month_ok || !year_ok || !hour_ok || !minute_ok || !second_ok { return }
	year := 2000 + short_year
	if year - time.year(time.now()) > HTTP_DATE_CENTURY_WINDOW { year -= 100 }
	return time.datetime_to_time(year, month, day, hour, minute, second)
}

// date_parse_asctime reads `Sun Nov  6 08:49:37 1994`, whose day is either two
// digits or one digit padded with a space.
date_parse_asctime :: proc(value: string) -> (instant: time.Time, ok: bool) {
	if len(value) != 24 { return }
	if value[3] != ' ' || value[7] != ' ' || value[10] != ' ' || value[13] != ':' || value[16] != ':' || value[19] != ' ' { return }
	if !date_weekday(value[:3], HTTP_DATE_WEEKDAYS_SHORT[:]) { return }
	month, month_ok := date_month(value[4:7])
	day_field := value[8:10]
	day, day_ok := date_digits(day_field if day_field[0] != ' ' else day_field[1:])
	hour, hour_ok := date_digits(value[11:13])
	minute, minute_ok := date_digits(value[14:16])
	second, second_ok := date_digits(value[17:19])
	year, year_ok := date_digits(value[20:24])
	if !day_ok || !month_ok || !year_ok || !hour_ok || !minute_ok || !second_ok { return }
	return time.datetime_to_time(year, month, day, hour, minute, second)
}

// date_digits reads one field of ASCII digits, however many the field's own
// grammar allows. It accepts nothing else: a sign, a space, or an empty field is
// a value this parser does not read.
date_digits :: proc(text: string) -> (value: int, ok: bool) {
	if len(text) == 0 { return }
	for character in text {
		if character < '0' || character > '9' { return }
		value = value * 10 + int(character - '0')
	}
	return value, true
}

// date_month reads a month name. The names are case-sensitive: every HTTP date
// grammar writes them exactly as they appear here.
date_month :: proc(text: string) -> (month: int, ok: bool) {
	for name, i in HTTP_DATE_MONTHS {
		if text == name { return i + 1, true }
	}
	return 0, false
}

date_weekday :: proc(text: string, names: []string) -> bool {
	for name in names {
		if text == name { return true }
	}
	return false
}

date_month_name :: proc(month: time.Month) -> string {
	if month < .January || month > .December { return "" }
	return HTTP_DATE_MONTHS[int(month) - 1]
}

@(private)
write_padded_int :: proc(writer: io.Writer, value: int) -> io.Error {
	if value < 10 {
		io.write_string(writer, PADDED_NUMS[value]) or_return
		return nil
	}

	_, err := io.write_int(writer, value)
	return err
}

@(private)
PADDED_NUMS := [10]string{"00", "01", "02", "03", "04", "05", "06", "07", "08", "09"}
