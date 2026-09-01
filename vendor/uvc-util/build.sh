#!/bin/sh
# Rebuilds uvc-util from source. Only needed if the vendored binary doesn't
# run on this Mac (wrong architecture, etc). Requires Xcode Command Line
# Tools (clang) -- no full Xcode.app needed.
set -e
cd "$(dirname "$0")"
clang -framework IOKit -framework Foundation -framework CoreFoundation \
  -o build/uvc-util src/*.m
echo "Built vendor/uvc-util/build/uvc-util"
