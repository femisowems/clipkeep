#!/bin/bash
# Run ClipKeep's logic tests (tests.swift). CI runs this before
# building the app; a failure here fails the whole run.
# main.swift is compiled with CLIPKEEP_TESTS, which removes its
# app entry point so tests.swift's @main can be the entry.
set -e
cd "$(dirname "$0")"

swiftc -D CLIPKEEP_TESTS -O -o clipkeep-tests main.swift tests.swift \
    -framework Cocoa -framework Carbon -framework ApplicationServices \
    -framework Vision -framework UniformTypeIdentifiers -framework ImageIO

./clipkeep-tests
rm -f clipkeep-tests
