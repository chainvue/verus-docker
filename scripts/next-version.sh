#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Compute the next release tag.
#
# The scheme is v<verusd-version>-rN:
#
#   v1.2.17-2-r1   first image built against upstream v1.2.17-2
#   v1.2.17-2-r2   same upstream binary, image-level change (base image bump,
#                  entrypoint fix, new docs shipped in the image, ...)
#
# release-please owns the CHANGELOG; it does not own the version, because this
# scheme has no semver equivalent it can express. This script is the single
# place the next tag is decided, and both the release workflow and a human
# running it by hand get the same answer.
#
# Usage:
#   scripts/next-version.sh              # print the next tag
#   scripts/next-version.sh --current    # print the highest existing tag
#   scripts/next-version.sh --upstream   # print the pinned upstream version

set -euo pipefail

readonly DOCKERFILE="${DOCKERFILE:-Dockerfile}"

die() {
	printf 'next-version: %s\n' "$*" >&2
	exit 1
}

# The Dockerfile's ARG VERUS_VERSION is the single source of truth for which
# upstream release this image is built against.
upstream_version() {
	local version
	version="$(awk -F= '/^ARG VERUS_VERSION=/ {print $2; exit}' "$DOCKERFILE" | tr -d '"'"'"' \r')"
	[[ -n "$version" ]] || die "could not read ARG VERUS_VERSION from ${DOCKERFILE}"
	# Normalise: we want the leading v exactly once.
	printf 'v%s\n' "${version#v}"
}

# Highest existing rN for a given upstream version, or 0 when there is none.
highest_revision() {
	local upstream="$1" highest=0 tag revision

	while read -r tag; do
		[[ -n "$tag" ]] || continue
		revision="${tag##*-r}"
		[[ "$revision" =~ ^[0-9]+$ ]] || continue
		((revision > highest)) && highest="$revision"
	done < <(git tag --list "${upstream}-r*" 2>/dev/null || true)

	printf '%s\n' "$highest"
}

main() {
	local upstream highest

	command -v git >/dev/null 2>&1 || die "git is required"
	[[ -f "$DOCKERFILE" ]] || die "${DOCKERFILE} not found (run from the repository root)"

	upstream="$(upstream_version)"

	case "${1:-}" in
	--upstream)
		printf '%s\n' "$upstream"
		return 0
		;;
	--current)
		highest="$(highest_revision "$upstream")"
		((highest > 0)) || die "no existing release tag for ${upstream}"
		printf '%s-r%s\n' "$upstream" "$highest"
		return 0
		;;
	"" | --next) ;;
	*) die "unknown argument: $1" ;;
	esac

	highest="$(highest_revision "$upstream")"
	printf '%s-r%s\n' "$upstream" "$((highest + 1))"
}

main "$@"
