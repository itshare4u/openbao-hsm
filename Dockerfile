# syntax=docker/dockerfile:1.6

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

# Build OpenBao external secrets engine plugins (aws/gcp/azure)
# Build on $BUILDPLATFORM and cross-compile for $TARGETPLATFORM (no QEMU needed).
FROM --platform=$BUILDPLATFORM golang:1.24 AS plugin-builder

ARG TARGETOS
ARG TARGETARCH

# Can be a tag, branch, commit SHA, or "latest".
ARG OPENBAO_PLUGINS_VERSION=latest

ENV CGO_ENABLED=0
ENV GOPROXY=https://proxy.golang.org,direct

RUN mkdir -p /out

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    set -eux; \
    GOBIN=/out GOOS=$TARGETOS GOARCH=$TARGETARCH \
      go install github.com/openbao/openbao-plugins/secrets/aws/cmd/openbao-plugin-secrets-aws@${OPENBAO_PLUGINS_VERSION}; \
    GOBIN=/out GOOS=$TARGETOS GOARCH=$TARGETARCH \
      go install github.com/openbao/openbao-plugins/secrets/gcp/cmd/openbao-plugin-secrets-gcp@${OPENBAO_PLUGINS_VERSION}; \
    GOBIN=/out GOOS=$TARGETOS GOARCH=$TARGETARCH \
      go install github.com/openbao/openbao-plugins/secrets/azure/cmd/openbao-plugin-secrets-azure@${OPENBAO_PLUGINS_VERSION}

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
COPY --from=plugin-builder /out/openbao-plugin-secrets-aws /usr/local/lib/openbao/plugins/
COPY --from=plugin-builder /out/openbao-plugin-secrets-gcp /usr/local/lib/openbao/plugins/
COPY --from=plugin-builder /out/openbao-plugin-secrets-azure /usr/local/lib/openbao/plugins/

# Add entrypoint wrapper for SoftHSM key bootstrap
COPY docker-entrypoint.sh /usr/local/bin/openbao-entrypoint.sh
RUN chmod +x /usr/local/bin/openbao-entrypoint.sh \
    && chown -R openbao:openbao /usr/local/lib/openbao/plugins

# Add metadata labels
LABEL org.opencontainers.image.title="OpenBao with SoftHSM2" \
      org.opencontainers.image.vendor="LicheeSight" \
      org.opencontainers.image.description="OpenBao HSM-enabled with SoftHSM2 for testing" \
      org.opencontainers.image.url="https://github.com/LicheeSight/openbao-hsm" \
      org.opencontainers.image.source="https://github.com/LicheeSight/openbao-hsm" \
      org.opencontainers.image.licenses="MPL-2.0"

# Switch back to openbao user
USER openbao

# Default entrypoint + command
ENTRYPOINT ["/usr/local/bin/openbao-entrypoint.sh"]
CMD ["server", "-dev", "-dev-no-store-token"]
