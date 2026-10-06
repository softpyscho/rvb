# `state/` and `configs/`

Everything the builder reads or writes besides code. One branch (`main`) holds it all; CI commits
its own files with `.github/scripts/commit_to_main.sh` (message ends `[skip ci]`).

| Path | Written by | Notes |
|---|---|---|
| `configs/patches/*.toml` | you | one file per patch source; the real app list |
| `configs/config.manual.toml` | you | what Manual CI builds |
| `configs/{stable,beta}_build.json` | the watcher | generated pool configs, never edit |
| `state/*.json` | the watcher | patch-source tags, app versions, bundle hashes, never edit |
| `state/manifests/<tag>.json` | each build | one manifest per numbered release; pruned with the release |
| `state/archive/{stable,beta}.json` | each build | cumulative manifests of the rolling archive releases |

Keys: [CONFIG.md](../CONFIG.md). Layout and formats: [docs/storage-and-branches.md](../docs/storage-and-branches.md).
