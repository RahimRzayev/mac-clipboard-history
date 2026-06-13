#!/bin/bash
# Runs the unit tests. The extra flags are only needed when building with Command Line
# Tools (no Xcode): CLT ships Testing.framework outside the default search/runtime paths.
# With full Xcode installed, plain `swift test` works.
set -euo pipefail
cd "$(dirname "$0")/.."

CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
CLT_TESTLIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

if [ -d "$CLT_FRAMEWORKS" ] && ! xcodebuild -version >/dev/null 2>&1; then
    exec swift test \
        -Xswiftc -F"$CLT_FRAMEWORKS" \
        -Xlinker -F"$CLT_FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS" \
        -Xlinker -rpath -Xlinker "$CLT_TESTLIB" \
        "$@"
fi
exec swift test "$@"
