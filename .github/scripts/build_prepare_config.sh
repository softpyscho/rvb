#!/bin/bash
set -euo pipefail

# Turn the `config_file` input of build.yml into the config file the build reads, and write it to
# $GITHUB_OUTPUT as `config=<path>`.
#
#   all      -> compile configs/config.toml (compile_patch_configs.py) and use config.json: every
#               enabled app, no watcher decision involved. No enabled app at all is an error.
#   manual   -> configs/config.manual.toml, the scratch config of Manual CI.
#   <path>   -> exactly that file (the watcher passes configs/build.json: the apps that are due).
#
# Anything else is rejected loudly: a mistyped name must not turn into "build nothing".
# Env: CONFIG_FILE (required), GITHUB_OUTPUT (optional; the path is also printed).

CONFIG_FILE="${CONFIG_FILE:?CONFIG_FILE not set}"
SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$CONFIG_FILE" in
	all)
		python3 "$SCRIPTS/compile_patch_configs.py" > /dev/null
		config="config.json"
		napps=$(jq '[to_entries[] | select(.value | type == "object")] | length' "$config")
		if [ "$napps" -eq 0 ]; then
			echo "::error::No enabled app in configs/config.toml." >&2
			exit 1
		fi
		echo "Compiled $napps app(s) from configs/config.toml." >&2
		;;
	manual)
		if [ ! -f configs/config.manual.toml ]; then
			echo "::error::configs/config.manual.toml does not exist." >&2
			exit 1
		fi
		config="configs/config.manual.toml"
		;;
	*)
		if [ ! -f "$CONFIG_FILE" ]; then
			echo "::error::config '$CONFIG_FILE' does not exist (use all, manual, or a path under configs/)." >&2
			exit 1
		fi
		config="$CONFIG_FILE"
		;;
esac

echo "Config: $config"
if [ -n "${GITHUB_OUTPUT-}" ]; then
	echo "config=$config" >> "$GITHUB_OUTPUT"
fi
