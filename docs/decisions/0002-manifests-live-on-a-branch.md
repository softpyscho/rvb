# 0002 — Build manifests live on a branch, not on releases

**Status:** accepted (2026-09-25); the branch placement is superseded by [0008](0008-one-branch.md) —
the manifests now live under `state/` on `main`, the decision to keep them out of release assets stands
**Affects:** `website` branch, `.github/scripts/merge_archive_branch.sh`,
`build.yml` upload order, the site's `rebuild_catalog.py --manifest-dir`

## Context

Every build produces a `build.json`: what was built, at which version, for which
architecture, with which patches applied. It started life as a **release asset** —
uploaded onto each numbered release, plus two cumulative `build.json` assets on the
`stable`/`beta` archive releases. The cumulative pair had to be rebuilt every run,
and the rebuild was implemented as:

```
gh release download <archive> --name build.json   →   merge with this build   →   re-upload
```

On 2026-09-24 that shape destroyed the archive history. The download is a transient
network call; when it failed, the script fell back to "previous manifest is empty",
merged one build into nothing, and uploaded the result — a cumulative file that now
described only the latest build, overwriting the good one. Retries on the upload
made the loss permanent, because the corrupted file was now the source for the next
run. Nothing failed: the step exited 0.

The deeper problem was storage choice. Release assets are mutable, size-capped,
pruned by cleanup, and addressed by a network call. A manifest is exactly the
opposite of what those properties suit: it is small text, it is the audit record,
and it must not be silently replaceable.

## Decision

**The `website` branch is the sole manifest store** (commit `82c7d4bb`,
2026-09-25). Per-build manifests are no longer uploaded as release assets at all:

- `manifests/<tag>.json` — one file per numbered build, appended by every run.
- `archive/{stable,beta}.json` — the cumulative pair, merged from the checked-out
  file rather than a download.
- The site consumes the branch through `rebuild_catalog.py --manifest-dir`; the
  Releases API is used **only** for what only it knows: existence, size, download
  counts (see [../website-contract.md](../website-contract.md)).

Merging is now: `git fetch` → union old + new → live-filter against the archive
release's actual assets → **sanity gate** (`ENTRIES >= |union ∩ live|`, refuse to
push otherwise) → push with rebase-retry.

## Why this is the fix, not a workaround

- **A failed fetch cannot look like success.** `git fetch` returns non-zero and the
  job dies; there is no "start from empty" branch in the code, because an empty
  previous state is expressed by a *missing file on a branch we just checked out
  successfully* — a genuinely different condition.
- **History is free.** `git log -p archive/stable.json`, `git show <rev>:…`, and a
  force-push to undo. Recovering a lost manifest used to mean reconstructing it from
  surviving assets (`repair_archive_manifest.py` exists for exactly that).
- **No size or count pressure.** Assets compete with the APKs for quota and are
  pruned by the same cleanup that keeps the archive bounded.

## Rejected alternatives

- **Retry the asset download harder.** Still one transient failure away from an
  empty base, and the failure would remain silent whenever retries ran out.
- **Keep both stores (branch + release asset).** Two sources of truth for one
  record, and the site would eventually read whichever of them was stale.
- **Store manifests in the website repo directly.** That inverts the dependency:
  rvb would need write access to another repository, and the metadata's lifetime is
  tied to a build run, not to a deployed page.
- **A database / external service.** Rejected for the same reason the branch won:
  git history, review and offline cloning come for free, and there is no
  availability to maintain.

## Consequences

- A build's metadata publish is a **git push to another branch**, so it needs its
  own failure handling (`[skip ci]` commit messages, rebase-retry, `build`
  concurrency group to keep two builders from merging simultaneously).
- `cleanup_website_branch.sh` must delete `manifests/<tag>.json` when a numbered
  release is deleted, or the branch accumulates references to gone artifacts. Archive
  entries drop out on their own at the next merge, via the live filter.
- Docs and tooling that assumed "download `build.json` from a release" are wrong:
  `seed_website_branch.py` remains only as a legacy-window recovery tool.
- The website's rebuild can no longer silently shrink either — its `MIN_RATIO`
  circuit breaker is the second half of the same lesson.

## Verification

`temp/test_merge_archive_branch.sh` (stubbed `gh`, local bare `origin`) covers the
merge, the live filter and the sanity gate. In CI the archive *upload* step is
`continue-on-error`, but the merge step that follows it is not — its fetch failure
is fatal by design. The catalogue side is verified with `rebuild-catalog.yml` in
`dry_run` mode.
