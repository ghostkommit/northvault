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

FROM tests AS hardware-tests
USER root
# hidapi's hidraw backend links libudev; the default image builds without USB support.
RUN apt-get update && apt-get install -y --no-install-recommends libudev-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*
USER tester
RUN cd /workspace/core && CARGO_NET_OFFLINE=false cargo test --locked --features emulator --test emulator_hardware --no-run
CMD ["sh", "-c", "cd /workspace/core && cargo test --locked --offline --features emulator --test emulator_hardware -- --ignored --test-threads=1"]

# Ledger's Bitcoin Test app, built from its 2.5.0 release tag for the Nano S Plus
# firmware emulator. Test-only: the app never leaves these images.
FROM ghcr.io/ledgerhq/ledger-app-builder/ledger-app-builder-lite@sha256:45ec491f28489aa0337eea8d50e9962a700ed41054081ee1b639bc1b128e6a32 AS ledger-app
RUN git clone --quiet https://github.com/LedgerHQ/app-bitcoin-new.git /app \
    && cd /app && git checkout --quiet 0fec192f13cac736107d15614ccbbe3f2b8446c1 \
    && make DEBUG=0 COIN=bitcoin_testnet BOLOS_SDK="$NANOSP_SDK" -j4

FROM ghcr.io/ledgerhq/speculos@sha256:56c7ec84c903147dac28e68706d3241218a3d9beb9562dd4a8c02947b2a24f47 AS ledger-emulator
COPY --from=ledger-app /app/bin/app.elf /apps/btc-test.elf
