#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Pin the Dockerfile to a new upstream VerusCoin release.
#
# Upstream publishes no SHA256SUMS, .asc or .sig asset, and the hashes in the
# release notes reference nothing that ships in the release (verified against
# v1.2.17-2: they match neither the outer .tgz, the inner .tar.gz, nor any
# extracted file). The root of trust is therefore a checksum pinned in this
# repository and reviewed by a human.
#
# This script downloads both architecture assets, computes their SHA-256, and
# rewrites the Dockerfile ARGs. It is run by the upstream-watch workflow, which
# opens a pull request — it never merges anything on its own.
#
# Usage:
#   scripts/bump-upstream.sh                # bump to the newest stable release
#   scripts/bump-upstream.sh v1.2.18        # bump to a specific tag

set -euo pipefail

readonly DOCKERFILE="${DOCKERFILE:-Dockerfile}"
readonly RELEASES_API="https://api.github.com/repos/VerusCoin/VerusCoin/releases"
readonly DOWNLOAD_BASE="https://github.com/VerusCoin/VerusCoin/releases/download"
readonly EXPECTED_SIGNER="Verus Coin Foundation Releases@"

die() {
	printf 'bump-upstream: %s\n' "$*" >&2
	exit 1
}

note() { printf '>> %s\n' "$*" >&2; }

latest_stable_tag() {
	curl --fail --silent --show-error "$RELEASES_API" |
		jq -r 'map(select(.draft == false and .prerelease == false)) | .[0].tag_name'
}

current_tag() {
	awk -F= '/^ARG VERUS_VERSION=/ {print $2; exit}' "$DOCKERFILE" | tr -d '"'"'"' \r'
}

# Downloads an asset, hashes it, and sanity-checks the archive structure so a
# renamed or restructured release fails here rather than in the image build.
hash_asset() {
	local tag="$1" arch="$2" workdir="$3"
	local asset="Verus-CLI-Linux-${tag}-${arch}.tgz"
	local url="${DOWNLOAD_BASE}/${tag}/${asset}"
	local inner embedded_hash embedded_signer actual

	note "downloading ${asset}"
	curl --fail --silent --show-error --location --retry 3 \
		--output "${workdir}/${asset}" "$url" ||
		die "could not download ${url}"

	# The release is a tarball inside a tarball; verify the inner one carries a
	# signature file that matches it and is signed by the expected identity.
	tar -xzf "${workdir}/${asset}" -C "$workdir"
	inner="${workdir}/Verus-CLI-Linux-${tag}-${arch}.tar.gz"
	[[ -f "$inner" ]] || die "${asset} did not contain the expected inner tarball"
	[[ -f "${inner}.signature.txt" ]] || die "${asset} has no signature file"

	embedded_hash="$(jq -r '.hash' "${inner}.signature.txt")"
	embedded_signer="$(jq -r '.signer' "${inner}.signature.txt")"
	actual="$(sha256sum "$inner" | cut -d' ' -f1)"

	[[ "$embedded_hash" == "$actual" ]] ||
		die "${arch}: signature file hash ${embedded_hash} != actual ${actual}"
	[[ "$embedded_signer" == "$EXPECTED_SIGNER" ]] ||
		die "${arch}: unexpected signer '${embedded_signer}'"

	note "${arch}: inner tarball verified, signed by ${embedded_signer}"
	sha256sum "${workdir}/${asset}" | cut -d' ' -f1
}

main() {
	local tag current workdir sha_amd64 sha_arm64

	command -v jq >/dev/null 2>&1 || die "jq is required"
	[[ -f "$DOCKERFILE" ]] || die "${DOCKERFILE} not found (run from the repository root)"

	tag="${1:-$(latest_stable_tag)}"
	[[ -n "$tag" && "$tag" != "null" ]] || die "could not determine the upstream release tag"

	current="$(current_tag)"
	note "current: ${current}"
	note "target:  ${tag}"

	if [[ "$tag" == "$current" ]]; then
		note "already up to date"
		return 0
	fi

	workdir="$(mktemp -d)"
	# shellcheck disable=SC2064  # expand workdir now, not at trap time
	trap "rm -rf -- '${workdir}'" EXIT

	sha_amd64="$(hash_asset "$tag" "x86_64" "$workdir")"
	rm -f "${workdir}"/*.tar.gz "${workdir}"/*.signature.txt
	sha_arm64="$(hash_asset "$tag" "arm64" "$workdir")"

	note "amd64 ${sha_amd64}"
	note "arm64 ${sha_arm64}"

	# Rewrite in place. These three lines are the only pinned state.
	sed -i.bak \
		-e "s|^ARG VERUS_VERSION=.*|ARG VERUS_VERSION=${tag}|" \
		-e "s|^ARG VERUS_SHA256_AMD64=.*|ARG VERUS_SHA256_AMD64=${sha_amd64}|" \
		-e "s|^ARG VERUS_SHA256_ARM64=.*|ARG VERUS_SHA256_ARM64=${sha_arm64}|" \
		"$DOCKERFILE"
	rm -f "${DOCKERFILE}.bak"

	# Fail loudly rather than opening a pull request that changes nothing.
	grep -q "ARG VERUS_VERSION=${tag}" "$DOCKERFILE" || die "failed to update ${DOCKERFILE}"
	grep -q "ARG VERUS_SHA256_AMD64=${sha_amd64}" "$DOCKERFILE" || die "failed to update the amd64 hash"
	grep -q "ARG VERUS_SHA256_ARM64=${sha_arm64}" "$DOCKERFILE" || die "failed to update the arm64 hash"

	note "updated ${DOCKERFILE} to ${tag}"

	# Consumed by the workflow to build the pull request body.
	if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
		{
			echo "old_version=${current}"
			echo "new_version=${tag}"
			echo "sha_amd64=${sha_amd64}"
			echo "sha_arm64=${sha_arm64}"
		} >>"$GITHUB_OUTPUT"
	fi
}

main "$@"
