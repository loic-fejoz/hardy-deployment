# ==============================================================================
# Multi-stage Dockerfile for CorteXlab Hardy Node with LTP CLA and GNU Radio
# ==============================================================================

# ------------------------------------------------------------------------------
# Stage 1: Rust Builder (compile hardy-bpa-server & dtn-hdy-utils)
# ------------------------------------------------------------------------------
FROM rust:bookworm AS builder

# Install build essentials and protobuf compiler required by hardy gRPC
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    pkg-config \
    libssl-dev \
    protobuf-compiler \
    libprotobuf-dev \
    cmake \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Build Hardy BPA Server with LTP CLA and DTN Hardy utilities
# Note: dtn-hdy-utils depends on ../hardy pinned at ref e7694992
RUN git clone https://github.com/loic-fejoz/hardy.git /build/hardy \
    && cd /build/hardy \
    && git checkout feat/ltp-cla \
    && cargo build --release --bin hardy-bpa-server \
    && cp target/release/hardy-bpa-server /build/hardy-bpa-server \
    && git checkout e7694992598f725ecfa3919a5de8105cd48956fe \
    && git clone --depth 1 https://github.com/loic-fejoz/dtn-hdy-utils.git /build/dtn-hdy-utils \
    && cd /build/dtn-hdy-utils \
    && cargo build --release

# ------------------------------------------------------------------------------
# Stage 2: Runtime Image (CorteXlab GNU Radio 3.10 environment)
# ------------------------------------------------------------------------------
FROM cxlb-docker-gnuradio-3.10:latest

LABEL maintainer="Loïc Féjoz"
LABEL description="CorteXlab experiment node with GNU Radio 3.10, Hardy BPA (LTP CLA), and DTN utilities"

# Configure environment for CorteXlab GNU Radio toolchain
ENV PATH="/cortexlab/toolchains/current/bin:${PATH}" \
    LD_LIBRARY_PATH="/cortexlab/toolchains/current/lib:${LD_LIBRARY_PATH}" \
    PYTHONPATH="/cortexlab/toolchains/current/lib/python3.11/site-packages:${PYTHONPATH}" \
    QT_QPA_PLATFORM="offscreen"

# Install essential runtime tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    sqlite3 \
    ca-certificates \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Copy compiled Rust binaries from builder stage
COPY --from=builder /build/hardy-bpa-server /usr/local/bin/
COPY --from=builder /build/dtn-hdy-utils/target/release/dtn* /usr/local/bin/
COPY --from=builder /build/dtn-hdy-utils/target/release/hdy-stats /usr/local/bin/

# Create application and storage directories
RUN mkdir -p /opt/cxlb-hardy/flowgraphs /var/lib/hardy/bundles /etc/hardy

# Copy and compile GNU Radio flowgraphs
COPY udp_gfsk.grc /opt/cxlb-hardy/
RUN grcc -o /opt/cxlb-hardy/flowgraphs /opt/cxlb-hardy/udp_gfsk.grc

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /opt/cxlb-hardy

# Expose default Hardy gRPC and UDP ports
EXPOSE 50051 52001 52002

ENTRYPOINT ["/entrypoint.sh"]
