#+test
package http

import "core:testing"
import "core:time"

// The date field of an HTTP message. A recipient has to read three formats, of
// which only one may be written, so these cases cover all three and the shapes
// that are none of them.
@(test)
test_http_date_parse :: proc(t: ^testing.T) {
	// IMF-fixdate, which is the only format this package writes.
	imf, imf_ok := date_parse("Sun, 06 Nov 1994 08:49:37 GMT")
	if testing.expect(t, imf_ok) {
		testing.expect_value(t, time.year(imf), 1994)
		testing.expect_value(t, time.month(imf), time.Month.November)
		testing.expect_value(t, time.day(imf), 6)
		hour, minute, second := time.clock_from_time(imf)
		testing.expect_value(t, hour, 8)
		testing.expect_value(t, minute, 49)
		testing.expect_value(t, second, 37)
	}

	// rfc850-date: a two-digit year is read as a past one when that is what it
	// would have to be, so this is 1994 and not 2094.
	obs, obs_ok := date_parse("Sunday, 06-Nov-94 08:49:37 GMT")
	if testing.expect(t, obs_ok) {
		testing.expect_value(t, time.year(obs), 1994)
		testing.expect_value(t, time.day(obs), 6)
	}

	// asctime-date: its day is one digit padded with a space.
	asctime, asctime_ok := date_parse("Sun Nov  6 08:49:37 1994")
	if testing.expect(t, asctime_ok) {
		testing.expect_value(t, time.year(asctime), 1994)
		testing.expect_value(t, time.month(asctime), time.Month.November)
		testing.expect_value(t, time.day(asctime), 6)
		hour, minute, second := time.clock_from_time(asctime)
		testing.expect_value(t, hour, 8)
		testing.expect_value(t, minute, 49)
		testing.expect_value(t, second, 37)
	}

	// The same instant in all three formats is the same time.
	testing.expect_value(t, imf, obs)
	testing.expect_value(t, imf, asctime)
}

@(test)
test_http_date_parse_rejects_everything_else :: proc(t: ^testing.T) {
	rejected := []string {
		"",
		"Fri, 05 Feb 2023 09:01:10 UTC", // the zone is GMT, and only GMT
		"Fri, 05 Feb 2023 09:01:10", // and it is not optional
		"Fri, 5 Feb 2023 09:01:10 GMT", // the day is two digits
		"Fri, 05 feb 2023 09:01:10 GMT", // month names are case-sensitive
		"Xxx, 05 Feb 2023 09:01:10 GMT", // an unknown weekday
		"Fri, 05 Feb 2023 9:01:10 GMT", // the clock is two digits per field
		"Fri, 32 Feb 2023 09:01:10 GMT", // a day the calendar does not have
		"Fri, 05 Foo 2023 09:01:10 GMT",
		"2030-01-01T00:00:00Z", // ISO 8601 is not an HTTP date
		"Fri, 05 Feb 2023 09:01:10 GMT ", // and neither is anything with a suffix
	}
	for value in rejected {
		_, ok := date_parse(value)
		testing.expectf(t, !ok, "%q must not be read as an HTTP date", value)
	}
}

// A date this package writes is a date it reads back, which is the one property
// that keeps the writer and the reader of the format from drifting apart.
@(test)
test_http_date_round_trip :: proc(t: ^testing.T) {
	// An HTTP date carries whole seconds, so the case taken from the clock is built
	// from the clock's own components.
	year, month, day := time.date(time.now())
	hour, minute, second := time.clock_from_time(time.now())
	instants := []time.Time {
		time.datetime_to_time(year, month, day, hour, minute, second),
		time.datetime_to_time(1970, 1, 1, 0, 0, 0),
		time.datetime_to_time(1994, 11, 6, 8, 49, 37),
		time.datetime_to_time(2024, 2, 29, 23, 59, 59),
	}
	for instant in instants {
		text := date_string(instant, context.temp_allocator)
		testing.expect_value(t, len(text), HTTP_DATE_LENGTH)
		parsed, ok := date_parse(text)
		if !testing.expectf(t, ok, "%q must read back", text) { continue }
		testing.expectf(t, parsed == instant, "%q: expected %v, got %v", text, instant, parsed)
	}
}
