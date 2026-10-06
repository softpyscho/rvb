# 0003 — A blocked patch source is skipped, never re-queried

**Status:** accepted (2026-09-26)
**Affects:** `.github/scripts/sync_patch_sources.py`, `scripts/utils.sh`
(`_patch_source_state_blocked`, `_get_prebuilts`), `state/patch_sources.json`,
the watcher's `TRIGGER_BLOCKED` flag

## Context

Patch sources live on other people's repositories. Those repositories disappear:
renamed, deleted, taken down for legal reasons, or switched to private. When they
do, `state/patch_sources.json` records the source as `blocked` and freezes the last
tags it knew.

The bug was what happened next. A blocked source looked like a plain lookup miss, so
the build fell through to the **live release listing** — one request per
architecture, per app, per run, against a repository whose answer cannot change
mid-run. Every app on a gone repository burned requests and time for a result that
was already known, and a large part of a run could be spent proving the same
dead end.

## Decision

**A blocked source is refused before any version handling** (commit `53810f87`).
`_get_prebuilts` consults the snapshot, and if the source is blocked it fails
immediately; `build.sh` already treats a failed `get_prebuilts` as "log it and move
to the next app", so the app is skipped with a reason and the run continues. The
check happens *before* version resolution, so an app with a pinned
`patches-version` on a gone repository is skipped too rather than attempting the tag
download.

`blocked` is set from forge answers only: `404` (deleted or renamed), `451` (legal
takedown), `403` (private or access refused). It is not a timeout, not a rate limit,
not a parse failure — those are retried, because they can recover.

## The deliberate asymmetry

The predicate answers **"not blocked"** when the snapshot is missing, the source is
unknown, or the `jq` read fails. That is a fail-open default, the opposite of the
fail-loud rule that governs branch reads and manifest merges — and it is on purpose:

| Direction of failure | What it would cost |
|---|---|
| Fail *closed* on a malformed snapshot | every app in every pool silently skipped → a run that "succeeds" while publishing nothing |
| Fail *open* on a malformed snapshot | the wasted HTTP request we were trying to avoid, once, per app |

Skipping an app is silent from CI's point of view; a dead repository is loud in the
log. Where a wrong answer is silent, the safe direction is the one that keeps doing
work. The blocking rule is: **never let an unreadable input decide to stop
building.**

## Rejected alternatives

- **Retry the live listing with backoff.** The 404/451/403 class is terminal for the
  run; no retry policy recovers a repository that is gone.
- **Drop the app from the config automatically.** The source may come back (renames
  often redirect, DMCA takedowns get re-uploaded elsewhere); deleting human config on
  a transient signal destroys intent that only a human can restore.
- **Keep the listing but cache the miss in-process.** Saves requests within a run and
  still re-pays the whole cost on the next run; the snapshot already exists and is
  the single source of truth for source state.

## Consequences

- A blocked source is **self-healing**: once the forge answers again, the watcher
  clears the flag and the app returns to the pool with no human involvement. Until
  then nothing in a build log will mention it except the skip line — so "why is my
  app missing" is answered by `state/patch_sources.json`, not by a build run.
- Blocking is itself a trigger (`TRIGGER_BLOCKED`), so the pool configs regenerate and
  membership is recomputed rather than continuing to offer an app that cannot build.
- `_patch_source_state_blocked` must stay cheap and total — it runs per app, and any
  error path in it must land on "not blocked".
- Users see the effect as "Could not get prebuilts" in the log; the reason names the
  blocked source, which is what a bug report needs to be routed to the patch author
  rather than to this builder.

## Verification

The trace harness exercises the skip with a snapshot in reach (blocked keyword and
pinned-version variants); `state/patch_sources.json` is the
fixture that mirrors reality. See `.github/traces/README.md`.
