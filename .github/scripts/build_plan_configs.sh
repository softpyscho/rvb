#!/bin/bash
set -euo pipefail

# Decide which configs one run of build.yml builds, and write them to $GITHUB_OUTPUT as
# `configs=<JSON array>` (the matrix of the build job).
#
#   CONFIG_FILE=all                  -> `all:stable` then `all:beta`: EVERY enabled app of
#                                       configs/patches/*.toml, each in the pool its
#                                       patches-version routes it to. These are compiled
#                                       fresh from the TOMLs (build_prepare_config.sh does it
#                                       in the build job), NOT the watcher's generated
#                                       configs/*_build.json: those say what the watcher decided
#                                       to build next, and in the beta pool that is usually
#                                       nobody (an app is enabled there only while its patch
#                                       source's beta is newer than stable). A pool with no app
#                                       is left out; none at all is an error.
#   CONFIG_FILE=<path to a config>   -> exactly that file (the watcher's two calls and Manual CI).
#
# Anything else is rejected loudly: a mistyped name must not turn into "build nothing".
# Env: CONFIG_FILE (required), GITHUB_OUTPUT (optional; the array is also printed).

CONFIG_FILE="${CONFIG_FILE:?CONFIG_FILE not set}"
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# apps in a compiled pool: its object-valued entries (the scalar beside them is the channel)
count_apps() {
	jq '[to_entries[] | select(.value | type == "object")] | length' "$1"
}

selected=()
if [ "$CONFIG_FILE" = "all" ]; then
	python3 "$SCRIPTS/compile_patch_configs.py" > /dev/null
	for channel in stable beta; do
		n=$(count_apps "config.$channel.json")
		if [ "$n" -gt 0 ]; then
			selected+=("all:$channel")
			echo "all:$channel: $n app(s)" >&2
		else
			echo "all:$channel: no apps, left out" >&2
		fi
	done
	if [ "${#selected[@]}" -eq 0 ]; then
		echo "::error::No enabled app in configs/patches/*.toml." >&2
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
