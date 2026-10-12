#!/bin/bash
set -euo pipefail

# Convert utils.sh to Unix line endings if needed
dos2unix scripts/utils.sh 2>/dev/null || true

source scripts/utils.sh
set_prebuilts

# Use the pre-compiled config if available, or compile as fallback
[ -f config.json ] || python3 .github/scripts/compile_patch_configs.py
CONFIG_INPUTS=(config.json)

mkdir -p state
[ -f state/app_versions.json ] || echo '{}' > state/app_versions.json
> fetched_app_versions.jsonl
CHECK_ONLY_LISTED=$(jq -r '."_check_only_listed" // false' state/app_versions.json)

if [ "$CHECK_ONLY_LISTED" = "true" ]; then
    jq -r 'to_entries | map(select(.key | startswith("_") | not)) | .[] | "\(.key)|\(.value.keys[0])"' state/app_versions.json > check_list.txt
else
    # All enabled apps of the config. "Enabled" is the default
    # (CONFIG.md: enabled = true), so a table that never writes the key still counts: the
    # compiled pools omit disabled apps already, and requiring an explicit `true` here
    # silently exempted every app whose TOML relied on the default from version checks -
    # for a mirrored app, which has no patch release to fall back on, that meant never building.
    ENABLED_APPS=$(jq -r -s 'add | to_entries | map(select((.value | type == "object") and .value.enabled != false)) | .[].key' "${CONFIG_INPUTS[@]}")
    
    # Get all grouped apps to exclude them
    GROUPED_APPS=$(jq -r 'to_entries | map(select(.key | startswith("_") | not)) | .[].value.keys[]?' state/app_versions.json 2>/dev/null || echo "")
    
    > check_list.txt
    
    # Add groups first
    jq -r 'to_entries | map(select(.key | startswith("_") | not)) | .[] | "\(.key)|\(.value.keys[0])"' state/app_versions.json >> check_list.txt
    
    # Add non-grouped enabled apps
    for app in $ENABLED_APPS; do
        if ! echo "$GROUPED_APPS" | grep -qx "$app"; then
            echo "$app|$app" >> check_list.txt
        fi
    done
fi

declare -A cached_versions

while IFS='|' read -r group app; do
    if [ -z "$group" ] || [ -z "$app" ]; then continue; fi
    echo "::group::Fetching version for $group ($app)..."
    
    mapfile -t _urls < <(
        jq -r -s --arg app "$app" '
            add | .[$app] as $a |
            ($a["uptodown-dlurl"] // ""),
            ($a["apkmirror-dlurl"] // ""),
            ($a["apkpure-dlurl"] // ""),
            ($a["apkcombo-dlurl"] // ""),
            ($a["github-dlurl"] // ""),
            ($a["actions-dlurl"] // ""),
            ($a["actions-artifact"] // ""),
            ($a.version // ""),
            ($a["pkg-name"] // "")
        ' "${CONFIG_INPUTS[@]}"
    )
    version_mode="${_urls[7]:-}"
    pkg_name="${_urls[8]:-}"
    actions_url="${_urls[5]:-}"
    # get_actions_resp reads its artifact regex from the engine's per-app args
    declare -A args=([actions_artifact]="${_urls[6]:-}")
    uptodown_url="${_urls[0]:-}"
    apkmirror_url="${_urls[1]:-}"
    apkpure_url="${_urls[2]:-}"
    apkcombo_url="${_urls[3]:-}"
    github_url="${_urls[4]:-}"

    dlurls=()
    sources=()
    # `waenhancer` apps ask the sources in the engine's order (APKMirror, then Uptodown), not
    # the usual Uptodown-first one: the build takes its version from the first source that
    # lists a supported build, and the version recorded here has to be that one.
    if [ "$version_mode" = waenhancer ]; then
        [ -n "$apkmirror_url" ] && { dlurls+=("$apkmirror_url"); sources+=("apkmirror"); }
        [ -n "$uptodown_url" ] && { dlurls+=("$uptodown_url"); sources+=("uptodown"); }
    else
        [ -n "$uptodown_url" ] && { dlurls+=("$uptodown_url"); sources+=("uptodown"); }
        [ -n "$apkmirror_url" ] && { dlurls+=("$apkmirror_url"); sources+=("apkmirror"); }
    fi
    [ -n "$apkpure_url" ] && { dlurls+=("$apkpure_url"); sources+=("apkpure"); }
    [ -n "$apkcombo_url" ] && { dlurls+=("$apkcombo_url"); sources+=("apkcombo"); }
    [ -n "$github_url" ] && { dlurls+=("$github_url"); sources+=("github"); }
    [ -n "$actions_url" ] && { dlurls+=("$actions_url"); sources+=("actions"); }

    if [ ${#dlurls[@]} -eq 0 ]; then
        echo "::warning::No dlurl for $app, skipping"
        echo "::endgroup::"
        continue
    fi
    
    latest_ver=""
    for i in "${!dlurls[@]}"; do
        dlurl="${dlurls[$i]}"
        source="${sources[$i]}"
        
        if [ "$version_mode" = waenhancer ]; then
            # The newest build the latest WaEnhancer release supports (the same narrowing
            # mirror_rv applies), so a new WaEnhancer release, or a new build inside what it
            # supports, is what moves the recorded version and triggers a build. Not cached by
            # URL: the answer depends on the package, not on the page.
            if [[ "$source" != "apkmirror" && "$source" != "uptodown" ]]; then continue; fi
            "get_${source}_resp" "$dlurl" || { echo "::warning::Failed $source resp for $app"; continue; }
            wae_rc=0
            vers=$(waenhancer_vers "$source" "$pkg_name") || wae_rc=$?
            if [ "$wae_rc" -ne 0 ]; then
                echo "::warning::Cannot read the WaEnhancer support list for $app"
                break
            fi
            latest_ver=$(get_highest_ver <<<"$vers") || latest_ver=""
            if [ -n "$latest_ver" ]; then
                sleep $((RANDOM % 5 + 3)) # same politeness as a scrape of any other source
                break
            fi
        elif [ -n "${cached_versions[$dlurl]:-}" ]; then
            latest_ver="${cached_versions[$dlurl]}"
            echo "::notice::Reusing cached version for $app: $latest_ver"
            break
        else
            if [[ "$source" == "uptodown" ]]; then
                get_uptodown_resp "$dlurl" || { echo "::warning::Failed uptodown resp for $app"; continue; }
                vers=$(get_uptodown_vers) || { echo "::warning::Failed uptodown vers for $app"; continue; }
                latest_ver=$(echo "$vers" | get_highest_ver) || true
            elif [[ "$source" == "apkmirror" ]]; then
                get_apkmirror_resp "$dlurl" || { echo "::warning::Failed apkmirror resp for $app"; continue; }
                vers=$(get_apkmirror_vers) || { echo "::warning::Failed apkmirror vers for $app"; continue; }
                latest_ver=$(echo "$vers" | get_highest_ver) || true
            elif [[ "$source" == "apkpure" ]]; then
                get_apkpure_resp "$dlurl" || { echo "::warning::Failed apkpure resp for $app"; continue; }
                vers=$(get_apkpure_vers) || { echo "::warning::Failed apkpure vers for $app"; continue; }
                latest_ver=$(echo "$vers" | get_highest_ver) || true
            elif [[ "$source" == "apkcombo" ]]; then
                get_apkcombo_resp "$dlurl" || { echo "::warning::Failed apkcombo resp for $app"; continue; }
                vers=$(get_apkcombo_vers) || { echo "::warning::Failed apkcombo vers for $app"; continue; }
                latest_ver=$(echo "$vers" | get_highest_ver) || true
            elif [[ "$source" == "github" ]]; then
                get_github_resp "$dlurl" || { echo "::warning::Failed github resp for $app"; continue; }
                vers=$(get_github_vers) || { echo "::warning::Failed github vers for $app"; continue; }
                latest_ver=$(echo "$vers" | get_highest_ver) || true
            elif [[ "$source" == "actions" ]]; then
                get_actions_resp "$dlurl" || { echo "::warning::Failed actions resp for $app"; continue; }
                latest_ver=$(get_actions_vers)
            fi
            
            if [ -n "$latest_ver" ]; then
                cached_versions[$dlurl]="$latest_ver"
                # Sleep to avoid rate limiting only if we actually fetched
                sleep $((RANDOM % 5 + 3))
                break
            fi
        fi
    done
    
    if [ -n "$latest_ver" ]; then
        echo "Latest version for $group is $latest_ver"
        jq -n --arg grp "$group" --arg ver "$latest_ver" '{($grp): $ver}' >> fetched_app_versions.jsonl
    else
        echo "::error::Could not find latest version for $group"
    fi
    echo "::endgroup::"
done < check_list.txt

if [ -s fetched_app_versions.jsonl ]; then
    FETCHED_JSON=$(jq -s 'reduce .[] as $item ({}; . * $item)' fetched_app_versions.jsonl)
else
    FETCHED_JSON="{}"
fi

echo "$FETCHED_JSON" > fetched_app_versions.json

rm -f fetched_app_versions.jsonl check_list.txt
