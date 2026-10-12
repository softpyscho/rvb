#!/bin/bash
set -euo pipefail
CONFIG="${1:-}"

if [ -z "$CONFIG" ] || [ ! -f "$CONFIG" ]; then
  echo "::error::Config file not found: ${CONFIG:-(empty)}"
  exit 1
fi

{
  echo "CONFIG_FILE=$CONFIG"
  echo "TG_THREAD_ID=${TG_THREAD_STABLE:-}"
  # Every build is published to the one rolling archive release. Its tag is "stable" for the same
  # reason the release is: Obtainium and the update branch already point at that name.
  echo "ARCHIVE_TAG=stable"
} >> "$GITHUB_OUTPUT"
