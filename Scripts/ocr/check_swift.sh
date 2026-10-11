#!/usr/bin/env bash
#
#  check_swift.sh
#  Hoshi Reader
#
#  Copyright © 2026 Manhhao.
#  SPDX-License-Identifier: GPL-3.0-or-later
#
#  Builds the macOS harness (the app's OCR sources) and compares it with reference.py on every
#  fixture page: accuracy against the ground truth, character agreement and box deltas.
#
#  Usage: Scripts/ocr/check_swift.sh PACK_DIR [FIXTURES_DIR]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACK="$(cd "$1" && pwd)"
FIXTURES="$(cd "${2:-$SCRIPT_DIR/../../Tests/Fixtures/pdf}" && pwd)"
PYTHON="$SCRIPT_DIR/.venv/bin/python"
OUT="$SCRIPT_DIR/build/check/$(basename "$PACK")"

swift build -c release --package-path "$SCRIPT_DIR/harness" 2>&1 | grep -E "error|warning: " || true
HARNESS="$SCRIPT_DIR/harness/.build/release/OCRHarness"
mkdir -p "$OUT"

for truth in "$FIXTURES"/*.p*.txt; do
    file="$(basename "$truth" .txt)"
    name="${file%.p*}"
    page="${file##*.p}"
    prefix="$OUT/$name-$page"
    echo "=== $name p$page"
    "$HARNESS" "$PACK" "$FIXTURES/$name.pdf" "$((page - 1))" "$prefix" "$truth" | grep -v "^reading order"
    "$PYTHON" -I "$SCRIPT_DIR/reference.py" run "$PACK" "$prefix.png" --json "$prefix.ref.json" > /dev/null
    "$PYTHON" -I "$SCRIPT_DIR/reference.py" compare "$prefix.json" "$prefix.ref.json"
done
