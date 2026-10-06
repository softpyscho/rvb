#!/bin/bash
set -euo pipefail

# Turn one matrix value of build.yml into the config file the build reads, and write it to
# $GITHUB_OUTPUT as `config=<path>`.
#
#   all:stable | all:beta   -> compile configs/patches/*.toml (compile_patch_configs.py) and use the
#                              channel's pool, config.stable.json / config.beta.json: every enabled
#                              app routed to that pool, no watcher decision involved. The file name
#                              keeps "beta" in it, which is how build_resolve_context.sh tells a
#                              pre-release pool.
#   anything else           -> returned as given (an existing config file).
#
# Env: CONFIG_FILE (required), GITHUB_OUTPUT (optional; the path is also printed).

CONFIG_FILE="${CONFIG_FILE:?CONFIG_FILE not set}"
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$CONFIG_FILE" in
	all:stable | all:beta)
		channel="${CONFIG_FILE#all:}"
		python3 "$SCRIPTS/compile_patch_configs.py" > /dev/null
		config="config.$channel.json"
		napps=$(jq '[to_entries[] | select(.value | type == "object")] | length' "$config")
		if [ "$napps" -eq 0 ]; then
			echo "::error::no enabled app is routed to the $channel pool." >&2
			exit 1
		fi
		echo "Compiled $napps app(s) for the $channel pool from configs/patches/." >&2
		;;
	all:*)
		echo "::error::unknown pool '$CONFIG_FILE' (expected all:stable or all:beta)." >&2
		exit 1
		;;
	*)
		config="$CONFIG_FILE"
		;;
esac

echo "Config: $config"
if [ -n "${GITHUB_OUTPUT-}" ]; then
	echo "config=$config" >> "$GITHUB_OUTPUT"
fi
