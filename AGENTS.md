# Agent instructions

Working in `nullcpy/rvb`. Read [docs/ai-context.md](docs/ai-context.md) before
making a change — it is the full brief. The rules below are the ones that cause
damage when broken.

1. **`main` is the only long-lived branch.** It holds the code, your config
   (`configs/`) and what the pipeline records (`state/`: watcher JSONs, build
   manifests). `temp/`, `build/`, `build.json`, `build.md` are scratch and gitignored —
   never commit them, never `git add -A` blindly. CI writes to `main` only through
   `.github/scripts/commit_to_main.sh`, naming each file (the generated JSONs, the build
   manifests, the README apps section between `APPS_START`/`APPS_END`); commits end `[skip ci]`.
2. **`git pull` before you edit `configs/` or `state/`.** CI commits to `main` between your
   edits; hand-edit only `configs/**.toml` — the `*.json` there and everything under `state/`
   is machine-written and never edited by hand.
3. **A field nobody named is not yours to write.** A default that asserts a value
   (`${X:-false}`, `-n ""`, an invented title) is a bug here, not a convenience.
   Reject an unrecognised value loudly instead of guessing
   ([docs/decisions/0001](docs/decisions/0001-release-metadata-ownership.md)).
4. **Wire formats are frozen:** asset filename grammar, `module.prop` `updateJson`
   paths on the `update` branch, manifest schema keys, `data.json` keys, the
   `update` branch name. Add a key or bump a version; never reinterpret an existing one.
5. **`.github/scripts/naming.py` is the only implementation of filename/architecture
   parsing.** The website's `rebuild_catalog.py` imports it through a sparse clone of
   `main` (`RVB_NAMING_DIR`) — do not add a copy there, and do not move the file's
   path without updating that clone step. Keep the module stdlib-only.
   ([docs/decisions/0006](docs/decisions/0006-filename-parsing-is-imported-not-mirrored.md))
6. **Shell:** `set -euo pipefail`; a `[ … ] && var=x` chain whose last command may
   not run will abort a step before `$GITHUB_OUTPUT` is written — use `if` blocks;
   never call a cache-writing function from inside `$( )`; patch-name quoting
   happens only in `join_args`.
7. **Fail loud** on reads from `main`, manifest merges and archive sanity (no "start
   from empty" fallbacks). **Fail soft** per app, per notification. Adding `|| true`
   to a metadata path is a regression.
8. **Verify before claiming done:**
   `bash .github/traces/trace_runner.sh verify` for anything touching
   `scripts/build.sh` / `scripts/utils.sh`; a stubbed-binary harness in `temp/` for
   CI scripts (absence assertions need a negative control).
9. **Commits:** Conventional Commits, one logical step per commit, body explains
   *why*. Do not push, merge, release, or open a PR unless asked — a push to `main`
   changes the next scheduled run.
10. `.gitattributes` mandates LF for `.sh .py .yml .json .toml .trace`; CRLF in a
    script breaks execution and trace goldens.

When a change alters behaviour that a document owns, update it in the same commit:
engine stages → [docs/build-engine.md](docs/build-engine.md); workflow order or
gating → [docs/ci-pipelines.md](docs/ci-pipelines.md); branches, releases and file
names → [docs/storage-and-branches.md](docs/storage-and-branches.md); anything the
website reads → [docs/website-contract.md](docs/website-contract.md); TOML keys →
[CONFIG.md](CONFIG.md).
