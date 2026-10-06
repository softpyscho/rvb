# `data` branch

Machine- and human-edited configuration for the builder. `main` is pure code; this
branch is materialised into `configs/` and `state/` by `.github/scripts/fetch_data_branch.sh`.

| Path | Written by | Notes |
|---|---|---|
| `configs/patches/*.toml` | you, via `.github/scripts/push_data_configs.sh` | one file per patch source; the real app list |
| `configs/config.manual.toml` | you | what Manual CI builds |
| `configs/{stable,beta}_build.json` | the watcher | generated pool configs, never edit |
| `state/*.json` | the watcher | patch-source tags, app versions, bundle hashes, never edit |

Reference for every key: `CONFIG.md` on `main`.
