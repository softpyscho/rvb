# Decision records

Short, append-only notes answering a question the code cannot answer: *why is it
this way, and what did we try instead?*

Write one when a future reader (human or agent) could plausibly "fix" the thing
back. The code comment that guards the rule should link here, and the file should
name the verification that keeps the rule true.

## Format

```markdown
# NNNN — <title in present tense>

**Status:** accepted (YYYY-MM-DD) | superseded by NNNN | deprecated
**Affects:** <paths, branches, wire formats, external state>

## Context        what the situation was, and what broke or nearly broke
## Decision       the rule, stated so it can be checked
## Rejected alternatives   each one, with the reason — this is the section that
                          stops the same idea being re-implemented in six months
## Consequences    what is now someone else's problem, and how to recover it
## Verification    the test or command that keeps the decision true
```

Number files monotonically, never renumber or delete one; supersede instead. Keep
each under ~100 lines — if it needs more, it is two decisions or an architecture
document.

## Index

| # | Decision | Affects |
|---|---|---|
| [0001](0001-release-metadata-ownership.md) | Release metadata is owned by whoever names it | release uploads, archive releases |
| [0002](0002-manifests-live-on-a-branch.md) | Build manifests live on a branch, not on releases | manifest store (now `state/` on `main`, see 0008), archive merge, catalogue rebuild |
| [0003](0003-blocked-patch-sources-are-skipped.md) | A blocked patch source is skipped, never re-queried | watcher state, `get_prebuilts` |
| [0004](0004-no-download-prewarm-pass.md) | No download prewarm pass; fetching stays inside each build | build pool, download flock, `RVB_DL_MAX_TIME` |
| [0005](0005-tuning-knobs-live-in-the-workflow.md) | Build tuning knobs live in the workflow's env block | `PARALLEL_JOBS`, `UPLOAD_CONCURRENCY`, no config keys |
| [0006](0006-filename-parsing-is-imported-not-mirrored.md) | Filename parsing is imported across the repo boundary, never mirrored | `naming.py`, the site's catalogue rebuild |
| [0007](0007-requested-arch-is-a-hard-requirement.md) | A requested build arch is a hard requirement; no mislabeled artifacts | `build_rv` download gate, download-link index, published arch names |
| [0008](0008-one-branch.md) | One branch: config, state and manifests live on `main` | `configs/`, `state/`, `commit_to_main.sh` |

Candidates still unwritten, because the reasoning currently lives only in commit
messages: pinning a patch source's `patches-version` to a tag vs resolving the
keyword from the state snapshot (2fced014), the universal-bundle strategy on
APKMirror (20eb4e5a), and why the archive release is the download target for module
update pointers rather than the numbered release.
