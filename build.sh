#!/bin/bash
#
# The real build script lives in camera_extension/, next to the Xcode project
# it generates, the build number it bumps and the build.config it reads. This
# runs it from the repository root, which is where you land after a clone.
#
# Everything is forwarded, so ./build.sh --release works the same from either
# directory. See docs/building.md.

exec "$(dirname "$0")/camera_extension/build.sh" "$@"
