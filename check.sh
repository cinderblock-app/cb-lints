#!/usr/bin/env bash
# Analyzes and tests both packages. CI runs this on every push.
set -euo pipefail
cd "$(dirname "$0")"
# pub upgrade, as that is how the analysis server resolves the plugin.
for package in cb_lints cb_checks; do
  (cd "$package" && dart pub upgrade && dart analyze --fatal-infos && dart test)
done

# Unit tests cannot see a plugin that never loads, and a clean run looks the same
# as an inert one, so the fixture must draw every rule, from its package root.
cd fixture
dart pub get
output=$(dart analyze --format=machine . 2>&1 || true)
for rule in api_class_in_presentation connectivity_event_outside_app_epics memo_input_is_collection_field \
  platform_check_outside_platform_support reader_without_ignore_no_connection route_page_outside_pages; do
  if ! grep -qi "|$rule|" <<<"$output"; then
    echo "fixture did not draw $rule. The analyzer said:" >&2
    echo "$output" >&2
    exit 1
  fi
done
echo "fixture drew every rule."
