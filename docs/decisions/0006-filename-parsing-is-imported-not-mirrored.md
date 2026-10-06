# 0006 — Filename parsing is imported across the repo boundary, never mirrored

**Status:** accepted (2026-09-29)
**Affects:** `nullcpy.github.io/.github/scripts/rebuild_catalog.py`,
`.github/workflows/rebuild-catalog.yml`, `.github/scripts/naming.py`

## Context

The rules that turn an asset filename into an app key, a display prefix and a
normalised architecture live in [.github/scripts/naming.py](../../.github/scripts/naming.py).
The builder applies them when it writes a manifest; the website applies them when it
groups app cards. Until now the website applied a **hand-copied mirror** of four of
them, justified by a comment claiming the module "must stay dependency-free", and the
two copies were held together by a rule nobody could enforce:

> Change one, change the other, in the same series of commits.

That is not a design, it is an apology. Divergence would have been silent — an app
grouping under the wrong architecture, or splitting into two variant cards — and the
manifest architecture exists precisely to eliminate silent-parse-disagreement as a
failure class.

The clone the rebuild job already performs made the duplication unnecessary: the
website fetches rvb's manifests to read them (from `state/` on `main`; formerly the `website` branch), so rvb's code is one small
checkout away.

## Decision

**`rebuild_catalog.py` imports rvb's `naming.py` and holds no local copy of any of
its rules.**

- `rebuild-catalog.yml` adds a blob-filtered, sparse clone of rvb's `main`
  (`--filter=blob:none --no-checkout` + `sparse-checkout set .github/scripts`),
  which fetches the script directory rather than the repository, and passes its path
  as `RVB_NAMING_DIR`.
- Resolution order is `RVB_NAMING_DIR`, then a `rvb` checkout beside the site repo
  (the local-development layout). If neither yields the file, the script exits with a
  `FATAL:` naming both paths it tried.
- The functions are bound at module level (`normalize_key`, `normalize_arch`,
  `extract_arch`, `file_prefix`), so the ~60 lines of mirrored logic and the
  "change both copies" comment are gone; `fallback_entry` now calls `file_prefix()`
  instead of re-implementing it, and the site's `import re` disappeared with them.
- `naming.py` remains stdlib-only (`import re`), so importing it across the boundary
  adds no dependency to the site — the "dependency-free" constraint was about third
  -party packages, never about a file in a repo the job already clones.

## Rejected alternatives

- **Keep the mirror and add a CI parity test.** Testable duplication is still
  duplication: the test would need both repositories present, and a green run would
  only mean "these two copies agree *today*". Importing removes the question.
- **Publish `naming.py` onto the `website` branch** so the existing clone carries it.
  Rejected as a quieter version of the same bug — that copy refreshes only when a
  build runs, so a change on `main` with no intervening build leaves the site parsing
  with a stale file, and the staleness is invisible by construction.
- **A fallback mirror inside `rebuild_catalog.py` ("import, else use local copy").**
  The worst option: it keeps CI green while silently parsing with the stale rules,
  which is precisely the failure being removed. Absence must be loud.
- **A published package (PyPI/git dependency).** Version pinning across two repos for
  85 lines of stdlib code buys release ceremony and a publish step, and a fork would
  resolve against the published package rather than its own `naming.py`.

## Consequences

- The site's catalogue rebuild now **depends on rvb's `main` being reachable** and on
  `.github/scripts/naming.py` staying at that path. Both are acceptable: the rebuild
  already depends on rvb's branches and releases API, and a rename produces a hard,
  immediate failure instead of a slow semantic drift.
- The dependency runs one way — the site reads rvb's code; rvb never reads the site's.
  Nothing in rvb may import from the site repository.
- Local runs of `rebuild_catalog.py` need either `RVB_NAMING_DIR` or a `rvb` checkout
  beside the site clone (the layout used by the repair tooling already).
- Changing a parsing rule in `naming.py` now changes website grouping on the *next
  rebuild*, with no second edit to remember. That is the point, and it is why a
  behaviour change there deserves a `dry_run` rebuild before merge.
- The coupling is stated in code at the import site, so the "change both copies"
  instruction no longer exists anywhere — including in the docs.

## Verification

Recorded on 2026-09-29 before the change was merged:

1. **Function parity** — a differential harness fed 490 filenames (every asset name
   on `stable`, `beta` and `260141`, plus hand-written edge cases: `armeabi-v7a`,
   `x64`, `arm32`, module zips, names with spaces, names with no architecture token)
   to both implementations: **0 mismatches**.
2. **End-to-end parity** — a full rebuild against the live API produced a catalogue
   **identical** to the committed `data.json` (which the mirrored code generated)
   once counters (`downloadCount`, `size`, `totalDownloads`, …) are scrubbed — for
   both the env-var and sibling-clone resolution paths.
3. **Loud failure path** — run from a location where neither `RVB_NAMING_DIR` nor a
   sibling `rvb` exists: non-zero exit, `FATAL: rvb's naming.py was not found`, and
   no output file written.
