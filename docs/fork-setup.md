# Running your own fork

The builder is written to run as one maintainer's repository with a few satellites (a
stock-APK cache, a download site, a Telegram channel). A fork needs none of the satellites;
it does need two branches to exist before the first workflow can run, because the pipeline
**hard-fails** on a missing `data` or `website` branch instead of starting from empty
([ai-context rule 7](ai-context.md)).

## 1. Seed the branches once

```bash
git clone https://github.com/<you>/rvb && cd rvb
bash .github/scripts/seed_data_branch.sh            # creates origin/data and origin/website
```

- `data` gets `configs/` (the per-source TOMLs from [`.github/seed/data`](../.github/seed/data),
  a `config.manual.toml` for Manual CI, empty generated pool configs) and empty `state/*.json`.
- `website` gets a README only; the first build writes `manifests/` and `archive/` into it.
- `update` is created by the first build that produces a module and needs no seeding.
- The script refuses to touch a branch that already exists, and refuses when the remote cannot
  be queried. `SEED_DRY_RUN=1` prints the tree it would push.

After this the branches are the source of truth and the seed directory is just history. Edit
apps with `fetch_data_branch.sh` → edit `configs/patches/*.toml` →
`push_data_configs.sh "<message>"` ([contributing.md](contributing.md)).

## 2. Settings

| Kind | Name | Needed? | Effect when unset |
|---|---|---|---|
| Actions | read/write workflow permissions | **yes** | Settings → Actions → General → "Read and write permissions"; the branch and release writes fail without it |
| secret | `KEYSTORE_B64`, `KEYSTORE_P12_B64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS` | recommended | the repository's bundled `ks.keystore` signs your builds, which is a public key — set your own before sharing APKs |
| secret / var | `APKS_REPO_TOKEN` / `APKS_REPO` | no | the stock-APK cache is off; every build downloads from the stores |
| var | `WEBSITE_REPO` (+ `WEBSITE_DISPATCH_TOKEN`) | no | no catalogue dispatch is sent |
| secret / var | `TG_TOKEN`, `TG_CHAT_ID`, `TG_CHAT_ID_BROADCAST`, `TG_THREAD_*` | no | no Telegram posts |
| var | `RELEASE_NOTES_TG_LINK`, `RELEASE_NOTES_DONATE_LINK`, `RELEASE_NOTES_WEBSITE_LINK` | no | that link is simply left out of the release notes |

There are deliberately no built-in defaults pointing at the upstream's cache, site or chat: an
unset value switches the feature off rather than sending your traffic (or token) to somebody
else's repository.

## 3. First run

Dispatch **CI**. With empty state every source and every app counts as changed, so the first
watcher run builds the whole configured list: the stable pool as numbered releases plus the
rolling `stable` archive, the beta pool (pre-releases) plus `beta`. Builds are sequential
(`PARALLEL_JOBS: "1"`), so expect a long first run; later runs only rebuild what moved. To try one
app end to end first, edit `configs/config.manual.toml` and dispatch **Manual CI**.

Two things the first run will not do, by design: the **beta** pool builds an app only when one of its
sources has a pre-release newer than its latest stable release (otherwise the stable pool already
covers it), so Instagram and Battery Guru wait for such a release; and a mirrored app that follows a
rolling tag (Duck Detector's `nightly`) never looks "updated" to the watcher, because the tag name never
changes — to refresh it, put its table in `configs/config.manual.toml` and dispatch **Manual CI**.

Sources that block GitHub-hosted runners (Cloudflare challenges on APKMirror/Uptodown) fail per
app and are skipped; the rest of the run is unaffected. A pinned stock APK you host yourself is the
reliable fallback (`github-dlurl` pointing at a release of your own).

## 4. Following it in Obtainium

[../OBTAINIUM.md](../OBTAINIUM.md) lists every app with a one-tap link and explains the
settings those links use.
