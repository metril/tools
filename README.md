# tools

A small, multi-arch container image bundling the tools needed in CI/CD pipelines
(built for use as a GitLab CI image). It currently ships:

- [HashiCorp Vault](https://developer.hashicorp.com/vault) (pinned, signature-verified)
- `jq`, `curl`, `wget` (from the Alpine package repos)
- `bash`, `ca-certificates`

## Usage

```yaml
# .gitlab-ci.yml
some-job:
  image: ghcr.io/metril/tools:latest
  script:
    - vault version
    - jq --version
```

Pull a specific version:

```bash
docker pull ghcr.io/metril/tools:1.2.3   # exact
docker pull ghcr.io/metril/tools:1.2     # latest patch of 1.2
docker pull ghcr.io/metril/tools:1       # latest minor of 1
docker pull ghcr.io/metril/tools:latest  # newest release
```

Images are published for `linux/amd64` and `linux/arm64`.

## How versioning works

The container has its **own** semantic version, managed by
[semantic-release](https://semantic-release.gitbook.io/) from
[Conventional Commits](https://www.conventionalcommits.org/):

| Change                                   | Commit type | Bump  |
| ---------------------------------------- | ----------- | ----- |
| New Vault version adopted                | `feat:`     | minor |
| Base image digest / package refresh      | `fix:`      | patch |
| Scheduled rebuild                        | `fix:`      | patch |

Each release also produces a GitHub Release with notes and a `CHANGELOG.md` entry.

## How rebuilds are triggered (the 1-week vetting delay)

[`scripts/check-upstream.sh`](scripts/check-upstream.sh) runs daily
([`check-upstream.yml`](.github/workflows/check-upstream.yml)) and compares the pinned
inputs in [`versions.json`](versions.json) against upstream:

- **Vault** — via the HashiCorp releases API (`version` + `timestamp_created`).
- **Base image** — the current `alpine:3.x` digest and its build date.

A newer upstream is **only adopted once it has been public for at least 7 days**, giving
the community time to vet it. When a version clears that gate, the workflow opens an
**auto-merge PR** bumping `versions.json`; once required checks pass it merges, and
[`release.yml`](.github/workflows/release.yml) cuts a new release and pushes the image.

> Because `jq`/`curl`/`wget` come from the Alpine repos, tracking the base-image digest
> already refreshes them whenever Alpine ships fixes. A weekly
> [`scheduled-rebuild`](.github/workflows/rebuild.yml) is an extra safety net for fixes
> that land between base-image rebuilds.

## Repository setup

**Nothing is required to publish.** The release pipeline uses the built-in
`GITHUB_TOKEN` (granted `contents: write` + `packages: write` in the workflow) to cut
versions, push to GHCR, and create GitHub Releases — the same way most GitHub-Actions
projects work, no secret needed.

The daily upstream-check and weekly rebuild workflows still open PRs and try to
auto-merge them on the built-in token, **but** GitHub deliberately prevents PRs opened
by `GITHUB_TOKEN` from triggering other workflows — so the `build-test` check won't run
on those bot PRs and auto-merge can't complete. By default you simply **merge those
bot PRs yourself** (one click), which then triggers the release.

### Optional: fully hands-off automation

If you want the bot PRs to build and auto-merge with zero clicks:

1. **Create a token** — a fine-grained PAT scoped to this repo with **Contents: read/write**
   and **Pull requests: read/write** (Metadata read is automatic). A classic PAT with the
   `repo` scope also works. *Not needed:* `packages` (GHCR uses `GITHUB_TOKEN`) or `workflow`.
   `Settings → Developer settings → Personal access tokens → Fine-grained tokens`.
2. **Store it** as the secret **`AUTOMATION_TOKEN`**:
   `Settings → Secrets and variables → Actions → New repository secret` (or
   `gh secret set AUTOMATION_TOKEN`). Every workflow falls back to it automatically
   (`secrets.AUTOMATION_TOKEN || secrets.GITHUB_TOKEN`).
3. **Enable auto-merge:** `Settings → General` → *Pull Requests* → tick "Allow auto-merge".
4. **Branch protection** on `main`: `Settings → Branches → Add branch protection rule` →
   pattern `main` → "Require status checks to pass" → select **`build-test`**. Add the
   token's user/App to the rule's **bypass list** so the `chore(release): … [skip ci]`
   changelog commit can push.

## CI dependencies

The workflows use **only GitHub- and Docker-published actions** (`actions/*`, `docker/*`) —
no third-party actions. PR automation uses the built-in `git` + `gh` CLI, and releases run
[`semantic-release`](https://semantic-release.gitbook.io/) directly via `npm`
(pinned in [`package.json`](package.json) / `package-lock.json`).

## Adding a tool

Edit the `Dockerfile` (and pin + gate it in `versions.json` /
`scripts/check-upstream.sh` if it comes from a tracked upstream), commit with a
`feat:`/`fix:` message, and the release pipeline handles the rest.
