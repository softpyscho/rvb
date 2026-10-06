# Agent instructions

Working in `nullcpy/rvb`. Read [docs/ai-context.md](docs/ai-context.md) before
making a change — it is the full brief. The rules below are the ones that cause
damage when broken.

1. **`main` is pure code.** `configs/` and `state/` are gitignored materialisations
   of the `data` branch; `temp/`, `build/`, `build.json`, `build.md` are scratch.
   Never `git add -A`, never commit those paths. (CI's only write to `main` is the
   README apps section, between its `APPS_START`/`APPS_END` markers.)
2. **Human config is published, not committed:**
   `bash .github/scripts/push_data_configs.sh "<msg>"`. `fetch_data_branch.sh`
   **overwrites** local `configs/` — publish before fetching or lose edits.
3. **A field nobody named is not yours to write.** A default that asserts a value
   (`${X:-false}`, `-n ""`, an invented title) is a bug here, not a convenience.
   Reject an unrecognised value loudly instead of guessing
   ([docs/decisions/0001](docs/decisions/0001-release-metadata-ownership.md)).
4. **Wire formats are frozen:** asset filename grammar, `module.prop` `updateJson`
   paths on the `update` branch, manifest schema keys, `data.json` keys, branch
   names. Add a key or bump a version; never reinterpret an existing one.
5. **`.github/scripts/naming.py` is the only implementation of filename/architecture
   parsing.** The website's `rebuild_catalog.py` imports it through a sparse clone of
   `main` (`RVB_NAMING_DIR`) — do not add a copy there, and do not move the file's
   path without updating that clone step. Keep the module stdlib-only.
   ([docs/decisions/0006](docs/decisions/0006-filename-parsing-is-imported-not-mirrored.md))
6. **Shell:** `set -euo pipefail`; a `[ … ] && var=x` chain whose last command may
   not run will abort a step before `$GITHUB_OUTPUT` is written — use `if` blocks;
   never call a cache-writing function from inside `$( )`; patch-name quoting
   happens only in `join_args`.
7. **Fail loud** on branch reads, manifest merges and archive sanity (no "start
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
