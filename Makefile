.PHONY: help fetch build run core project open test clean lint fmt coverage dist
.DEFAULT_GOAL := help

help:        ## List the available targets
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed -E 's/:.*## */\t/' | expand -t 22

lint:        ## Formatting, clippy, shell/Swift/workflow linters and coverage-gate self-tests
	bash scripts/lint.sh

fmt:         ## Format the Rust crates
	cd core && cargo fmt
	cd descriptor-core && cargo fmt

coverage: coverage-rust-check coverage-swift-check ## Both coverage gates (Docker and macOS tools required)

dist:        ## Zip the built app with a SHA-256 checksum into dist/ (run make build first)
	bash scripts/dist.sh $(VERSION)

fetch:       ## Download the locked Rust dependencies (later build steps run offline)
	cd core && cargo fetch --locked
	cd descriptor-core && cargo fetch --locked

build: fetch ## Build a local app bundle (Command Line Tools sufficient)
	bash ./scripts/build-local.sh

run: build   ## Build and launch the local app
	open macos/build/Northvault.app

core:        ## Build Rust core + Swift bindings + XCFramework
	./scripts/build-core.sh

project: core storage-apple ## Generate the Xcode project
	cd macos && xcodegen generate

open: project ## Generate and open the Xcode project
	open macos/Northvault.xcodeproj

test:        ## Rust tests, including offline Regtest integration workflows
	cd core && cargo test --locked --lib --tests
	cd descriptor-core && cargo test --locked

.PHONY: regtest-test
regtest-test: ## Disposable Bitcoin Core + electrs integration tests
	python3 scripts/test-regtest.py

.PHONY: docker-test docker-up docker-down
docker-test: ## Portable Rust + live Regtest suites; only Docker is required
	docker compose run --build --rm tests

docker-up: ## Start the disposable node and indexer, waiting for readiness
	docker compose up --build --wait --wait-timeout 180

docker-down: ## Stop Regtest services, retaining disposable chain/index volumes
	docker compose down

.PHONY: coverage-rust coverage-rust-check
coverage-rust: ## Measure portable Rust plus live Regtest coverage inside Docker
	docker compose run --build --rm coverage

coverage-rust-check: ## Require 80% measured Rust lines and 100% of the critical files
	docker compose run --build --rm coverage sh /opt/northvault/run-coverage.sh --min-lines 80

.PHONY: coverage-swift
coverage-swift: ## Instrument synthetic Swift suites and report uncovered sources
	bash scripts/coverage-swift.sh

.PHONY: coverage-swift-check
coverage-swift-check: ## Require 80% measured Swift lines; list missing sources
	bash scripts/coverage-swift.sh --min-lines 80

.PHONY: qr-test
qr-test:     ## Branded QR rendering, decode and PSBT round trips (run make build first)
	bash scripts/test-qr.sh

.PHONY: wallet-ui-test
wallet-ui-test: ## Native account screens backed by temporary funded Regtest fixtures
	bash scripts/test-wallet-ui.sh

clean:       ## Remove build outputs
	cd core && cargo clean
	rm -rf macos/Generated macos/Northvault.xcodeproj macos/build dist

.PHONY: storage-test storage-apple
storage-test: ## Shared encryption/storage checks without full Xcode
	bash scripts/test-storage.sh
storage-apple: ## Build macOS/iOS descriptor libraries and generate storage Xcode targets
	bash scripts/build-storage-apple.sh

.PHONY: storage-build-local
storage-build-local: ## Standalone descriptor manager, Command Line Tools supported
	bash scripts/build-storage-app-local.sh
