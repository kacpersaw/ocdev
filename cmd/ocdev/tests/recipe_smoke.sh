#!/usr/bin/env bash
# Explicitly opt-in: runs a trusted recipe against a user-prepared test snapshot.
set -euo pipefail
[[ "${OCDEV_LIVE_TESTS:-}" == 1 ]] || { echo 'Set OCDEV_LIVE_TESTS=1 to authorize live operations' >&2; exit 1; }
: "${OCDEV_TEST_RECIPE:?Set OCDEV_TEST_RECIPE to a trusted test recipe file}"
: "${OCDEV_TEST_TASK:?Set OCDEV_TEST_TASK to a harmless declared smoke task}"
binary="${OCDEV_TEST_BINARY:-./bin/ocdev}"
name="ocdev-smoke-$$-${RANDOM}"
created=0
cleanup() {
  if [[ $created == 1 ]]; then
    "$binary" delete "$name" --json || {
      echo "Cleanup failed; inspect retained test environment: $name" >&2
      return 1
    }
  fi
}
trap cleanup EXIT
"$binary" recipe validate "$OCDEV_TEST_RECIPE" --json
"$binary" create "$name" --recipe "$OCDEV_TEST_RECIPE" --dry-run --json
# Mark before creation so a retained failed setup is also offered normal cleanup.
created=1
"$binary" create "$name" --recipe "$OCDEV_TEST_RECIPE" --json
"$binary" inspect "$name" --json
"$binary" task run "$name" "$OCDEV_TEST_TASK" --json
if [[ "${OCDEV_TEST_SERVICES:-}" == 1 ]]; then
  "$binary" services list "$name" --json
fi
"$binary" delete "$name" --dry-run --json
"$binary" delete "$name" --json
created=0
