# `state/` and `configs/`

Everything the builder reads or writes besides code. One branch (`main`) holds it all; CI commits
its own files with `.github/scripts/commit_to_main.sh` (message ends `[skip ci]`).

| Path | Written by | Notes |
|---|---|---|
| `configs/config.toml` | you | the real app list: every app, every patch source and channel |
| `configs/config.manual.toml` | you | what Manual CI builds |
| `configs/build.json` | the watcher | the generated build config, never edit |
| `state/*.json` | the watcher | patch-source tags, app versions, bundle hashes, never edit |
| `state/manifests/<tag>.json` | each build | one manifest per numbered release; pruned with the release |
| `state/archive/stable.json` | each build | cumulative manifest of the rolling archive release |

Keys: [CONFIG.md](../CONFIG.md). Layout and formats: [docs/storage-and-branches.md](../docs/storage-and-branches.md).
