# Git Sync

A standalone Git repository mirroring tool. It syncs the current repository to another Git host, runs as a Docker Action or a plain container, and supports HTTPS and SSH authentication.

A typical use case is mirroring a GitHub repository to CNB from GitHub Actions, or pulling an external repository back on a schedule. Any combination of GitHub, GitLab, self-hosted Git servers, and other hosts works.

Maintained independently by `h1s97x` and released under the MIT License.

## Features

- HTTPS (recommended) and SSH authentication
- Push a specific branch or all branches
- Push tags
- Force push
- Configurable Git user information
- Custom Git servers and private repositories
- Git LFS support

## Sync Modes

Three modes are available via `sync_mode`:

| Mode | Behavior | Use case |
| --- | --- | --- |
| `push` (default) | Push branches and tags of the current repository to `target_url` | One-way mirroring |
| `rebase` | Clone the target, rebase source branches onto it, then force push, keeping target-only files | Both sides have host-specific config files |
| `pull` | Fetch from `target_url`, rebase locally, then push back to `origin` | Scheduled sync of an external repository |

See the parameter table below for all options.

## Using as a GitHub Action

The `action.yml` at the repository root defines a Docker Action. Replace the target repository URL in the examples with your own:

```yaml
# .github/workflows/git-sync.yml
name: Mirror Repository
on:
  push:
    branches: ['**']
    tags: ['**']
  workflow_dispatch:

concurrency:
  group: git-sync
  cancel-in-progress: false

jobs:
  sync:
    if: github.actor != 'git-sync-bot'   # avoid a loop with a reverse sync
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: h1s97x/git-sync@v0.0.1
        with:
          target_url: https://git.example.com/<org>/<repo>.git
          auth_type: https
          username: <your-username>
          password: ${{ secrets.GIT_SYNC_TOKEN }}
          push_tags: 'true'
```

GitHub injects every `with:` key as `INPUT_*`; the entrypoint maps those to `PLUGIN_*` automatically, so the inputs below behave exactly like the parameter table. Branches created by `dependabot` additionally need [Dependabot Secrets](https://docs.github.com/en/code-security/dependabot/troubleshooting-dependabot/troubleshooting-dependabot-on-github-actions#accessing-secrets).

When no `branch` is given in GitHub Actions, the entrypoint first fetches all remote branch refs from `origin` and pushes with `refs/remotes/origin/*:refs/heads/*`, so mirroring all branches actually works.

To publish on the Marketplace, push a version tag such as `v0.0.1` and check "Publish to GitHub Marketplace" when creating the Release. `action.yml` uses `image: Dockerfile`, which builds the image on every run; to speed this up, publish the image first and switch `image` to `docker://<registry>/<image>:<tag>`, keeping the image tag aligned with the action tag.

### Scheduled pull

```yaml
name: Pull Mirror
on:
  schedule:
    - cron: "0 1 * * *"

jobs:
  pull:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: h1s97x/git-sync@v0.0.1
        with:
          target_url: https://git.example.com/<org>/<repo>.git
          auth_type: https
          username: <your-username>
          password: ${{ secrets.GIT_SYNC_TOKEN }}
          sync_mode: pull
```

`pull` mode pushes the fetched branches to `origin`, so the job needs `contents: write`. Configure syncing on one side only to avoid a loop.

## Using with Docker in other CI systems or locally

```bash
docker build -t git-sync:local .
docker run --rm \
  -e PLUGIN_TARGET_URL="https://git.example.com/<org>/<repo>.git" \
  -e PLUGIN_AUTH_TYPE="https" \
  -e PLUGIN_USERNAME="<your-username>" \
  -e PLUGIN_PASSWORD="<your-access-token>" \
  -e PLUGIN_BRANCH="main" \
  -v $(pwd):$(pwd) \
  -w $(pwd) \
  git-sync:local
```

You can also publish the built image to your own registry and invoke it from any CI via `image:` or `docker run`. All options are passed as `PLUGIN_*` environment variables.

## Parameter Description

| Parameter | Required | Default | Description |
| --- | --- | --- | --- |
| target_url | Yes | - | Target repository URL, HTTPS or SSH |
| auth_type | No | https | `https` or `ssh` |
| username | No* | - | Username for HTTPS auth (*required for HTTPS) |
| password | No* | - | Password or access token for HTTPS (*required for HTTPS) |
| ssh_key | No* | - | SSH private key content (*required for SSH) |
| branch | No | - | Push only this branch; all branches when unset |
| force | No | false | Force push, accepts `true` / `false` only (`rebase` always force pushes internally) |
| push_tags | No | false | Push tags |
| git_user | No | Git Sync | Git committer name |
| git_email | No | git-sync@users.noreply.github.com | Git committer email |
| git_host | No | - | Custom Git server host |
| sync_mode | No | push | `push` / `rebase` / `pull`; unknown values fail immediately |
| fetch_options | No | - | Extra options for `git fetch`, e.g. `--depth=1 --prune` |

## Security Recommendations

1. Use access tokens instead of real passwords
2. Keep secrets in your CI secret store (GitHub Secrets / Dependabot Secrets), never in config files or command lines
3. Keep SSH private keys restricted; `known_hosts` and credential files are created with mode 600 inside the container
4. Use a dedicated account with the minimum write permissions on the target repository
5. When syncing in both directions, use a dedicated account with `if:` filtering to avoid loops

## Common Issues

1. HTTPS authentication failure
   - Check the username/token and its permissions
   - Verify the target URL and that special characters in the token are handled

2. Push failure
   - Check write permissions on the target repository
   - Check the branch name and whether `branch` was set
   - Use `force: 'true'` only for non-fast-forward conflicts

3. Custom Git server
   - Make sure `git_host` is set correctly
   - Verify the server's SSH fingerprint was added to `known_hosts`

4. Syncing branches created by dependabot[bot] fails
   - GitHub Actions does not expose regular Secrets to Dependabot-triggered workflows by default; configure [Dependabot Secrets](https://docs.github.com/en/code-security/dependabot/troubleshooting-dependabot/troubleshooting-dependabot-on-github-actions#accessing-secrets)

## License

[MIT License](LICENSE) — the original copyright notice is retained, with `h1s97x`'s copyright added as the maintainer.
