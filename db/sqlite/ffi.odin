#+private
package sqlite

import "core:c"

// The raw SQLite interface, private to this package. Nothing here is part of
// `nabla:sqlite`'s public surface: outside code reaches SQLite through db.Conn
// or not at all.
//
// Only the pieces this backend uses are declared. They are the newest form of
// each call: open_v2, prepare_v3, close_v2, and the 64-bit bind variants.

foreign import lib "system:sqlite3"

sqlite3 :: struct {}
sqlite3_stmt :: struct {}

sqlite3_int64 :: i64
sqlite3_uint64 :: u64

// Destructor is C's sqlite3_destructor_type: either a callback that frees the
// buffer, or one of two sentinels. behaviour is pointer-sized so that -1 fills
// the whole pointer; a 4-byte field would leave the high half zero and hand
// SQLite a callback address of 0xFFFFFFFF.
//
//   -1  copy the bytes before returning (SQLITE_TRANSIENT)
//    0  the buffer outlives the binding (SQLITE_STATIC)
Destructor :: struct #raw_union {
	callback:  proc "c" (_: rawptr),
	behaviour: c.intptr_t,
}

// Result_Code is the primary result of every interface that returns int. An
// extended code, which only extended_errcode reports, is the primary code in
// its low byte.
Result_Code :: enum (c.int) {
	OK         = 0,
	Error      = 1,
	Internal   = 2,
	Perm       = 3,
	Abort      = 4,
	Busy       = 5,
	Locked     = 6,
	No_Mem     = 7,
	Read_Only  = 8,
	Interrupt  = 9,
	IO_Error   = 10,
	Corrupt    = 11,
	Not_Found  = 12,
	Full       = 13,
	Cant_Open  = 14,
	Protocol   = 15,
	Empty      = 16,
	Schema     = 17,
	Too_Big    = 18,
	Constraint = 19,
	Mismatch   = 20,
	Misuse     = 21,
	No_LFS     = 22,
	Auth       = 23,
	Format     = 24,
	Range      = 25,
	Not_A_DB   = 26,
	Notice     = 27,
	Warning    = 28,
	Row        = 100,
	Done       = 101,
}

// Column_Type is a result column's storage class, as reported by column_type.
// The numbering is SQLite's own datatype codes, not a result code.
Column_Type :: enum (c.int) {
	Integer = 1,
	Float   = 2,
	Text    = 3,
	Blob    = 4,
	Null    = 5,
}

OPEN_READWRITE :: 0x00000002
OPEN_CREATE :: 0x00000004

// UTF8 is the text encoding a bound string is read as; the byte count is given
// alongside it, so no NUL terminator is required.
UTF8 :: 1

@(default_calling_convention = "c")
@(link_prefix = "sqlite3_")
foreign lib {
	open_v2 :: proc(filename: cstring, db: ^^sqlite3, flags: c.int, vfs: cstring) -> Result_Code ---
	close_v2 :: proc(db: ^sqlite3) -> Result_Code ---
	busy_timeout :: proc(db: ^sqlite3, ms: c.int) -> Result_Code ---

	prepare_v3 :: proc(db: ^sqlite3, sql: cstring, n: c.int, flags: c.uint, stmt: ^^sqlite3_stmt, tail: ^cstring) -> Result_Code ---
	step :: proc(stmt: ^sqlite3_stmt) -> Result_Code ---
	reset :: proc(stmt: ^sqlite3_stmt) -> Result_Code ---
	finalize :: proc(stmt: ^sqlite3_stmt) -> Result_Code ---

	bind_parameter_count :: proc(stmt: ^sqlite3_stmt) -> c.int ---
	bind_int64 :: proc(stmt: ^sqlite3_stmt, i: c.int, value: sqlite3_int64) -> Result_Code ---
	bind_double :: proc(stmt: ^sqlite3_stmt, i: c.int, value: f64) -> Result_Code ---
	bind_null :: proc(stmt: ^sqlite3_stmt, i: c.int) -> Result_Code ---
	bind_text64 :: proc(stmt: ^sqlite3_stmt, i: c.int, text: cstring, n: sqlite3_uint64, d: Destructor, encoding: u8) -> Result_Code ---
	bind_blob64 :: proc(stmt: ^sqlite3_stmt, i: c.int, blob: rawptr, n: sqlite3_uint64, d: Destructor) -> Result_Code ---

	column_count :: proc(stmt: ^sqlite3_stmt) -> c.int ---
	column_type :: proc(stmt: ^sqlite3_stmt, i: c.int) -> Column_Type ---
	column_int64 :: proc(stmt: ^sqlite3_stmt, i: c.int) -> sqlite3_int64 ---
	column_double :: proc(stmt: ^sqlite3_stmt, i: c.int) -> f64 ---
	column_text :: proc(stmt: ^sqlite3_stmt, i: c.int) -> [^]u8 ---
	column_blob :: proc(stmt: ^sqlite3_stmt, i: c.int) -> rawptr ---
	column_bytes :: proc(stmt: ^sqlite3_stmt, i: c.int) -> c.int ---

	extended_errcode :: proc(db: ^sqlite3) -> c.int ---
	errmsg :: proc(db: ^sqlite3) -> cstring ---
	get_autocommit :: proc(db: ^sqlite3) -> c.int ---
}
