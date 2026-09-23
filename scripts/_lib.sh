#!/usr/bin/env bash
# Shared helpers for the task scripts. Not executable on purpose: mise only
# discovers executable files as tasks, so this stays out of `mise tasks`.

NABLA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Defines every build, check, and test runs with.
#
# A temporary arena is where the standard library and this harness put memory that
# lives for one call: the arena behind `context.temp_allocator` and the two `core:os`
# keeps for its own path handling. Odin sizes a new arena's first block at four
# mebibytes, and a thread that touches one reserves that whole block. Every tool call
# runs on a fresh thread, so a call needing a few kilobytes for its arguments, a path,
# and a stat would reserve eight mebibytes across those arenas, once per call. The
# define sets the block granularity instead: a call commits what it touches, and an
# arena still grows by whole blocks when one call needs more.
NABLA_DEFINES=(-define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=65536)

# Every package runs its core:testing suite on the runner's default thread
# count (the machine's cores). Tests that mutate process-global state (the
# cancel token, signal dispositions, environment variables) isolate themselves
# by re-running in a child of the test binary; see agent/isolate_test.odin.
# No package is pinned to one thread.
# Packages whose core:testing suites must not be discovered by `odin test`
# because an external harness runs them instead. Empty once every suite is on
# core:testing.
NABLA_HARNESS_TEST_PACKAGES=""

nabla_packages() {
	local d sub base
	for d in "$NABLA_ROOT"/*/; do
		d="${d%/}"
		base="$(basename "$d")"
		[[ -n "$(compgen -G "$d/*.odin")" ]] || continue
		printf '%s\n' "$base"
		for sub in "$d"/*/; do
			[[ -d "$sub" ]] || continue
			[[ -n "$(compgen -G "${sub%/}/*.odin")" ]] || continue
			printf '%s/%s\n' "$base" "$(basename "${sub%/}")"
		done
	done
}

nabla_test_packages() {
	local pkg
	while IFS= read -r pkg; do
		[[ -n "$(compgen -G "$NABLA_ROOT/$pkg/*_test*.odin")" ]] || continue
		case " $NABLA_HARNESS_TEST_PACKAGES " in
			*" $pkg "*) continue ;;
		esac
		printf '%s\n' "$pkg"
	done < <(nabla_check_packages)
}

nabla_check_packages() {
	nabla_packages
	nabla_executables
}

nabla_harnesses() {
	local d
	# In-package executable harnesses that cannot run under `odin test`.
	# Empty: every suite currently runs through the native test interface.
	for d in "$NABLA_ROOT"/*/test/*/; do
		d="${d%/}"
		[[ -f "$d/main.odin" ]] || continue
		printf '%s\n' "${d#"$NABLA_ROOT"/}"
	done
}

nabla_executables() {
	# The harness is the repository root package.
	if [[ -f "$NABLA_ROOT/main.odin" ]]; then
		printf '.\n'
	fi
}

nabla_owned_sources() {
	(
		cd "$NABLA_ROOT" || exit 1
		find . \
			\( -name .jj -o -name .git -o -name build \) -prune -o \
			-name '*.odin' -print | sed 's|^\./||' | sort
	)
}

nabla_die() { printf 'error: %s\n' "$*" >&2; exit 1; }

nabla_step() { printf '\n==> %s\n' "$*"; }
