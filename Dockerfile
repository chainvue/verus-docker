# syntax=docker/dockerfile:1.7

# =============================================================================
# verus-docker — production Verus (VRSC) full nodes
#
# Upstream ships prebuilt Linux binaries for both x86_64 and arm64, so this
# image downloads and verifies them rather than compiling anything.
#
# A note on verification: VerusCoin publishes no SHA256SUMS, .asc or .sig
# release asset. Each release tarball embeds a VerusID signature file, but
# checking that signature requires a synced VRSC node, which is impossible
# during a container build. The SHA-256 values in the release notes reference
# nothing that ships in the release and must not be used.
#
# The root of trust is therefore the checksum pinned below, reviewed by a human
# when the version is bumped. The embedded signature file is cross-checked as
# defence in depth. Both must pass or the build fails.
# =============================================================================

ARG VERUS_VERSION=v1.2.17-2
ARG DEBIAN_TAG=bookworm-slim

# -----------------------------------------------------------------------------
# Stage 1: fetch and verify the upstream binaries.
#
# Pinned to BUILDPLATFORM: this stage only downloads and unpacks, so there is no
# reason to run it under emulation when cross-building.
# -----------------------------------------------------------------------------
FROM --platform=${BUILDPLATFORM} debian:${DEBIAN_TAG} AS fetch

ARG VERUS_VERSION
ARG TARGETARCH

# SHA-256 of the outer .tgz release asset, per architecture.
# Update both together; scripts/bump-upstream.sh recomputes them.
ARG VERUS_SHA256_AMD64=4ff43ee52599bff9bf19eed99daa80c5a4b609e13df7cad1796a81393e7dee42
ARG VERUS_SHA256_ARM64=749f4c9c8bb57fc3eef116ff876a890cd4fc2cdb8fd8f549df4ffcc646ab2a90

ARG VERUS_SIGNER="Verus Coin Foundation Releases@"

# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        jq \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# The verification step pipes into sha256sum; without pipefail a failure in the
# left-hand side of that pipe would be silently ignored.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) upstream_arch="x86_64"; expected_sha="${VERUS_SHA256_AMD64}" ;; \
        arm64) upstream_arch="arm64";  expected_sha="${VERUS_SHA256_ARM64}" ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    asset="Verus-CLI-Linux-${VERUS_VERSION}-${upstream_arch}.tgz"; \
    url="https://github.com/VerusCoin/VerusCoin/releases/download/${VERUS_VERSION}/${asset}"; \
    echo ">> downloading ${url}"; \
    curl --fail --silent --show-error --location --retry 3 --retry-delay 5 \
         --output "${asset}" "${url}"; \
    echo ">> verifying against the pinned checksum (root of trust)"; \
    echo "${expected_sha}  ${asset}" | sha256sum --check --strict -; \
    echo ">> unpacking (the release is a tarball inside a tarball)"; \
    tar -xzf "${asset}"; \
    inner="Verus-CLI-Linux-${VERUS_VERSION}-${upstream_arch}.tar.gz"; \
    test -f "${inner}"; \
    test -f "${inner}.signature.txt"; \
    echo ">> cross-checking the embedded VerusID signature file"; \
    embedded_hash="$(jq -r '.hash' "${inner}.signature.txt")"; \
    embedded_signer="$(jq -r '.signer' "${inner}.signature.txt")"; \
    actual_hash="$(sha256sum "${inner}" | cut -d' ' -f1)"; \
    if [ "${embedded_hash}" != "${actual_hash}" ]; then \
        echo "FATAL: embedded hash ${embedded_hash} != actual ${actual_hash}" >&2; \
        exit 1; \
    fi; \
    if [ "${embedded_signer}" != "${VERUS_SIGNER}" ]; then \
        echo "FATAL: unexpected signer '${embedded_signer}'" >&2; \
        exit 1; \
    fi; \
    echo ">> verified ${inner} (signed by ${embedded_signer})"; \
    tar -xzf "${inner}" -C /opt; \
    test -x /opt/verus-cli/verusd; \
    test -x /opt/verus-cli/verus; \
    rm -f /opt/verus-cli/fetch-params /opt/verus-cli/fetch-bootstrap; \
    rm -f /build/*

# -----------------------------------------------------------------------------
# Stage 2: runtime.
#
# Debian is required: the upstream binaries need GLIBC_2.28 / GLIBCXX_3.4.22,
# so musl-based images such as Alpine cannot run them.
# -----------------------------------------------------------------------------
FROM debian:${DEBIAN_TAG}

ARG VERUS_VERSION
ARG IMAGE_REVISION=dev
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown

# The licenses label is a compound SPDX expression on purpose: this project is
# Apache-2.0, the bundled verusd is MIT, and verusd links AGPL Berkeley DB.
# See LICENSING.md for what that means for a redistributor.
LABEL org.opencontainers.image.title="verus-docker" \
      org.opencontainers.image.description="Production-ready Verus (VRSC) full node — mainnet, testnet and any PBaaS chain" \
      org.opencontainers.image.source="https://github.com/chainvue/verus-docker" \
      org.opencontainers.image.documentation="https://github.com/chainvue/verus-docker#readme" \
      org.opencontainers.image.licenses="Apache-2.0 AND MIT AND AGPL-3.0" \
      org.opencontainers.image.vendor="Robert Lech and the verus-docker contributors" \
      org.opencontainers.image.version="${VERUS_VERSION}-${IMAGE_REVISION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      io.verusdocker.upstream.version="${VERUS_VERSION}"

# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gosu \
        iproute2 \
        jq \
        libexpat1 \
        libgomp1 \
        tini \
    && rm -rf /var/lib/apt/lists/*

# Fixed UID/GID so host bind mounts behave predictably. PUID/PGID can remap
# them at runtime; see the entrypoint.
RUN groupadd --gid 1000 verus \
    && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash verus

COPY --from=fetch /opt/verus-cli /opt/verus-cli
COPY rootfs/ /
COPY chains/ /usr/local/share/verus-docker/chains/

RUN chmod 0755 \
        /usr/local/bin/entrypoint.sh \
        /usr/local/bin/healthcheck.sh \
        /usr/local/bin/verus \
    && ln -sf /opt/verus-cli/verusd /usr/local/bin/verusd \
    # Pre-create the mount points. Docker seeds a new named volume with the
    # ownership of the directory it shadows; if that directory does not exist it
    # creates it as root and the unprivileged daemon cannot write to it.
    && mkdir -p \
        /home/verus/.komodo \
        /home/verus/.verus \
        /home/verus/.verustest \
        /home/verus/.zcash-params \
    && chown -R verus:verus /home/verus

ENV VERUS_HOME=/home/verus \
    HOME=/home/verus \
    CHAIN=VRSC \
    TXINDEX=1 \
    USE_BOOTSTRAP=false \
    DISABLE_WALLET=false \
    ENABLE_STAKING=false \
    VERUS_VERSION=${VERUS_VERSION} \
    IMAGE_REVISION=${IMAGE_REVISION}

WORKDIR /home/verus
USER verus

# Documentation only; the effective ports come from CHAIN / RPC_PORT / P2P_PORT.
#   27485/27486 VRSC p2p/rpc      18842/18843 VRSCTEST p2p/rpc
EXPOSE 27485 27486 18842 18843

# Liveness only: a node doing its initial sync is healthy. Readiness ("has it
# caught up?") is a separate question — see healthcheck.sh --require-synced.
HEALTHCHECK --interval=30s --timeout=15s --start-period=180s --retries=5 \
    CMD /usr/local/bin/healthcheck.sh --quiet || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
