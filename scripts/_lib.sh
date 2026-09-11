#!/usr/bin/env bash
# Shared helpers for Nabla task scripts.
#
# NOT executable on purpose: mise only discovers executable files as tasks, so
# leaving the mode bits off keeps this a library and out of `mise tasks`.
#
# Every script sources this, so every script behaves identically whether it was
# started by `mise run <task>` or by `./scripts/<task>` with no mise at all.

# Repo root. mise sets MISE_PROJECT_ROOT; the fallback covers direct execution.
NABLA_ROOT="${MISE_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
readonly NABLA_ROOT

# Directories holding executables or vendored code rather than library
# packages. The package list is derived from the tree, so a package added,
# renamed, or deleted is picked up by every task without editing them.
readonly NABLA_NON_PACKAGE_DIRS="cmd demo examples tests third_party"

# Packages pinned to one test thread, for two different reasons. `agent` and
# `ai` assert on process-global state: the SIGINT disposition and open
# descriptor counts are not meaningful if other tests run concurrently in the
# same process. `layout` is the only package that drives the test runner's
# expected-assertion path, which recovers by trapping and unwinding through the
# signal handler; with several tests free to trap at once the runner segfaults
# at roughly one run in twelve, so its assertions need to be the only ones
# in flight.
readonly NABLA_SERIAL_TEST_PACKAGES="agent ai layout"

# Packages whose suites run through an external harness under tests/ instead of
# `odin test`. Their test files are written against a bespoke assertion harness
# (no `@(test)` declarations, a package-local `run_tests` entry), so `odin test`
# would compile the package and report success while running nothing.
readonly NABLA_HARNESS_TEST_PACKAGES="term"

# Library packages, in dependency order, with sub-packages reported by their
# relative path so `odin check ./term/ansi` works unchanged.
nabla_packages() {
	local d sub base
	for d in "$NABLA_ROOT"/*/; do
		d="${d%/}"
		base="$(basename "$d")"
		[[ " $NABLA_NON_PACKAGE_DIRS " == *" $base "* ]] && continue
		[[ -n "$(compgen -G "$d/*.odin")" ]] || continue
		printf '%s\n' "$base"
		for sub in "$d"/*/; do
			[[ -d "$sub" ]] || continue
			[[ -n "$(compgen -G "${sub%/}/*.odin")" ]] || continue
			printf '%s/%s\n' "$base" "$(basename "${sub%/}")"
		done
	done
}

# Packages carrying in-package test files, and therefore `odin test` targets.
# The glob covers both spellings in the tree (`*_test.odin`, `*_tests.odin`).
# A package main can be tested too: the test runner does not call main.
nabla_test_packages() {
	local pkg
	while IFS= read -r pkg; do
		[[ -n "$(compgen -G "$NABLA_ROOT/$pkg/*_test*.odin")" ]] || continue
		# A bespoke-harness suite is not an `odin test` target.
		case " $NABLA_HARNESS_TEST_PACKAGES " in
			*" $pkg "*) continue ;;
		esac
		printf '%s\n' "$pkg"
	done < <(nabla_check_packages)
}

# Everything owned that has a package clause: the libraries plus every
# executable. `odin check` covers all of them; only libraries build as shared
# objects, and only some carry in-package suites.
nabla_check_packages() {
	nabla_packages
	nabla_executables
}

# External test executables under tests/. These exist because a package name
# that collides with a core package cannot link core:testing; the source
# repositories accumulated them for that reason and this merge keeps them.
nabla_harnesses() {
	local d
	for d in "$NABLA_ROOT"/tests/*/; do
		[[ -f "${d%/}/main.odin" ]] || continue
		printf 'tests/%s\n' "$(basename "${d%/}")"
	done
}

# Executable packages: cmd/* ships, examples/* and demo/ are contract fixtures
# for the presentation stack. Every one of them has a main.
nabla_executables() {
	local d base
	for base in cmd examples; do
		for d in "$NABLA_ROOT/$base"/*/; do
			[[ -f "${d%/}/main.odin" ]] || continue
			printf '%s/%s\n' "$base" "$(basename "${d%/}")"
		done
	done
	if [[ -f "$NABLA_ROOT/demo/main.odin" ]]; then printf 'demo\n'; fi
}

# Owned Odin sources, relative to the repo root. Formatting and listing
# enumerate files rather than directories because odinfmt recurses into them,
# which would reach vendored code in third_party/.
nabla_owned_sources() {
	(
		cd "$NABLA_ROOT" || exit 1
		find . \
			\( -name .jj -o -name .git -o -name third_party -o -name .build -o -name build -o -name .scratch \) -prune -o \
			-name '*.odin' -print | sed 's|^\./||' | sort
	)
}

# Flags kept identical to `checker_args` in ols.json so the editor, the local
# run and CI cannot disagree about what counts as an error.
nabla_vet_flags() {
	printf '%s\n' \
		-vet \
		-strict-style \
		-vet-tabs \
		-disallow-do \
		-warnings-as-errors \
		-no-entry-point \
		"-collection:nabla=$NABLA_ROOT"
}

nabla_collections() {
	printf '%s\n' "-collection:nabla=$NABLA_ROOT"
}

nabla_have() { command -v "$1" >/dev/null 2>&1; }

# odinfmt ships inside the OLS release. When installed through mise the binary
# keeps its release name (odinfmt-x86_64-unknown-linux-gnu), so look for both.
nabla_odinfmt() {
	local c
	for c in odinfmt "odinfmt-$(uname -m)-unknown-linux-gnu"; do
		if nabla_have "$c"; then printf '%s' "$c"; return 0; fi
	done
	return 1
}

nabla_die() { printf 'error: %s\n' "$*" >&2; exit 1; }

nabla_step() { printf '\n==> %s\n' "$*"; }
