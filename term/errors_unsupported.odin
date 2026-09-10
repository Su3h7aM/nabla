#+build !linux
package term

// _Platform_Error on targets without a backend: a placeholder so the
// portable Error union compiles. No operation produces it — session calls
// return General_Error.Unsupported.
_Platform_Error :: enum u32 {
	None,
}
