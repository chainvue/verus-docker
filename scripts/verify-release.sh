#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Cryptographically verify an upstream VerusCoin release against the signing
# identity recorded on the Verus blockchain.
#
# Every release tarball ships a .signature.txt holding a VerusID signature over
# the SHA-256 of its contents. Checking that signature needs a Verus node to
# resolve the identity on chain — which a container build cannot do, but a
# script with network access can, by asking any node's RPC.
#
# By default it asks the public gateway the Verus wallet uses. Point
# VERIFY_RPC_URL at your own node if you would rather not trust it; the answer
# should be identical, and disagreeing answers are themselves informative.
#
# Usage:
#   scripts/verify-release.sh               # the version pinned in the Dockerfile
#   scripts/verify-release.sh v1.2.18       # a specific tag
#
# Exit codes:
#   0  every architecture verified
#   1  a signature was rejected — do not ship this
#   2  could not reach a node to ask; nothing was proven either way

set -euo pipefail

readonly DOCKERFILE="${DOCKERFILE:-Dockerfile}"
readonly DOWNLOAD_BASE="https://github.com/VerusCoin/VerusCoin/releases/download"
readonly VERIFY_RPC_URL="${VERIFY_RPC_URL:-https://api.verus.services/}"
readonly EXPECTED_SIGNER="${EXPECTED_SIGNER:-Verus Coin Foundation Releases@}"

note() { printf '>> %s\n' "$*" >&2; }
die() {
	printf 'verify-release: %s\n' "$*" >&2
	exit 1
}

# rpc <method> <params-json> — prints the result member, or nothing on failure.
rpc() {
	local method="$1" params="$2" response
	response="$(curl --fail --silent --show-error --max-time 45 \
		--header 'Content-Type: application/json' \
		--data "{\"jsonrpc\":\"1.0\",\"id\":\"verify\",\"method\":\"${method}\",\"params\":${params}}" \
		"$VERIFY_RPC_URL" 2>/dev/null)" || return 1
	jq -e -r '.result' <<<"$response" 2>/dev/null
}

main() {
	local tag workdir arch asset inner sig hash signer result
	local verified=0 rejected=0 unreachable=0

	command -v jq >/dev/null 2>&1 || die "jq is required"

	tag="${1:-}"
	if [[ -z "$tag" ]]; then
		[[ -f "$DOCKERFILE" ]] || die "${DOCKERFILE} not found (run from the repository root)"
		tag="$(awk -F= '/^ARG VERUS_VERSION=/ {print $2; exit}' "$DOCKERFILE" | tr -d '"'"'"' \r')"
	fi
	[[ -n "$tag" ]] || die "could not determine which release to verify"

	note "release:  ${tag}"
	note "asking:   ${VERIFY_RPC_URL}"
	note "expected: ${EXPECTED_SIGNER}"

	# A node that cannot resolve the identity cannot verify anything, so say so
	# rather than reporting a misleading failure.
	if ! rpc getidentity "[\"${EXPECTED_SIGNER}\"]" >/dev/null 2>&1; then
		note "could not resolve '${EXPECTED_SIGNER}' — the node is unreachable, not synced,"
		note "or does not serve getidentity. Nothing has been proven either way."
		return 2
	fi

	workdir="$(mktemp -d)"
	# shellcheck disable=SC2064  # expand now, not at trap time
	trap "rm -rf -- '${workdir}'" EXIT

	for arch in x86_64 arm64; do
		asset="Verus-CLI-Linux-${tag}-${arch}.tgz"
		note "fetching ${asset}"
		if ! curl --fail --silent --show-error --location --retry 3 \
			--output "${workdir}/${asset}" "${DOWNLOAD_BASE}/${tag}/${asset}"; then
			note "  ${arch}: download failed"
			unreachable=$((unreachable + 1))
			continue
		fi

		tar -xzf "${workdir}/${asset}" -C "$workdir"
		inner="${workdir}/Verus-CLI-Linux-${tag}-${arch}.tar.gz"
		[[ -f "${inner}.signature.txt" ]] || die "${arch}: no signature file in the release"

		sig="$(jq -r '.signature' "${inner}.signature.txt")"
		hash="$(jq -r '.hash' "${inner}.signature.txt")"
		signer="$(jq -r '.signer' "${inner}.signature.txt")"

		# The signature covers the hash, so confirm the hash covers the file.
		if [[ "$(sha256sum "$inner" | cut -d' ' -f1)" != "$hash" ]]; then
			note "  ${arch}: REJECTED — signature file's hash does not match the tarball"
			rejected=$((rejected + 1))
			continue
		fi
		if [[ "$signer" != "$EXPECTED_SIGNER" ]]; then
			note "  ${arch}: REJECTED — signed by '${signer}', expected '${EXPECTED_SIGNER}'"
			rejected=$((rejected + 1))
			continue
		fi

		result="$(rpc verifyhash "[\"${signer}\",\"${sig}\",\"${hash}\"]" || echo error)"
		case "$result" in
		true)
			note "  ${arch}: VERIFIED — signed by ${signer}"
			printf '%s  %s\n' "$(sha256sum "${workdir}/${asset}" | cut -d' ' -f1)" "$asset"
			verified=$((verified + 1))
			;;
		false)
			note "  ${arch}: REJECTED — the chain says this signature is not valid"
			rejected=$((rejected + 1))
			;;
		*)
			note "  ${arch}: could not complete the check (node error)"
			unreachable=$((unreachable + 1))
			;;
		esac

		rm -f "${workdir}"/*.tar.gz "${workdir}"/*.signature.txt "${workdir}/${asset}"
	done

	note "verified ${verified}, rejected ${rejected}, unreachable ${unreachable}"

	((rejected == 0)) || return 1
	((unreachable == 0)) || return 2
	return 0
}

main "$@"
