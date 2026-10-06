# 0005 — Build tuning knobs live in the workflow's env block

**Status:** accepted (2026-09)
**Affects:** `.github/workflows/build.yml` (job `env`), `scripts/build.sh`,
`.github/scripts/build_upload_release.sh`, `scripts/utils.sh` (`_req`)

## Context

Concurrency and transfer limits need changing often — a runner shape changes, an
upload queue grows, a store starts throttling. Where those numbers live is a real
design choice, because this repository has tried at least three places: a config key,
repository variables, and an `"auto"` sentinel that computes a value at runtime.

## Decision

**Every tuning knob is a job-level `env` entry in
[build.yml](../../.github/workflows/build.yml)**, and nowhere else. As of writing:

| Knob | Value | Read by | Effect |
|---|---|---|---|
| `PARALLEL_JOBS` | `1` | `scripts/build.sh` | concurrent table builds; `1` = the historical sequential path; non-numeric warns and falls back to `1`; capped at `8` because the runner is 4-core/16 GB |
| `UPLOAD_CONCURRENCY` | `12` | `build_upload_release.sh` | simultaneous asset uploads (script default `4` when unset) |

`PARALLEL_JOBS` is `1` in this fork (upstream ships `6`): a config that arrives with a
`parallel-jobs = 1` line is carried over by editing this value, not by adding the key back.

There is deliberately **no download-concurrency knob**: stock downloads happen
inside each table build and are throttled only by the per `pkg+version` flock
([0004](0004-no-download-prewarm-pass.md)). The only other tuning point is
`RVB_DL_MAX_TIME` — a curl transfer ceiling read in `utils.sh` `_req`, defaulting to
1800 s, and intentionally *not* set in the YAML, because the default is the tuned
value and overriding it per-run is a debugging action, not configuration.

The rationale recorded in the workflow itself:

> Performance tuning knobs — version-controlled here instead of repo variables
> (visible in PRs, survive forks, git history for the values).

## Rejected alternatives

- **A `parallel-jobs` key in the TOML config.** Rejected and removed; nothing reads
  it any more. Config files describe **what** gets built — app, patches, variant,
  channel. A concurrency number describes how a particular runner is provisioned, and
  baking it into published configuration would push the maintainer's machine profile
  onto every fork and every local run. It also put a runtime concern inside the data
  branch's diff churn.
- **GitHub repository variables (`vars.*`).** Invisible in a PR diff, absent on a
  fork, no history, and only changeable by someone with repo settings. A tuning change
  then arrives with no reviewable artifact and no way to ask "what was this before?".
- **An `"auto"` sentinel** (derive concurrency from `nproc`/memory). Rejected: it makes
  a build run non-reproducible from the workflow file, moves the failure mode into
  "the heuristic picked badly on this runner generation", and removes the ability to
  set the value to `1` deliberately to bisect a concurrency bug.
- **Per-invocation `workflow_dispatch` input.** Good for one-off debugging, wrong for
  a standing setting: the interesting value is the one CI runs by default, and that
  has to be readable before the run.

## Consequences

- Changing tuning is a **commit**, so it gets reviewed, reverted and bisected like
  code. `git log -p .github/workflows/build.yml` is the change history of the
  numbers, which is the thing nobody can reconstruct from repository variables.
- Forks inherit the settings and can change them in their own commit; nothing has to
  be re-entered through a web UI after a fork or a repo transfer.
- The knobs must be **read from env in exactly one place each**: `build.sh` owns
  validation and clamping of `PARALLEL_JOBS` (a script must survive a bad value
  rather than assuming the YAML was sane), the uploader owns `UPLOAD_CONCURRENCY`'s
  default. Adding a new knob means adding one env entry and one reader — no config
  plumbing, no docs keys.
- Because they are code, not settings, an agent or contributor can propose a tuning
  change as a normal PR. That is the whole point.

## Verification

`bash .github/traces/trace_runner.sh verify` is recorded against the sequential
shape (`PARALLEL_JOBS` unset → 1), so pool-related regressions surface there; the
pool's own invariants (rc-file drain, orphaned-child `137`, log replay grouping) are
exercised by real CI runs, where the step groups per build are visible in the log.
