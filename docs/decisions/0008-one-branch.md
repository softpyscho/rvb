# 0008 — One branch: config, state and manifests live on `main`

**Status:** accepted (2026-10-06) — supersedes the *placement* in
[0002](0002-manifests-live-on-a-branch.md) and the "`main` is pure code" rule; the reasons 0002 gave
for leaving **release assets** still stand.
**Affects:** `configs/`, `state/`, `.github/scripts/commit_to_main.sh`,
`merge_archive_manifest.sh`, `cleanup_manifests.sh`, `update_readme.sh`, `build.yml`, `ci.yml`,
`cleanup.yml`

## Context

The upstream layout kept machine-written files off `main`: `data` held the config and the
watcher's state, `website` held the build manifests. The point was a human-only history on `main`
and a catalogue site (a separate repository) that could clone just the manifests.

A single-maintainer fork has neither need, and paid for the layout every day: three branches to
keep in step, a materialise step in every job, `fetch_data_branch.sh` that **overwrote** local
edits, a separate publisher for hand-edited TOMLs, and a bootstrap script before the first run.

## Decision

`configs/` and `state/` are ordinary tracked directories on `main`. Manifests are
`state/manifests/<tag>.json` and `state/archive/{stable,beta}.json`. Everything CI stores goes
through one script, `commit_to_main.sh`, which commits **named files only** onto `origin/main`'s
tip with a temporary index (no checkout switch, no dirty-tree hazard) and a `[skip ci]` message.
You edit TOMLs and commit them like code. The `update` branch stays as documented — it is the
module-pointer wire format and is only ever created when a module zip is built.

## Rejected alternatives

- **Keep `data`/`website`, publish with the old scripts.** Works, but is the cost described above.
- **One extra `data` branch holding both.** Halves the branches, keeps the materialise/overwrite
  hazard and the second publisher.
- **`git add -A` from CI on a checked-out `main`.** Sweeps in whatever the job left behind and
  races human pushes; the named-file plumbing commit cannot do either.

## Consequences

- `main`'s history now contains bot commits (`chore: update …`, `docs: refresh …`). Filter them with
  `git log --invert-grep --grep='\[skip ci\]'` or `--author`.
- Edit `configs/` after a `git pull`; CI may have committed generated JSON since your last one.
- A download site (like upstream's) that wants the manifests reads `state/` on `main` instead of
  the `website` branch — see [website-contract.md](../website-contract.md). This fork has none.
- Recovery of a damaged manifest or state file is `git log -p` / `git show <rev>:<path>`.

## Verification

`bash .github/traces/test_commit_to_main.sh` (add/update/remove, named-files-only, race with a
human push, loud failure), `test_manifest_scripts.sh` (merge, live filter, prune, fail-loud),
`test_update_readme.sh`.
