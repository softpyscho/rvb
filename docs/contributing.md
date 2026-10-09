# Contributing

Two very different contributions live here. Pick yours first — most of the value
in this project comes from the first one, and it needs no code.

| I want to… | Touch | How |
|---|---|---|
| add an app, enable/disable a patch, change a variant or channel | a TOML under `configs/patches/` | [below](#changing-app-configurations-the-common-case) |
| fix a build failure, scraper, uploader, workflow | `main` | [below](#changing-code) |
| report something | nothing | [issue templates](../.github/ISSUE_TEMPLATE) (yes, website issues are filed here too), or the Telegram group |
| patch a patch problem | nothing here | the patch author's repository — this builder only assembles what they publish |

## Changing app configurations (the common case)

Config lives in `configs/patches/*.toml` on `main`, one file per
patch-source family, with file-level defaults above the first `[table]`.
Every key is documented in [CONFIG.md](../CONFIG.md); read that rather than
copying a neighbour's guess. The rules that people get wrong:

- **Channel is routing, not versioning.** `patches-version` is `stable`, `beta` or
  `both` (or a concrete tag to pin). Omitted means "inherit the file default", and
  the file default is `stable` unless the filename carries `.beta.`. `both` opts an
  app into both pools — an app with no explicit setting does **not** get both.
- **A mistyped channel is treated as a tag**, so `patchs-version = "stble"` fails
  loudly on the release lookup instead of quietly landing in the wrong pool.
- **Patch names in include/exclude lists must be quoted** — the parser splits on
  quoted tokens, and `build.sh` rejects an unquoted list.
- **`inclusive-patches` and `exclusive-patches` are opposites**; setting both is a
  hard error.
- `enabled = false` disables an app in every pool. Deleting a config block instead
  leaves the generated pool entry until the watcher regenerates, and a *renamed*
  file is a plain `git rm` — CI never deletes your TOMLs.

### Publish it

```bash
git pull                                             # CI commits generated JSON to main between your edits
# edit configs/patches/<family>.toml
git commit -am "feat(config): add Pinterest builds" && git push
```

Hand-edit only the TOMLs: the `*.json` under `configs/` and everything under `state/` is
written by CI. Regenerate the README/Obtainium documents after adding or removing an app:
`python3 .github/scripts/obtainium.py --repo <owner>/<repo> --page OBTAINIUM.md --json obtainium-apps.json --readme README.md`
(`test_release_notes.py` fails while they are stale).

Your change takes effect on the next watcher run (every 4 hours): the pool configs
are regenerated from your TOML and the affected app gets built. To verify
immediately instead of waiting, run **Manual CI** (`workflow_dispatch`): `all` builds every app
(stable pool, then beta pool), or pick `configs/config.manual.toml` — a hand-built config that never
touches the pools. **Build** (`build.yml`) can also be dispatched directly with the same choices;
Manual CI adds the cleanup and failure notification around it.

## Changing code

### Local setup

```bash
git clone <this repo> && cd rvb
git pull    # configs/ and state/ are tracked on main
```

Requirements: bash 4+ (the project's tests are written against bash 5.x under Git
Bash on Windows), GNU `sed`, `jq`, `python3` (3.11+ for `tomllib`), `zip`,
Java 21 for real builds, and `dos2unix` where CI normalises `utils.sh`.
Line endings are enforced by [.gitattributes](../.gitattributes): scripts, JSON,
YAML and TOML are LF everywhere. If your editor writes CRLF into a `.sh`, the
trace goldens will fail on byte comparison.

Run a build locally to see the engine work end to end:

```bash
bash scripts/build.sh configs/config.manual.toml
```

Expect it to need real network access to the stores. Module auto-update is
disabled locally by design (there is no published `update` branch for a local run
to point at), and output lands in `build/` with `build.json` + `build.md`
describing it. `bash scripts/build.sh clean` resets.

### Test what you changed

| Layer | Command | Notes |
|---|---|---|
| Patcher/tool decisions in the engine | `bash .github/traces/trace_runner.sh verify` | offline; stubbed `curl`/`java` + fixtures; runs on push to `build.sh`/`utils.sh`. After an *intentional* argv change: `… capture`, read the diff, commit the goldens |
| Cache / bundle helpers | `bash .github/traces/test_cache_helpers.sh`, `bash .github/traces/test_bundle_helpers.sh` | same job |
| Mirrored apps (`mirror_rv`, `mirror`/`keep-filename` parsing) | `bash .github/traces/test_mirror.sh` | same job; fake downloads and a stub `aapt2`, every rejection paired with an accepting control |
| What a build records about itself (stock-APK source, recommended version, skipped / failed / excluded patches) and how it reaches the manifest | `bash .github/traces/test_build_record.sh` | same job; the real `write_build_info` over a Morphe-shaped log and result file |
| Which configs a build run covers (`all` → both pools, empty pool left out, typo rejected) | `bash .github/traces/test_build_plan.sh` | same job; offline, jq only |
| CI's writer to `main` (`commit_to_main.sh`); manifest merge and prune | `bash .github/traces/test_commit_to_main.sh`, `bash .github/traces/test_manifest_scripts.sh` | same job; local bare origin, stub `gh`; includes a human push landing mid-run and loud failures |
| How a `github` source reports versions (tag vs release-per-package asset names) | `bash .github/traces/test_github_versions.sh` | same job |
| The CI refresh of the README app table (`update_readme.sh`) | `bash .github/traces/test_update_readme.sh` | same job; local bare origin whose `main` carries the config and `state/archive/` |
| Cleanup of the `update` branch (absent branch, dead pointers) | `bash .github/traces/test_cleanup_update_branch.sh` | same job; local bare origin and a stub `gh` |
| Which apps the watcher version-checks, BKS need | `bash .github/traces/test_ci_app_versions.sh` | same job; offline, a stub `utils.sh` and compiled-pool fixtures |
| Release notes, Obtainium links, manifest of mirrored files, app config | `python3 .github/traces/test_release_notes.py` | same job; also fails when `README.md` / `OBTAINIUM.md` / `obtainium-apps.json` are stale against `configs/patches` (regenerate with `.github/scripts/obtainium.py`) |
| A CI shell script | a stubbed-binary harness under `temp/` | convention below |
| Website-facing formats | `rebuild-catalog.yml` with `dry_run: true` | see [website-contract.md](website-contract.md) |

The `temp/` harness convention, because it is how most bugs in this repo got
pinned down: `temp/` is gitignored, so a harness there is a *maintainer's* test,
not a CI gate. The pattern that works is a stub directory first on `PATH`
(`stub/gh`, `stub/curl`) that appends every invocation to a log, then assertions
about which flags actually reached the tool. Two lessons baked into the habit:

- **Guard against escaping the sandbox.** Resolve the repo root with `cygpath` and
  refuse to run if it is not the expected checkout, before any `rm`/`git` in the
  script touches disk. MSYS2 also rewrites arguments that look like paths unless
  `MSYS2_ARG_CONV_EXCL` is set.
- **An absence check needs a negative control.** Asserting "the flag was not
  passed" proves nothing if the same harness cannot also show the flag *being*
  passed. Keep the `true`/`false` cases next to the "unset" case.

### Shell rules this codebase follows

- `set -euo pipefail` at the top of every script.
- The engine assembles patcher argv as strings that are later evaluated, which is
  why quoting must happen in exactly one place — `join_args` in `utils.sh` for
  `-e`/`-d` patch lists. Never add a second quoting site or a hand-built `eval`:
  patch names contain apostrophes and that is a known failure class, not a
  hypothetical.
- A `[ … ] && var=value` short-circuit list is fine as a statement, but a chain
  whose *final* command may not run will abort the step under `set -e` before
  outputs are written. Write `if` blocks when the thing after it is `$GITHUB_OUTPUT`.
- Reset `local` variables in functions that are called repeatedly with
  `local var=${1:-}`-style initialisers rather than relying on the previous value
  being gone.
- Command substitution swallows side effects: anything that mutates a shared cache
  or global must be called directly.

### Commits

- [Conventional Commits](https://www.conventionalcommits.org/): `fix(ci): …`,
  `refactor(build): …`, `feat(config): …`, `perf(build): …`, `docs: …`,
  `test: …`, `chore: …`. Scope is the subsystem, not the file.
- **One logical step per commit.** A fix and the test that pins it belong
  together; adjacent cleanups do not.
- Multi-line messages go through a file (`git commit -F temp/_commit_msg.txt`) so
  the shell cannot mangle quoting; the body explains *why*, since the diff already
  shows *what*.
- Never `git add -A` blindly. `temp/`, `build/`, `build.json`, `build.md` and the
  watcher's working files are gitignored; `configs/` and `state/` are tracked, but only the
  TOMLs are yours to edit — the JSON there is CI's, and committing a stale local copy of it
  would overwrite the watcher's state.
- Do not merge or push on someone's behalf without being asked; a push to `main`
  changes the next scheduled run, and nothing runs on push except Trace Verify.

### Pull request checklist

1. `bash .github/traces/trace_runner.sh verify` passes (if you touched the engine).
2. Any new/changed wire format is reflected in
   [storage-and-branches.md](storage-and-branches.md) and, if it crosses the seam,
   in [website-contract.md](website-contract.md). Filename-parsing rules belong in
   `.github/scripts/naming.py` only — the site imports it, so never add a copy.
3. Behaviour docs updated where the behaviour is documented
   ([ci-pipelines.md](ci-pipelines.md) for steps/ordering,
   [build-engine.md](build-engine.md) for engine stages).
4. A load-bearing decision that someone might undo got a numbered file in
   [decisions/](decisions/) and a pointer to it from the code.
5. No `configs/`, `state/`, `temp/` or generated artifacts in the diff.

## Reading the running system

```bash
gh run list --repo nullcpy/rvb                     # recent CI / Build / Cleanup runs
gh run view <id> --log-failed                      # the failing step, filtered
gh api repos/nullcpy/rvb/releases/tags/stable -q '.assets[].name'   # what is downloadable now
jq '.files | length' state/archive/stable.json
```

`state/` (including the build manifests), the pool configs and the `update` branch are all readable
without any privileged access, which is what makes a bug report actionable.
