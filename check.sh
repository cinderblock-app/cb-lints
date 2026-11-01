#!/usr/bin/env bash
# Analyzes and tests both packages. CI runs this on every push.
set -euo pipefail
cd "$(dirname "$0")"
for package in cb_lints cb_checks; do
  (cd "$package" && dart pub get && dart analyze --fatal-infos && dart test)
done
