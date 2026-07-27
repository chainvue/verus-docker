#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
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

# Emits the curl option, nothing else. Callers read this through a command
# substitution, so it must not try to keep state — see warn_insecure_tls.
_insecure_tls_opts() {
	is_true "${BOOTSTRAP_INSECURE_TLS:-false}" || return 0
	printf '%s\n' "--insecure"
}

# Called once from maybe_bootstrap, in the main shell. The policy in
# SECURITY.md describes this flag as warning loudly; for several releases it
# did not warn at all.
warn_insecure_tls() {
	is_true "${BOOTSTRAP_INSECURE_TLS:-false}" || return 0

	log_banner_warning \
		"BOOTSTRAP_INSECURE_TLS=true — certificate verification is OFF." \
		"" \
		"Both the archive AND its checksum are fetched over an unauthenticated" \
		"connection. Anyone able to intercept that traffic can serve you a" \
		"different archive together with a matching checksum, and the integrity" \
		"check will pass." \
		"" \
		"The SHA-256 check still catches corruption and truncation. It does NOT" \
		"establish who you are talking to." \
		"" \
		"This is only a reasonable trade for a host you already trust whose" \
		"certificate has merely expired."
}

# Fetch the sidecar checksum for a bootstrap archive.
# Echoes the hex digest on stdout.
_fetch_bootstrap_checksum() {
	local url="$1" tmp curl_status=0 digest
	local -a insecure=()

	mapfile -t insecure < <(_insecure_tls_opts)

	tmp="$(mktemp)"
	http_get_to_stdout "${url}.sha256sum" "${insecure[@]}" >"$tmp" 2>/dev/null || curl_status=$?

	# Not every host publishes a .sha256sum. The Verus bootstrap hosts also
	# publish a .verusid JSON sidecar carrying the same digest — verified
	# byte-identical on VRSC, where both exist — and for the third-party PBaaS
	# host it is the only checksum on offer. Fall back to it.
	if ((curl_status != 0)); then
		local vtmp vhash
		vtmp="$(mktemp)"
		if http_get_to_stdout "${url}.verusid" "${insecure[@]}" >"$vtmp" 2>/dev/null &&
			vhash="$(jq -r '.hash // empty' "$vtmp" 2>/dev/null)" &&
			[[ "$vhash" =~ ^[0-9a-f]{64}$ ]]; then
			log_info "  no .sha256sum published; using the .verusid sidecar"
			log_info "  signed by: $(jq -r '.signee // "unknown"' "$vtmp" 2>/dev/null)"
			rm -f -- "$tmp" "$vtmp"
			printf '%s\n' "$vhash"
			return 0
		fi
		rm -f -- "$vtmp"
	fi

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
#
# This one drives its own progress loop rather than using run_interruptible, so
# it publishes the child PID itself for the entrypoint's signal handler. The
# short sleep is what makes a stop responsive: the handler cannot run while a
# foreground command is in progress, so the loop must return to the shell often.
# shellcheck disable=SC2034  # VERUS_CHILD_PID is read by forward_signal
_download_with_progress() {
	local url="$1" dest="$2"
	local part="${dest}.part"
	local total=0 pid rc=0 elapsed=0 size pct
	local -a insecure=()

	mapfile -t insecure < <(_insecure_tls_opts)

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

	# Resumes a partial file from an earlier, interrupted start rather than
	# discarding 22 GiB of completed transfer.
	if [[ -s "$part" ]]; then
		log_info "resuming a partial download ($(human_bytes "$(stat -c %s "$part")") already fetched)"
	fi

	curl --fail --silent --show-error --location \
		--user-agent "$VERUS_HTTP_UA" \
		--retry 3 --retry-delay 10 --retry-connrefused \
		--connect-timeout 30 \
		--continue-at - \
		"${insecure[@]}" \
		--output "$part" "$url" &
	pid=$!
	VERUS_CHILD_PID="$pid"

	# Poll often so a stop is noticed promptly, but only log every 30s.
	local ticks=0
	while kill -0 "$pid" 2>/dev/null; do
		sleep 5
		elapsed=$((elapsed + 5))
		ticks=$((ticks + 1))
		((ticks % 6 == 0)) || continue
		size="$(stat -c %s "$part" 2>/dev/null || echo 0)"
		if ((total > 0)); then
			pct=$((size * 100 / total))
			log_info "  downloading... $(human_bytes "$size") / $(human_bytes "$total") (${pct}%, ${elapsed}s elapsed)"
		else
			log_info "  downloading... $(human_bytes "$size") (${elapsed}s elapsed)"
		fi
	done

	wait "$pid" || rc=$?
	VERUS_CHILD_PID=""
	if ((rc != 0)); then
		# Keep the partial file so the next start resumes instead of restarting.
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

	warn_insecure_tls

	# A PBaaS chain's data directory is named after a hash. We can only seed it
	# ahead of the daemon when we already know that hash, which is exactly the
	# chains/ metadata case.
	if [[ "$CHAIN_KIND" == "pbaas" ]]; then
		local hash
		hash="$(chain_meta '.datadir_hash')"
		if [[ ! "$hash" =~ ^[0-9a-f]{40}$ ]]; then
			log_warn "USE_BOOTSTRAP=true, but the data directory name for '${CHAIN_NAME}' is not known."
			log_warn "  A PBaaS directory is named after a hash the daemon derives from the chain"
			log_warn "  definition. Add datadir_hash to chains/${CHAIN_SLUG}.json to enable this,"
			log_warn "  or let the chain sync from the network (usually fine — PBaaS chains are small)."
			return 0
		fi
		datadir="${CHAIN_HOME}/pbaas/${hash}"
		log_info "PBaaS bootstrap target: ${datadir}"
	fi

	# Everything below deletes directories underneath $datadir. CHAIN_DATADIR is
	# deliberately empty for PBaaS chains (the daemon names that directory), so
	# an unset or root value here would mean `rm -rf /blocks`. The PBaaS branch
	# above sets it, but this must not be one refactor away from disaster.
	[[ -n "$datadir" && "$datadir" != "/" ]] ||
		die "internal error: bootstrap called with an unsafe data directory ('${datadir}')"

	# Check the in-progress marker on its own rather than only when the
	# directory already looks like a chain: a tar killed before it created
	# chainstate/ leaves debris that dir_has_chain_data does not recognise.
	if [[ -f "${datadir}/${BOOTSTRAP_PARTIAL}" ]]; then
		log_warn "a previous bootstrap did not finish extracting; redoing it"
		log_warn "  (partial chain data would otherwise be mistaken for a good sync)"
		rm -rf -- "${datadir}/blocks" "${datadir}/chainstate" "${datadir}/notarisations"
		rm -f -- "${datadir}/${BOOTSTRAP_PARTIAL}"
	elif dir_has_chain_data "$datadir"; then
		log_info "chain data already present in ${datadir} — skipping bootstrap"
		return 0
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

	# An archive left by an interrupted start is worth re-checking before
	# spending hours downloading it again: if it still hashes correctly we can
	# go straight to extraction.
	if [[ -s "$archive" ]] && log_info "re-checking the archive left by a previous start..." &&
		sha256_matches_interruptible "$archive" "$checksum"; then
		log_info "it still verifies — skipping the download and going straight to extraction"
	else
		_check_bootstrap_space "$datadir" "$url"
		_download_with_progress "$url" "$archive" ||
			die "bootstrap download failed"

		log_info "verifying archive (hashing several GB, please wait)..."
		verify_sha256_interruptible "$archive" "$checksum" "bootstrap archive"
	fi

	log_info "extracting into ${datadir} ..."
	# Mark the directory as mid-extract so an interrupted tar cannot be mistaken
	# for a completed bootstrap on the next start.
	: >"${datadir}/${BOOTSTRAP_PARTIAL}"
	# A bootstrap archive is chain data. It has no business carrying a wallet, a
	# config or a credentials file, and on the one occasion it did we would
	# overwrite the operator's. The checksum comes from the same host as the
	# archive, so it proves the download was not corrupted in transit — not that
	# the contents are benign.
	if ! run_interruptible tar -xzf "$archive" -C "$datadir" \
		--no-same-owner --no-same-permissions \
		--exclude='wallet.dat' --exclude='*/wallet.dat' \
		--exclude='wallet.dat.*' --exclude='*/wallet.dat.*' \
		--exclude='*.conf' --exclude='rpc-credentials'; then
		# The archive stays: it is already verified, so a retry only re-extracts.
		# Deleting it here is how a disk-full failure turned into a loop that
		# re-downloaded 22 GiB on every restart.
		die "bootstrap extraction failed; the verified archive was kept, so the next start resumes at extraction"
	fi
	rm -f -- "${datadir}/${BOOTSTRAP_PARTIAL}"
	: >"${datadir}/${BOOTSTRAP_SENTINEL}"

	rm -f -- "$archive"
	log_info "bootstrap complete; the daemon will sync the remaining blocks from the network"
}

# Bootstraps need room for the archive AND its expanded contents at the same
# time. Running out mid-extraction is recoverable but slow, and the error the
# operator sees otherwise is a bare tar failure.
_check_bootstrap_space() {
	local datadir="$1" url="$2" total avail needed
	local -a insecure=()

	mapfile -t insecure < <(_insecure_tls_opts)

	total="$(curl --fail --silent --location --head \
		--user-agent "$VERUS_HTTP_UA" --connect-timeout 30 \
		"${insecure[@]}" "$url" 2>/dev/null |
		tr -d '\r' |
		awk 'tolower($1) == "content-length:" {v = $2} END {print v}' || true)"
	[[ "$total" =~ ^[0-9]+$ ]] && ((total > 0)) || return 0

	avail="$(free_bytes "$datadir")" || return 0

	# Compressed chain data expands to roughly its own size again, and the
	# archive is only deleted after extraction succeeds.
	needed=$((total * 5 / 2))
	if ((avail < needed)); then
		log_banner_warning \
			"Not enough free space for this bootstrap." \
			"" \
			"archive:    $(human_bytes "$total")" \
			"free space: $(human_bytes "$avail")" \
			"needed:     $(human_bytes "$needed") (archive + extracted copy)" \
			"" \
			"The archive is only removed once extraction succeeds, so both exist" \
			"at the same time. Grow the volume, or leave USE_BOOTSTRAP unset and" \
			"sync from the network instead."
		die "insufficient disk space for the bootstrap"
	fi
	log_info "  disk check: $(human_bytes "$avail") free, $(human_bytes "$needed") needed"
}
