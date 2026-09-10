package main

// External harness for the term package's in-package suites.
//
// The suites are written against a package-local assertion harness (a `T`
// context, `expect`, and a `run_tests` entry) rather than core:testing's
// `@(test)` declarations, so `odin test ./term` would compile the package and
// report success while executing nothing. scripts/test runs this harness with
// `odin run` instead. Moving the suites onto core:testing is a later cleanup.
import "core:os"
import "nabla:term"

main :: proc() {
	if !term.run_tests() {
		os.exit(1)
	}
}
