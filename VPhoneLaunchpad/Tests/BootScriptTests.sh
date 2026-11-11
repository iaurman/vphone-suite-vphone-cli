#!/bin/zsh
set -euo pipefail

launchpad="${0:a:h:h}"
temporary="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$temporary"' EXIT

/usr/bin/xcrun swiftc -swift-version 6 -strict-concurrency=complete \
    -parse-as-library \
    "$launchpad/VPhoneLaunchpadShared/VPhoneLaunchpadBundleStore.swift" \
    "$launchpad/VPhoneLaunchpadShared/VPhoneLaunchpadHostPolicy.swift" \
    "$launchpad/VPhoneLaunchpadHelper/VPhoneLaunchpadHelperCodeCheck.swift" \
    "$launchpad/VPhoneLaunchpadHelper/VPhoneLaunchpadHelperBootScript.swift" \
    "$launchpad/Tests/BootScriptTests.swift" \
    -o "$temporary/boot-script-tests"
"$temporary/boot-script-tests" "$@"
