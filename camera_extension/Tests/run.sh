#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/t2s-calibration.XXXXXX")
trap 'rm -rf "$CHECK_DIR"' EXIT
CHECK_PYTHON="${T2S_TEST_PYTHON:-python3}"
if [ -z "${T2S_TEST_PYTHON:-}" ] && [ -x ../venv/bin/python ]; then
    CHECK_PYTHON=../venv/bin/python
fi
"$CHECK_PYTHON" Tests/generate_reference.py "$CHECK_DIR/fixtures"
xcrun swiftc T2SCameraApp/ThermalDecoder.swift T2SCameraApp/Calibration.swift \
    T2SCameraApp/Measurements.swift T2SCameraApp/ThermalProcessor.swift \
    T2SCameraApp/ImageRotation.swift Tests/RadiometryChecks.swift \
    Tests/CalibrationChecks.swift -o "$CHECK_DIR/calibration-checks"
"$CHECK_DIR/calibration-checks" "$CHECK_DIR/fixtures"
