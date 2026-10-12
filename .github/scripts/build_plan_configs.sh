#!/bin/bash
set -euo pipefail

# Decide which configs one run of build.yml builds, and write them to $GITHUB_OUTPUT as
# `configs=<JSON array>` (the matrix of the build job).
#
#   CONFIG_FILE=all      -> `all:stable` then `all:beta`: EVERY enabled app of configs/config.toml,
#                           each in the pool its patches-version routes it to. A pool with no app is
#                           left out; none at all is an error.
#   CONFIG_FILE=stable   -> `all:stable` only: every enabled app on the stable patches.
#   CONFIG_FILE=beta     -> `all:beta` only: every enabled app that sets patches-version = "beta".
#                           An empty pool is an error here, since it was asked for by name.
#   CONFIG_FILE=manual   -> configs/config.manual.toml, the scratch config of Manual CI.
#   CONFIG_FILE=<path>   -> exactly that file (the watcher's two calls pass configs/*_build.json).
#
# The pools are compiled fresh from configs/config.toml (build_prepare_config.sh does it in the build
# job), NOT taken from the watcher's generated configs/*_build.json: those say what the watcher decided
# to build next, and in the beta pool that is usually nobody (an app is enabled there only while its
# patch source's beta is newer than stable).
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
case "$CONFIG_FILE" in
	all)
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
			echo "::error::No enabled app in configs/config.toml." >&2
			exit 1
		fi
		;;
	stable | beta)
		python3 "$SCRIPTS/compile_patch_configs.py" > /dev/null
		n=$(count_apps "config.$CONFIG_FILE.json")
		if [ "$n" -eq 0 ]; then
			echo "::error::No enabled app is routed to the $CONFIG_FILE pool (an app opts in with patches-version = \"$CONFIG_FILE\" in configs/config.toml)." >&2
			exit 1
		fi
		selected+=("all:$CONFIG_FILE")
		echo "all:$CONFIG_FILE: $n app(s)" >&2
		;;
	manual)
		if [ ! -f configs/config.manual.toml ]; then
			echo "::error::configs/config.manual.toml does not exist." >&2
			exit 1
		fi
		selected=("configs/config.manual.toml")
		;;
	*)
		if [ ! -f "$CONFIG_FILE" ]; then
			echo "::error::config '$CONFIG_FILE' does not exist (use all, stable, beta, manual, or a path under configs/)." >&2
			exit 1
		fi
		selected=("$CONFIG_FILE")
		;;
esac

json=$(printf '%s\n' "${selected[@]}" | jq -R . | jq -sc .)
echo "Building: $json"
if [ -n "${GITHUB_OUTPUT-}" ]; then
	echo "configs=$json" >> "$GITHUB_OUTPUT"
fi
