#!/usr/bin/env bash
# Bootstrap (chain snapshot) download.
#
# We deliberately do NOT use verusd's own -bootstrap / -bootstrapinstall flags:
#
#   * -bootstrap is unconditional and destructive on EVERY start. It deletes
#     blocks/, chainstate/, notarisations/, peers.dat and komodostate, and
#     forces -zappwallettxes=2, which discards wallet transaction metadata.
#   * The daemon's downloader never verifies the archive. It fetches the
#     .verusid signature sidecar and then never reads it, performs no hashing,
#     and sets CURLOPT_SSL_VERIFYPEER=0 / CURLOPT_SSL_VERIFYHOST=0.
#
# This implementation is idempotent, verifies the published SHA-256 before
# extracting, and aborts loudly on any mismatch.

readonly BOOTSTRAP_SENTINEL=".bootstrap-complete"
readonly BOOTSTRAP_PARTIAL=".bootstrap-in-progress"

# Fetch the sidecar checksum for a bootstrap archive.
# Echoes the hex digest on stdout.
_fetch_bootstrap_checksum() {
	local url="$1" tmp curl_status=0 digest
	local -a insecure=()

	is_true "${BOOTSTRAP_INSECURE_TLS:-false}" && insecure=(--insecure)

	tmp="$(mktemp)"
	http_get_to_stdout "${url}.sha256sum" "${insecure[@]}" >"$tmp" 2>/dev/null || curl_status=$?

	if ((curl_status != 0)); then
		rm -f -- "$tmp"
		if ((curl_status == 60)); then
			log_error "TLS certificate verification failed for ${url}"
			log_error ""
			log_error "Known issue: the third-party PBaaS bootstrap host bootstrap.dexstats.info"
			log_error "serves an expired certificate issued for a different hostname."
			log_error ""
			log_error "You can proceed with BOOTSTRAP_INSECURE_TLS=true. The archive's SHA-256"
			log_error "is still verified in that case, so a corrupted or truncated download is"
			log_error "still caught — but the identity of the server is not authenticated."
			log_error "Only do this if you also trust the checksum's origin."
		else
			log_error "could not fetch ${url}.sha256sum (curl exit ${curl_status})"
		fi
		return 1
	fi

	if ! digest="$(extract_sha256_from_sidecar "$tmp")"; then
		rm -f -- "$tmp"
		return 1
	fi

	rm -f -- "$tmp"
	printf '%s\n' "$digest"
}

# Download with periodic progress output. Bootstraps are 6-22 GiB; a silent
# container for two hours looks identical to a hung one.
_download_with_progress() {
	local url="$1" dest="$2"
	local part="${dest}.part"
	local total=0 pid rc=0 elapsed=0 size pct
	local -a insecure=()

	is_true "${BOOTSTRAP_INSECURE_TLS:-false}" && insecure=(--insecure)

	# Ask for the size with a HEAD request so we can report a percentage. Take
	# the LAST Content-Length header, because redirects emit one per hop.
	total="$(curl --fail --silent --location --head \
		--user-agent "$VERUS_HTTP_UA" --connect-timeout 30 \
		"${insecure[@]}" "$url" 2>/dev/null |
		tr -d '\r' |
		awk 'tolower($1) == "content-length:" {v = $2} END {print v}' || true)"
	[[ "$total" =~ ^[0-9]+$ ]] || total=0

	if ((total > 0)); then
		log_info "archive size: $(human_bytes "$total")"
	fi

	rm -f -- "$part"
	curl --fail --silent --show-error --location \
		--user-agent "$VERUS_HTTP_UA" \
		--retry 3 --retry-delay 10 --retry-connrefused \
		--connect-timeout 30 \
		"${insecure[@]}" \
		--output "$part" "$url" &
	pid=$!

	while kill -0 "$pid" 2>/dev/null; do
		sleep 30
		elapsed=$((elapsed + 30))
		size="$(stat -c %s "$part" 2>/dev/null || echo 0)"
		if ((total > 0)); then
			pct=$((size * 100 / total))
			log_info "  downloading... $(human_bytes "$size") / $(human_bytes "$total") (${pct}%, ${elapsed}s elapsed)"
		else
			log_info "  downloading... $(human_bytes "$size") (${elapsed}s elapsed)"
		fi
	done

	wait "$pid" || rc=$?
	if ((rc != 0)); then
		rm -f -- "$part"
		log_error "bootstrap download failed (curl exit ${rc})"
		return 1
	fi

	mv -f -- "$part" "$dest"
}

# maybe_bootstrap <datadir>
# Returns 0 in every non-fatal case: a missing bootstrap is a slow sync, not an
# error. Only an integrity failure is fatal.
maybe_bootstrap() {
	local datadir="$1"
	local url checksum archive

	is_true "${USE_BOOTSTRAP:-false}" || return 0

	if [[ "$CHAIN_KIND" == "pbaas" ]]; then
		log_banner_warning \
			"USE_BOOTSTRAP=true is not supported for PBaaS chains." \
			"A PBaaS data directory is named after a hash the daemon derives" \
			"at runtime, so there is nothing to extract into before it starts." \
			"Additionally the community bootstrap host for PBaaS chains" \
			"currently serves an expired TLS certificate." \
			"Continuing with a normal sync from the network."
		return 0
	fi

	if dir_has_chain_data "$datadir"; then
		if [[ -f "${datadir}/${BOOTSTRAP_SENTINEL}" ]] || [[ ! -f "${datadir}/${BOOTSTRAP_PARTIAL}" ]]; then
			log_info "chain data already present in ${datadir} — skipping bootstrap"
			return 0
		fi
		log_warn "a previous bootstrap did not finish extracting; redoing it"
		log_warn "  (partial chain data would otherwise be mistaken for a good sync)"
		rm -rf -- "${datadir}/blocks" "${datadir}/chainstate" "${datadir}/notarisations"
		rm -f -- "${datadir}/${BOOTSTRAP_PARTIAL}"
	fi

	url="${BOOTSTRAP_URL:-$(chain_meta '.bootstrap.url')}"
	if [[ -z "$url" ]]; then
		log_warn "USE_BOOTSTRAP=true but no bootstrap URL is known for chain '${CHAIN_NAME}'."
		log_warn "Set BOOTSTRAP_URL=<url> to use one, or leave it unset to sync from the network."
		return 0
	fi

	log_info "Bootstrapping ${CHAIN_NAME} from ${url}"
	if [[ -n "$(chain_meta '.bootstrap.signer')" && -z "${BOOTSTRAP_URL:-}" ]]; then
		log_info "  published by: $(chain_meta '.bootstrap.signer')"
	fi

	checksum="$(_fetch_bootstrap_checksum "$url")" ||
		die "cannot verify the bootstrap for ${CHAIN_NAME}; refusing to download it unverified"

	log_info "  expected SHA-256: ${checksum}"

	mkdir -p -- "$datadir"
	archive="${datadir}/.bootstrap-download.tar.gz"

	_download_with_progress "$url" "$archive" ||
		die "bootstrap download failed"

	log_info "verifying archive (hashing several GB, please wait)..."
	verify_sha256 "$archive" "$checksum" "bootstrap archive"

	log_info "extracting into ${datadir} ..."
	# Mark the directory as mid-extract so an interrupted tar cannot be mistaken
	# for a completed bootstrap on the next start.
	: >"${datadir}/${BOOTSTRAP_PARTIAL}"
	if ! tar -xzf "$archive" -C "$datadir"; then
		rm -f -- "$archive"
		die "bootstrap extraction failed; it will be redone automatically on the next start"
	fi
	rm -f -- "${datadir}/${BOOTSTRAP_PARTIAL}"
	: >"${datadir}/${BOOTSTRAP_SENTINEL}"

	rm -f -- "$archive"
	log_info "bootstrap complete; the daemon will sync the remaining blocks from the network"
}
