#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/t2s-workspace.XXXXXX")
trap 'rm -rf "$CHECK_DIR"' EXIT
SOURCES=()
while IFS= read -r SOURCE; do SOURCES+=("$SOURCE"); done < <(rg --files T2SCameraApp Shared -g '*.swift' -g '!main.swift')
xcrun swiftc "${SOURCES[@]}" Tests/WorkspaceChecks.swift Tests/RGBChecks.swift -o "$CHECK_DIR/workspace-checks"
"$CHECK_DIR/workspace-checks"
