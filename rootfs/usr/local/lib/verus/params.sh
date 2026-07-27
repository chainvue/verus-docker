#!/usr/bin/env bash
# Zcash proving/verifying parameters.
#
# verusd refuses to start without these (checkParams() during init). They live
# outside the chain data directory, in ~/.zcash-params, and are identical for
# every chain — so they belong on their own shared volume and are deliberately
# NOT baked into the image.
#
# The expected hashes are the ones pinned in VerusCoin's src/params.h.

readonly PARAMS_DEFAULT_SOURCE="https://verus.io/zcparams"

# name:sha256 — only the Sapling parameters and the Groth16 Sprout parameters
# are required. The legacy sprout-proving.key/sprout-verifying.key (~900 MB)
# are not fetched; upstream stopped requiring them.
readonly -a ZCASH_PARAMS=(
	"sapling-spend.params:8e48ffd23abb3a5fd9c5589204f32d9c31285a04b78096ba40a79b75677efc13"
	"sapling-output.params:2f0ebbcbb9bb0bcffe95a397e7eba89c29eb4dde6191c339db88570e3f3fb0e4"
	"sprout-groth16.params:b685d700c60328498fbde589c8c7c484c722b788b265b72af448a5bf0ee55b50"
)

params_dir() {
	printf '%s\n' "${VERUS_HOME}/.zcash-params"
}

ensure_params() {
	local dir source entry name expected path missing=0

	dir="$(params_dir)"
	source="${PARAMS_SOURCE:-$PARAMS_DEFAULT_SOURCE}"
	source="${source%/}"

	mkdir -p -- "$dir"

	for entry in "${ZCASH_PARAMS[@]}"; do
		name="${entry%%:*}"
		[[ -s "${dir}/${name}" ]] || missing=1
	done

	if ((missing == 0)); then
		log_info "Zcash parameters present in ${dir}"
		if is_true "${PARAMS_VERIFY_EXISTING:-false}"; then
			verify_existing_params "$dir"
		fi
		return 0
	fi

	log_info "Fetching Zcash parameters (about 740 MB, one time, shared by every chain)."
	log_info "  source:      ${source}"
	log_info "  destination: ${dir}"
	if [[ "$source" != "$PARAMS_DEFAULT_SOURCE" ]]; then
		log_info "  (using PARAMS_SOURCE override)"
	fi

	for entry in "${ZCASH_PARAMS[@]}"; do
		name="${entry%%:*}"
		expected="${entry##*:}"
		path="${dir}/${name}"

		if [[ -s "$path" ]]; then
			log_info "  ${name}: already present, skipping"
			continue
		fi

		log_info "  ${name}: downloading..."
		http_download "${source}/${name}" "$path" ||
			die "failed to download ${name} from ${source}"

		# Another container sharing this volume may have finished the same file
		# while we were fetching it. Either copy is valid once verified.
		verify_sha256 "$path" "$expected" "$name"
		log_info "  ${name}: $(human_bytes "$(stat -c %s "$path")")"
	done

	log_info "Zcash parameters ready."
}

verify_existing_params() {
	local dir="$1" entry name expected

	log_info "PARAMS_VERIFY_EXISTING=true — re-hashing parameters (this takes a while)"
	for entry in "${ZCASH_PARAMS[@]}"; do
		name="${entry%%:*}"
		expected="${entry##*:}"
		[[ -s "${dir}/${name}" ]] || continue
		verify_sha256 "${dir}/${name}" "$expected" "$name"
	done
}
