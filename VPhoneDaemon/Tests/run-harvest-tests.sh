#!/bin/zsh
set -euo pipefail

# Builds the guest-independent harvest recorder and its tar.gz writer for the
# Mac and runs their checks: the timer's cadence and caps, the gesture
# debounce, notes, retention, startup recovery and the archive. The capture,
# the clock and the root directory are substitutes, so nothing here needs a
# guest.

daemon="${0:a:h:h}"
temporary="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vphone-harvest-tests.XXXXXX")"
trap '/bin/rm -rf "$temporary"' EXIT

/usr/bin/xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library \
    -module-name HarvestTests \
    -module-cache-path "$temporary/module-cache" \
    "$daemon/Daemon/GuestHarvest.swift" \
    "$daemon/Daemon/GuestHarvestArchive.swift" \
    "$daemon/Tests/HarvestTests.swift" \
    -o "$temporary/harvest-tests"

"$temporary/harvest-tests"
