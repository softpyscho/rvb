#!/bin/bash
set -euo pipefail

RAW_TRIGGER_PATCHES=${RAW_TRIGGER_PATCHES:-0}
RAW_TRIGGER_APP_UPDATE=${RAW_TRIGGER_APP_UPDATE:-0}

TRIGGER_BUILD=0

if [ "$RAW_TRIGGER_PATCHES" = "1" ] || [ "$RAW_TRIGGER_APP_UPDATE" = "1" ]; then
  CFG="configs/build.json"
  if [ -f "$CFG" ]; then
    ENABLED_COUNT=$(jq '[.[] | objects | select(.enabled != false)] | length' "$CFG" || echo 0)
    if [ "${ENABLED_COUNT:-0}" -gt 0 ]; then
      TRIGGER_BUILD=1
    else
      echo "::notice::Skipping build trigger: no enabled apps in $CFG"
    fi
  fi
fi

echo "TRIGGER_BUILD=$TRIGGER_BUILD" >> "$GITHUB_OUTPUT"
