package db

import "core:math"

// Value is one SQL value. Its zero value, nil, is SQL NULL; an empty string and
// a zero-length blob are values, not NULL.
//
// A row's string and []u8 cases are views into backend storage, are read-only,
// and are valid only until the result set moves on. A Value given as an argument
// is borrowed only for the call that consumes it.
//
// A zero-length string or blob may come back with a nil data pointer, so len is
// what says whether there is anything there. Both are empty values, and neither
// is NULL.
Value :: union {
	i64,
	f64,
	bool,
	string,
	[]u8,
}

// -(2^63) and 2^63. The latter is the first float above the i64 range and is
// exactly representable, so the test below is a half-open range.
@(private)
I64_MIN_F64 :: -9223372036854775808.0

@(private)
I64_MAX_F64 :: 9223372036854775808.0

// as_i64 returns value as an integer. A bool widens to 1 or 0. A float converts
// only when it is a whole number inside the i64 range, so reading a count that
// arrived as a double works but rounding a measurement does not. Text, blobs,
// and NULL do not convert.
@(require_results)
as_i64 :: proc(value: Value) -> (number: i64, err: Error) {
	switch member in value {
	case i64:
		return member, nil
	case f64:
		// NaN orders false against both bounds, so it needs its own refusal.
		if math.is_nan(member) {
			return 0, error_make(.Out_Of_Range, 0, "NaN has no integer value")
		}
		if member < I64_MIN_F64 || member >= I64_MAX_F64 {
			return 0, error_make(.Out_Of_Range, 0, "float is outside the i64 range")
		}
		number = i64(member)
		if f64(number) != member {
			return 0, error_make(.Out_Of_Range, 0, "float is not a whole number")
		}
		return number, nil
	case bool:
		return 1 if member else 0, nil
	case string, []u8:
		return 0, error_make(.Type_Mismatch, 0, "value is not an integer")
	case:
		return 0, error_make(.Null_Value, 0, "value is NULL")
	}
}

// as_f64 returns value as a float. An integer converts only when the float can hold
// it exactly, so a value above 2^53 is an error rather than a rounded number.
@(require_results)
as_f64 :: proc(value: Value) -> (number: f64, err: Error) {
	switch member in value {
	case f64:
		return member, nil
	case i64:
		number = f64(member)
		// Round-tripping has to check the range before converting back: a
		// float at 2^63 cannot become an i64.
		if number < I64_MIN_F64 || number >= I64_MAX_F64 || i64(number) != member {
			return 0, error_make(.Out_Of_Range, 0, "integer is not exactly representable as a float")
		}
		return number, nil
	case bool:
		return 1 if member else 0, nil
	case string, []u8:
		return 0, error_make(.Type_Mismatch, 0, "value is not a float")
	case:
		return 0, error_make(.Null_Value, 0, "value is NULL")
	}
}

// as_bool returns value as a boolean. A bool converts directly; an integer
// converts only when it is 0 or 1. Text and floats do not convert.
@(require_results)
as_bool :: proc(value: Value) -> (result: bool, err: Error) {
	switch member in value {
	case bool:
		return member, nil
	case i64:
		if member == 0 { return false, nil }
		if member == 1 { return true, nil }
		return false, error_make(.Out_Of_Range, 0, "integer is neither 0 nor 1")
	case f64, string, []u8:
		return false, error_make(.Type_Mismatch, 0, "value is not a boolean")
	case:
		return false, error_make(.Null_Value, 0, "value is NULL")
	}
}

// as_string returns value as text. Only the text case converts; use as_bytes for
// a blob. The result aliases the same storage as value.
@(require_results)
as_string :: proc(value: Value) -> (text: string, err: Error) {
	switch member in value {
	case string:
		return member, nil
	case i64, f64, bool, []u8:
		return "", error_make(.Type_Mismatch, 0, "value is not text")
	case:
		return "", error_make(.Null_Value, 0, "value is NULL")
	}
}

// as_bytes returns value as a blob. Only the blob case converts; use as_string
// for text. The result aliases the same storage as value.
@(require_results)
as_bytes :: proc(value: Value) -> (bytes: []u8, err: Error) {
	switch member in value {
	case []u8:
		return member, nil
	case i64, f64, bool, string:
		return nil, error_make(.Type_Mismatch, 0, "value is not a blob")
	case:
		return nil, error_make(.Null_Value, 0, "value is NULL")
	}
}
