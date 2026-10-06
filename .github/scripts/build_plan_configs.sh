#!/bin/bash
set -euo pipefail

# Decide which config files one run of build.yml builds, and write them to $GITHUB_OUTPUT as
# `configs=<JSON array>` (the matrix of the build job).
#
#   CONFIG_FILE=all                  -> the stable pool, then the beta pool: every app, one run.
#                                       A pool with no app in it is left out (building an empty
#                                       pool would fail for want of anything to do), and it is an
#                                       error when neither has one.
#   CONFIG_FILE=<path to a config>   -> exactly that file (the watcher's two calls and Manual CI).
#
# Anything else is rejected loudly: a mistyped name must not turn into "build nothing".
# Env: CONFIG_FILE (required), GITHUB_OUTPUT (optional; the array is also printed).

CONFIG_FILE="${CONFIG_FILE:?CONFIG_FILE not set}"
POOLS=("configs/stable_build.json" "configs/beta_build.json")

# apps in a generated pool: its object-valued entries (the scalars next to them are file defaults)
count_apps() {
	jq '[to_entries[] | select(.value | type == "object")] | length' "$1"
}

selected=()
if [ "$CONFIG_FILE" = "all" ]; then
	for pool in "${POOLS[@]}"; do
		if [ ! -f "$pool" ]; then
			echo "::error::$pool is missing - the watcher has not generated the pools yet (run CI first)." >&2
			exit 1
		fi
		n=$(count_apps "$pool")
		if [ "$n" -gt 0 ]; then
			selected+=("$pool")
			echo "$pool: $n app(s)" >&2
		else
			echo "$pool: no apps, left out" >&2
		fi
	done
	if [ "${#selected[@]}" -eq 0 ]; then
		echo "::error::Neither pool has an app to build." >&2
		exit 1
	fi
else
	if [ ! -f "$CONFIG_FILE" ]; then
		echo "::error::config file '$CONFIG_FILE' does not exist (use 'all' or a path under configs/)." >&2
		exit 1
	fi
	selected=("$CONFIG_FILE")
fi

json=$(printf '%s\n' "${selected[@]}" | jq -R . | jq -sc .)
echo "Building: $json"
if [ -n "${GITHUB_OUTPUT-}" ]; then
	echo "configs=$json" >> "$GITHUB_OUTPUT"
fi
