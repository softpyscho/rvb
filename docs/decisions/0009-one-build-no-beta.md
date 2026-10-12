# 0009 — One build: no beta channel, one config, one pool

**Status:** accepted (2026-10-12) — supersedes the stable/beta pool routing described in the earlier
notes ([0001](0001-release-metadata-ownership.md) and [0002](0002-manifests-live-on-a-branch.md) still
describe their own history).
**Affects:** `configs/config.toml`, `compile_patch_configs.py`, `sync_patch_sources.py`,
`derive_source_changes.py`, `ci_generate_configs.sh`, `ci_resolve_triggers.sh`, `ci_trigger_flags.sh`,
`build_prepare_config.sh`, `build_resolve_context.sh`, `scripts/build.sh`, `ci.yml`, `build.yml`,
`manual-ci.yml`

## Context

The pipeline carried two builds side by side: a stable pool and a beta pool, each with its own generated
config, trigger, release channel, archive release, archive manifest and `-beta` module id. In practice
the beta pool held one app (Instagram), and only because Piko's stable release had once lagged behind its
`dev` line; Piko's stable v3.10.0 supports the same Instagram build with the same patches. Everything else
the beta pool did - a date gate, a second build job, a second archive - existed to serve that one app.

## Decision

There is one build.

- `patches-version` is `stable` (the default) or a pinned release tag. `beta` and `both` are **rejected
  loudly**, in `compile_patch_configs.py` and in `build.sh`, never read as a tag or guessed at.
- One compiled config (`config.json`), one watcher-generated config (`configs/build.json`), one trigger
  (`TRIGGER_PATCHES`, plus `TRIGGER_APP_UPDATE` and `TRIGGER_BLOCKED`), one `build` job. The dispatch
  choices are `all` and `manual`.
- `state/patch_sources.json` records only each source's latest stable release.
- Instagram moved to the stable patches.

### What was kept, because it is a wire format

- The archive release is still tagged **`stable`**. Obtainium entries already installed point at
  `releases/expanded_assets/stable`, and renaming the tag would orphan them.
- `update_json_path()` still understands a `-beta` module id and the `beta/` pointer folder, so a module
  installed from the old beta channel keeps updating from the pointer it was given. Nothing writes new ones.
- The manifest keeps its `meta.channel` key; its value is always `stable`.
- `TG_THREAD_STABLE` remains the repository variable for the build's Telegram thread.
- `cleanup-archive-assets.py` and `cleanup_update_branch.sh` still look at a `beta` release if one exists,
  so its files age out instead of lingering. `state/archive/beta.json` is left as it was; nothing merges
  into it and the README no longer reads it.

## Consequences

- An Instagram install from the old beta archive does not receive updates: its Obtainium entry reads the
  `beta` page, which no longer gains files. It has to be re-added from the README (the `stable` page).
- A pre-release patch bundle can still be used by pinning its tag on one app; nothing tracks it for you.
- The watcher can no longer be told "only the beta pool"; there is nothing to tell it.

## Rejected alternatives

- **Keep the code, leave the pool empty.** Two pools of which one is always empty keeps every branch
  of the beta code alive and tested for nothing.
- **Rename the `stable` archive tag to something neutral.** Cleaner, but it breaks every installed
  Obtainium entry for no functional gain.
