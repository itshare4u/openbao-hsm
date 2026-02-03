# OpenBao with SoftHSM2 Support
# Based on openbao-hsm-ubi with added SoftHSM2 for testing

FROM ghcr.io/openbao/openbao-hsm-ubi:latest AS builder

USER root

# Install build dependencies for SoftHSM2
RUN microdnf install -y \
    gcc \
    gcc-c++ \
    make \
    cmake \
    openssl-devel \
    autoconf \
    automake \
    libtool \
    git \
    sqlite \
    sqlite-devel

# Build SoftHSM2 from source
WORKDIR /tmp
RUN git clone --depth 1 --branch 2.6.1 https://github.com/opendnssec/SoftHSMv2.git
WORKDIR /tmp/SoftHSMv2
RUN autoreconf -fi && \
    ./configure \
        --prefix=/usr/local \
        --with-openssl=/usr \
        --with-objectstore-backend-db \
        --disable-gost && \
    make -j$(nproc) && \
    make install

# Build external secrets engine plugins (aws/gcp/azure)
FROM golang:1.22 AS plugin-builder

ARG VAULT_PLUGIN_AWS_REF=main
ARG VAULT_PLUGIN_GCP_REF=main
ARG VAULT_PLUGIN_AZURE_REF=main

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN set -eu; \
    rm -rf aws; \
    if git clone --depth 1 --branch "${VAULT_PLUGIN_AWS_REF}" https://github.com/hashicorp/vault-plugin-secrets-aws.git aws; then :; \
    else \
        echo "WARN: ref ${VAULT_PLUGIN_AWS_REF} not found, cloning default branch"; \
        rm -rf aws; \
        git clone --depth 1 https://github.com/hashicorp/vault-plugin-secrets-aws.git aws; \
    fi; \
    cd aws; \
    (go build -o /out/vault-plugin-secrets-aws ./cmd/vault-plugin-secrets-aws || go build -o /out/vault-plugin-secrets-aws ./)

RUN set -eu; \
    rm -rf gcp; \
    if git clone --depth 1 --branch "${VAULT_PLUGIN_GCP_REF}" https://github.com/hashicorp/vault-plugin-secrets-gcp.git gcp; then :; \
    else \
        echo "WARN: ref ${VAULT_PLUGIN_GCP_REF} not found, cloning default branch"; \
        rm -rf gcp; \
        git clone --depth 1 https://github.com/hashicorp/vault-plugin-secrets-gcp.git gcp; \
    fi; \
    cd gcp; \
    (go build -o /out/vault-plugin-secrets-gcp ./cmd/vault-plugin-secrets-gcp || go build -o /out/vault-plugin-secrets-gcp ./)

RUN set -eu; \
    rm -rf azure; \
    if git clone --depth 1 --branch "${VAULT_PLUGIN_AZURE_REF}" https://github.com/hashicorp/vault-plugin-secrets-azure.git azure; then :; \
    else \
        echo "WARN: ref ${VAULT_PLUGIN_AZURE_REF} not found, cloning default branch"; \
        rm -rf azure; \
        git clone --depth 1 https://github.com/hashicorp/vault-plugin-secrets-azure.git azure; \
    fi; \
    cd azure; \
    (go build -o /out/vault-plugin-secrets-azure ./cmd/vault-plugin-secrets-azure || go build -o /out/vault-plugin-secrets-azure ./)

# Create production image
FROM ghcr.io/openbao/openbao-hsm-ubi:latest

USER root

# Install runtime dependencies
RUN microdnf install -y \
    openssl \
    gnutls-utils \
    libstdc++ \
    && microdnf clean all \
    && rm -rf /var/cache/yum

# Copy SoftHSM2 from builder
COPY --from=builder /usr/local/bin/softhsm2-* /usr/local/bin/
COPY --from=builder /usr/local/lib/softhsm/ /usr/local/lib/softhsm/
COPY --from=builder /usr/local/share/man/man1/ /usr/local/share/man/man1/
COPY --from=builder /usr/local/etc/softhsm2.conf /usr/local/etc/softhsm2.conf
COPY --from=builder /usr/local/var/lib/softhsm/ /usr/local/var/lib/softhsm/

# Create necessary directories
RUN mkdir -p /var/lib/softhsm/tokens \
    /etc/softhsm \
    /usr/local/var/lib/softhsm/tokens \
    /usr/local/lib/openbao/plugins

# Set up SoftHSM2 configuration
RUN echo "directories.tokendir = /var/lib/softhsm/tokens" > /etc/softhsm/softhsm2.conf \
    && echo "objectstore.backend = file" >> /etc/softhsm/softhsm2.conf \
    && echo "log.level = INFO" >> /etc/softhsm/softhsm2.conf \
    && echo "slots.removable = false" >> /etc/softhsm/softhsm2.conf \
    && echo "slots.mechanisms = ALL" >> /etc/softhsm/softhsm2.conf \
    && ln -sf /etc/softhsm/softhsm2.conf /etc/softhsm2.conf \
    && ln -sf /etc/softhsm/softhsm2.conf /usr/local/etc/softhsm2.conf

# Set environment variables for SoftHSM2
ENV SOFTHSM2_CONF=/etc/softhsm/softhsm2.conf
ENV PKCS11_LIB=/usr/local/lib/softhsm/libsofthsm2.so
ENV OPENBAO_PLUGIN_DIR=/usr/local/lib/openbao/plugins

# Update library path
RUN echo "/usr/local/lib/softhsm" > /etc/ld.so.conf.d/softhsm.conf && ldconfig

# Fix permissions
RUN chown -R openbao:openbao /var/lib/softhsm \
    && chmod 755 /var/lib/softhsm \
    && chmod 755 /usr/local/lib/softhsm/libsofthsm2.so

# Copy external plugins
COPY --from=plugin-builder /out/vault-plugin-secrets-aws /usr/local/lib/openbao/plugins/
COPY --from=plugin-builder /out/vault-plugin-secrets-gcp /usr/local/lib/openbao/plugins/
COPY --from=plugin-builder /out/vault-plugin-secrets-azure /usr/local/lib/openbao/plugins/

# Add entrypoint wrapper for SoftHSM key bootstrap
COPY docker-entrypoint.sh /usr/local/bin/openbao-entrypoint.sh
RUN chmod +x /usr/local/bin/openbao-entrypoint.sh \
    && chown -R openbao:openbao /usr/local/lib/openbao/plugins

# Add metadata labels
LABEL org.opencontainers.image.title="OpenBao with SoftHSM2" \
      org.opencontainers.image.vendor="itshare4u" \
      org.opencontainers.image.description="OpenBao HSM-enabled with SoftHSM2 for testing" \
      org.opencontainers.image.url="https://github.com/itshare4u/openbao-hsm" \
      org.opencontainers.image.source="https://github.com/itshare4u/openbao-hsm" \
      org.opencontainers.image.licenses="MPL-2.0"

# Switch back to openbao user
USER openbao

# Default entrypoint + command
ENTRYPOINT ["/usr/local/bin/openbao-entrypoint.sh"]
CMD ["server", "-dev", "-dev-no-store-token"]
