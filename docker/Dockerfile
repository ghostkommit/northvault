# syntax=docker/dockerfile:1
FROM debian:bookworm-slim AS bitcoin-download
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
ARG TARGETARCH
# Bitcoin Core 30.4 hashes from bitcoin-core/guix.sigs, 30.4/fanquake/all.SHA256SUMS.
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) arch=x86_64; checksum=051a18c595d9a27df23cb7187ff9fb343e90943cb142af751e12787806500c3d ;; \
      arm64) arch=aarch64; checksum=f8c7dfda24fbf14de9f32c9d793779a97470e0420c84999fca83389ed1dcc572 ;; \
      *) echo "Supported architectures: amd64, arm64" >&2; exit 1 ;; \
    esac; \
    curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
      "https://bitcoincore.org/bin/bitcoin-core-30.4/bitcoin-30.4-${arch}-linux-gnu.tar.gz" \
      --output /tmp/bitcoin.tar.gz; \
    echo "$checksum  /tmp/bitcoin.tar.gz" | sha256sum --check --strict; \
    tar -xzf /tmp/bitcoin.tar.gz -C /opt; \
    rm /tmp/bitcoin.tar.gz

FROM rust:1.94.0-bookworm AS rust-build
ENV RUSTUP_TOOLCHAIN=1.94.0 CARGO_BUILD_JOBS=2
RUN apt-get update && apt-get install -y --no-install-recommends \
      clang libclang-dev cmake python3 \
    && rm -rf /var/lib/apt/lists/*

FROM rust-build AS electrs-build
# electrs v0.11.1. v0.12 requires Core 31+ and a different index backend.
RUN git init /opt/electrs \
    && cd /opt/electrs \
    && git remote add origin https://github.com/romanz/electrs.git \
    && git fetch --depth 1 origin 35216c6d30148be8e6763d913d437330f431fc03 \
    && git checkout --detach FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = 35216c6d30148be8e6763d913d437330f431fc03 \
    && cargo build --locked --release --bin electrs

FROM debian:bookworm-slim AS services
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 libstdc++6 libgcc-s1 ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 1000 tester \
    && mkdir -p /data/bitcoin /data/electrs \
    && printf 'disposable regtest\n' > /data/bitcoin/northvault-test-only \
    && chown -R tester:tester /data
COPY --from=bitcoin-download /opt/bitcoin-30.4/bin/bitcoind /usr/local/bin/bitcoind
COPY --from=bitcoin-download /opt/bitcoin-30.4/bin/bitcoin-cli /usr/local/bin/bitcoin-cli
COPY --from=electrs-build /opt/electrs/target/release/electrs /usr/local/bin/electrs
COPY docker/service.py /opt/northvault/service.py
USER tester
CMD ["python3", "/opt/northvault/service.py", "node"]

FROM rust-build AS tests
RUN useradd --create-home --uid 1000 tester \
    && mkdir -p /workspace \
    && chown -R tester:tester /workspace /usr/local/cargo
COPY --from=bitcoin-download /opt/bitcoin-30.4/bin/bitcoin-cli /usr/local/bin/bitcoin-cli
COPY --chown=tester:tester core/Cargo.toml core/Cargo.lock /workspace/core/
COPY --chown=tester:tester core/src /workspace/core/src
COPY --chown=tester:tester core/tests /workspace/core/tests
COPY --chown=tester:tester core/examples /workspace/core/examples
COPY --chown=tester:tester descriptor-core/Cargo.toml descriptor-core/Cargo.lock /workspace/descriptor-core/
COPY --chown=tester:tester descriptor-core/src /workspace/descriptor-core/src
COPY --chown=tester:tester descriptor-core/tests /workspace/descriptor-core/tests
COPY --chown=tester:tester descriptor-core/examples /workspace/descriptor-core/examples
COPY docker/service.py docker/test_service.py docker/run-tests.sh /opt/northvault/
USER tester
# Fetch and compile during the build: test execution needs no Internet access.
RUN cd /workspace/descriptor-core && cargo test --locked --lib --tests --no-run \
    && cd /workspace/core && cargo test --locked --no-default-features --lib --tests --no-run
ENV NORTHVAULT_TEST_BITCOIN_CLI=/usr/local/bin/bitcoin-cli \
    NORTHVAULT_TEST_NODE_DIR=/data/bitcoin \
    NORTHVAULT_TEST_RPC_PORT=18443 \
    NORTHVAULT_TEST_ELECTRUM_PORT=50001 \
    CARGO_NET_OFFLINE=true
WORKDIR /workspace
CMD ["sh", "/opt/northvault/run-tests.sh"]

FROM tests AS coverage
USER root
RUN rustup component add llvm-tools-preview --toolchain 1.94.0
USER tester
RUN CARGO_NET_OFFLINE=false cargo install cargo-llvm-cov --version 0.9.1 --locked
COPY docker/run-coverage.sh docker/check-rust-coverage.py docker/test_coverage.py /opt/northvault/
RUN python3 -B -m unittest discover -s /opt/northvault -p 'test_coverage.py'
CMD ["sh", "/opt/northvault/run-coverage.sh"]
