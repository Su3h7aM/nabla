#+build !linux
package main

// process_name_set is the portable no-op: only Linux carries a process name a
// monitor shows, so every other target keeps the binary's own name.
process_name_set :: proc(name: string) {  }
