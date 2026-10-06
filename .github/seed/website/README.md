# `website` branch

Build metadata for the download catalogue: `manifests/<tag>.json` per numbered release
and the cumulative `archive/{stable,beta}.json`. Written by `merge_archive_branch.sh`
after each build and pruned by `cleanup_website_branch.sh`; never edit by hand.
Format: `docs/website-contract.md` on `main`.
