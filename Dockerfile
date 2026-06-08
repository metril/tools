# syntax=docker/dockerfile:1

# Base image is pinned by digest in versions.json; both are injected as build args
# by the release workflow (see .github/workflows/release.yml). Defaults here keep
# `docker build` working locally without --build-arg.
ARG BASE_IMAGE=alpine:3.21
ARG BASE_DIGEST=sha256:48b0309ca019d89d40f670aa1bc06e426dc0931948452e8491e3d65087abc07d

# ---------------------------------------------------------------------------
# Builder: download HashiCorp Vault and verify checksum + GPG signature before
# it ever lands in the published image.
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE}@${BASE_DIGEST} AS vault-builder

ARG VAULT_VERSION=2.0.2
# Provided automatically by buildx (linux, amd64|arm64). HashiCorp's archive
# naming matches these values directly.
ARG TARGETOS=linux
ARG TARGETARCH=amd64

RUN apk add --no-cache curl gnupg unzip

WORKDIR /tmp/vault
RUN set -eux; \
    base="https://releases.hashicorp.com/vault/${VAULT_VERSION}"; \
    zip="vault_${VAULT_VERSION}_${TARGETOS}_${TARGETARCH}.zip"; \
    curl -fsSLO "${base}/${zip}"; \
    curl -fsSLO "${base}/vault_${VAULT_VERSION}_SHA256SUMS"; \
    curl -fsSLO "${base}/vault_${VAULT_VERSION}_SHA256SUMS.sig"; \
    # Import HashiCorp's release-signing public key and verify the signature
    # over the checksum file, then verify the archive against the checksum.
    curl -fsSL "https://www.hashicorp.com/.well-known/pgp-key.txt" | gpg --import; \
    gpg --verify "vault_${VAULT_VERSION}_SHA256SUMS.sig" "vault_${VAULT_VERSION}_SHA256SUMS"; \
    grep " ${zip}\$" "vault_${VAULT_VERSION}_SHA256SUMS" | sha256sum -c -; \
    unzip "${zip}"; \
    mv vault /usr/local/bin/vault; \
    chmod +x /usr/local/bin/vault; \
    /usr/local/bin/vault version

# ---------------------------------------------------------------------------
# Final image: the tools needed in CI. jq/curl/wget come from the Alpine repos
# at build time (the distro vets them; periodic rebuilds refresh them).
# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE}@${BASE_DIGEST}

RUN apk add --no-cache \
        bash \
        ca-certificates \
        curl \
        jq \
        wget

COPY --from=vault-builder /usr/local/bin/vault /usr/local/bin/vault

# OCI image metadata. VERSION/REVISION/CREATED are injected at build time.
ARG VERSION=dev
ARG REVISION=unknown
ARG CREATED=unknown
LABEL org.opencontainers.image.title="tools" \
      org.opencontainers.image.description="CI/CD toolbox: HashiCorp Vault, jq, curl, wget" \
      org.opencontainers.image.source="https://github.com/metril/tools" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}"

# Sanity-check the toolchain is present and runnable at build time.
RUN set -eux; \
    vault version; \
    jq --version; \
    curl --version; \
    wget --version 2>&1 | head -n1

CMD ["/bin/bash"]
