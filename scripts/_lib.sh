#!/usr/bin/env bash
# Shared helpers for the task scripts. Not executable on purpose: mise only
# discovers executable files as tasks, so this stays out of `mise tasks`.

NABLA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NABLA_NON_PACKAGE_DIRS="cmd third_party"
NABLA_SERIAL_TEST_PACKAGES="agent ai layout"
# Packages whose core:testing suites must not be discovered by `odin test`
# because an external harness runs them instead. Empty once every suite is on
# core:testing.
NABLA_HARNESS_TEST_PACKAGES=""

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
	# In-package executable harnesses that cannot run under `odin test`
	# (for example term/test/lifecycle, which forks).
	for d in "$NABLA_ROOT"/*/test/*/; do
		d="${d%/}"
		[[ -f "$d/main.odin" ]] || continue
		printf '%s\n' "${d#"$NABLA_ROOT"/}"
	done
}

nabla_executables() {
	local d
	for d in "$NABLA_ROOT/cmd"/*/; do
		[[ -f "${d%/}/main.odin" ]] || continue
		printf 'cmd/%s\n' "$(basename "${d%/}")"
	done
}

nabla_owned_sources() {
	(
		cd "$NABLA_ROOT" || exit 1
		find . \
			\( -name .jj -o -name .git -o -name third_party -o -name build -o -name .scratch \) -prune -o \
			-name '*.odin' -print | sed 's|^\./||' | sort
	)
}

nabla_die() { printf 'error: %s\n' "$*" >&2; exit 1; }

nabla_step() { printf '\n==> %s\n' "$*"; }
