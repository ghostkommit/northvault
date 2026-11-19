#!/usr/bin/env bash
# Every static check CI runs. Rust checks are required; the other linters run
# when installed (CI installs all of them) and are reported when skipped.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "$ROOT"

for crate in core descriptor-core; do
  # Enter the crate so rustup selects its pinned toolchain.
  (cd "$crate" && cargo fmt -- --check && cargo clippy --locked --all-targets -- -D warnings)
done
# The air-gapped build without USB support must stay warning-free too.
(cd core && cargo clippy --locked --no-default-features --all-targets -- -D warnings)
# The emulator feature is for tests only: lint it, and keep it out of anything that builds the app.
(cd core && cargo clippy --locked --features emulator --all-targets -- -D warnings)
if grep -n 'emulator' scripts/build*.sh scripts/dist.sh .github/workflows/release.yml; then
  echo "the emulator feature must not reach an app or release build" >&2
  exit 1
fi

optional() {
  if command -v "$1" >/dev/null; then
    "$@"
  elif [[ -n "${CI:-}" ]]; then
    echo "$1 is required in CI" >&2
    exit 1
  else
    echo "skipped: $1 is not installed" >&2
  fi
}
# With Command Line Tools only, SwiftLint needs to be told where SourceKit lives.
TOOLS_LIB="$(xcode-select -p)/usr/lib"
if [[ -d "$TOOLS_LIB/sourcekitdInProc.framework" ]]; then
  export DYLD_FRAMEWORK_PATH="$TOOLS_LIB"
fi
optional shellcheck -x scripts/*.sh docker/*.sh
optional swiftlint lint --strict --quiet
optional actionlint
python3 -B -m unittest discover -s docker -p 'test_coverage.py'
python3 -B scripts/test-coverage.py
