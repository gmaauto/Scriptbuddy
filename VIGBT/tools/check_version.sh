#!/usr/bin/env bash
# Fails if the version number disagrees between VERSION, code, CHANGELOG, SPEC and the app project.
set -euo pipefail
cd "$(dirname "$0")/.."
v=$(tr -d '[:space:]' < VERSION)
fail=0
check() { if ! grep -qF -- "$2" "$1"; then echo "✗ $1 does not contain: $2"; fail=1; else echo "✓ $1"; fi; }
[[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "✗ VERSION '$v' is not MAJOR.MINOR.PATCH"; exit 1; }
check Sources/VIGBTCore/Models/Versioning.swift "public static let string = \"$v\""
check CHANGELOG.md "## [$v]"
check SPEC.md "Document version: $v"
check App/project.yml "MARKETING_VERSION: \"$v\""
check design/screen-review.html "const VERSION = \"$v\";"
build=$(sed -n 's/.*public static let build = \([0-9]*\).*/\1/p' Sources/VIGBTCore/Models/Versioning.swift)
check App/project.yml "CURRENT_PROJECT_VERSION: \"$build\""
exit $fail
