#!/bin/sh
#
# Runs every test/system/*_test.sh file in sequence and aggregates results.
# Each file is a standalone test suite; this script just chains them.

set -u

SYSTEM_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SYSTEM_DIR"

FAILED_FILES=""
TOTAL_FILES=0

echo "=== omq system tests ==="
echo

for f in *_test.sh; do
  TOTAL_FILES=$((TOTAL_FILES + 1))
  echo "--- $f ---"
  if sh "$f"; then
    :
  else
    FAILED_FILES="$FAILED_FILES $f"
  fi
  echo
done

if [ -z "$FAILED_FILES" ]; then
  echo "OK — $TOTAL_FILES test file(s) passed"
  exit 0
else
  echo "FAIL — failed test files:$FAILED_FILES"
  exit 1
fi
