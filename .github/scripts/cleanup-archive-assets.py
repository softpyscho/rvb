import os
import json
import re
import subprocess
import sys

def run_cmd(cmd):
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Error running command: {cmd}\n{result.stderr}")
        return None
    return result.stdout.strip()

GRAMMAR = re.compile(r'^(.*?)-((?:[vV]?[0-9]|[vV][A-Z]).*?)-(arm64-v8a|arm-v7a|universal|all|module|x86|x86_64)\.(apk|zip)$')
KEEP_GRAMMAR = 2   # newest versions kept per app + architecture
KEEP_OTHER = 1     # newest assets kept per app + architecture for names the grammar does not cover


def plan_prune(assets, manifest_files):
    """Which assets to keep and delete, as (kept, deleted) lists of (group, asset).

    Assets named by the grammar are grouped by `<app>-<arch>.<ext>` and the 2 newest kept. An
    asset the grammar does not recognise (a mirrored nightly that keeps its source's own name,
    "Duck.Detector-2026.10.11-78aabb41c513.apk") is grouped through the archive manifest by
    (app, arch) and only the newest is kept, by upload time: two such names that differ only by a
    hash say nothing about which is newer, so a client picking "the highest name" would take the
    older one. An asset the manifest does not know either is left alone."""
    groups = {}
    for asset in assets:
        name = asset['name']
        match = GRAMMAR.match(name)
        if match:
            groups.setdefault((f"{match.group(1)}-{match.group(3)}.{match.group(4)}", KEEP_GRAMMAR), []).append(asset)
            continue
        entry = (manifest_files or {}).get(name) or {}
        if entry.get('appKey') and entry.get('arch'):
            groups.setdefault((f"{entry['appKey']} ({entry['arch']}, own file names)", KEEP_OTHER), []).append(asset)
        else:
            print(f"Warning: Asset {name} does not match expected pattern, skipping.")
    kept, deleted = [], []
    for (key, keep_count), group_assets in groups.items():
        # newest first
        group_assets.sort(key=lambda x: x['created_at'], reverse=True)
        kept += [(key, a) for a in group_assets[:keep_count]]
        deleted += [(key, a) for a in group_assets[keep_count:]]
    return kept, deleted


def read_archive_manifest(tag):
    """`files` of state/archive/<tag>.json at the tip of main, or {} when it cannot be read (then
    only grammar-named assets are pruned - nothing is deleted on a guess)."""
    if run_cmd("git fetch -q origin main") is None:
        print("Warning: could not fetch main; assets with their own names are left alone.")
        return {}
    out = run_cmd(f"git show origin/main:state/archive/{tag}.json")
    if not out:
        print(f"Warning: no state/archive/{tag}.json on main; assets with their own names are left alone.")
        return {}
    try:
        return json.loads(out).get('files') or {}
    except Exception as e:
        print(f"Warning: state/archive/{tag}.json is not readable ({e}); assets with their own names are left alone.")
        return {}


def cleanup_release(tag):
    print(f"\n--- Fetching assets for release: {tag} ---")
    repo = os.environ.get("GITHUB_REPOSITORY")
    
    # Get the release ID first
    output = run_cmd(f"gh api repos/{repo}/releases/tags/{tag} --jq .id")
    if not output:
        return
    release_id = output.strip()
    
    # Fetch all assets with pagination to ensure we get all 600+ files
    output = run_cmd(f"gh api --paginate repos/{repo}/releases/{release_id}/assets")
    if not output:
        return
        
    try:
        assets = json.loads(output)
    except Exception as e:
        print(f"Failed to parse JSON: {e}")
        return
    
    kept, deleted = plan_prune(assets, read_archive_manifest(tag))
    by_group = {}
    for key, a in kept:
        by_group.setdefault(key, ([], []))[0].append(a)
    for key, a in deleted:
        by_group.setdefault(key, ([], []))[1].append(a)
    for key, (keeping, deleting) in by_group.items():
        if not deleting:
            continue
        print(f"\nGroup: {key}")
        for a in keeping:
            print(f"  Keeping: {a['name']} ({a['created_at']})")
        for a in deleting:
            print(f"  Deleting: {a['name']} ({a['created_at']})")
            cmd = f'gh api -X DELETE repos/{repo}/releases/assets/{a["id"]}'
            run_cmd(cmd)

if __name__ == "__main__":
    if not os.environ.get("GITHUB_REPOSITORY"):
        print("GITHUB_REPOSITORY environment variable not set.")
        sys.exit(1)
    cleanup_release("stable")
    cleanup_release("beta")
