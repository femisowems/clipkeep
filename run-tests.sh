#!/bin/bash
# Run ClipKeep's logic tests (tests.swift). CI runs this before
# building the app; a failure here fails the whole run.
#
# The test runner is built from a copy of main.swift with the
# app entry stripped (everything from the "// MARK: - Main"
# line to the end of the file), so tests.swift's @main is the
# only entry point. An earlier version relied on a -D flag +
# #if guard to compile the entry out; CI's compiler kept
# seeing the entry anyway, so the strip is mechanical now.
set -e
cd "$(dirname "$0")"

sed '/^\/\/ MARK: - Main/,$d' main.swift > .tests-main.swift
trap 'rm -f .tests-main.swift clipkeep-tests' EXIT

swiftc -parse-as-library -O -o clipkeep-tests .tests-main.swift tests.swift \
    -framework Cocoa -framework Carbon -framework ApplicationServices \
    -framework Vision -framework UniformTypeIdentifiers -framework ImageIO

./clipkeep-tests
