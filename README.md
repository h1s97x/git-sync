# Git Sync

一个独立的 Git 仓库镜像工具：把当前仓库同步到另一个 Git 托管平台，以 Docker Action / 容器方式运行，支持 HTTPS 与 SSH 认证。

典型场景是在 GitHub Actions 中把仓库同步到 CNB，或定时把外部仓库拉取回来；也适用于 GitHub、GitLab、自建 Git 服务器之间的任意组合。

本项目由 `h1s97x` 独立维护，采用 MIT 协议发布。

## 功能特点

- 支持 HTTPS（推荐）和 SSH 两种认证方式
- 支持推送指定分支或所有分支
- 支持推送标签
- 支持强制推送
- 可配置 Git 用户信息
- 支持自定义 Git 服务器与私有仓库认证
- 支持 Git LFS

## 同步模式

支持三种模式，由 `sync_mode` 指定：

| 模式 | 行为 | 适用场景 |
| --- | --- | --- |
| `push`（默认） | 把当前仓库的分支、标签推送到 `target_url` | 单向镜像 |
| `rebase` | 克隆目标仓库，把源分支 rebase 上去再强推，保留目标仓库独有文件 | 两侧都有平台特有配置文件 |
| `pull` | 从 `target_url` 拉取并 rebase 到本地，再推回 `origin` | 定时任务把外部仓库同步进来 |

具体参数见下方参数表。

## 作为 GitHub Action 使用

仓库根目录的 `action.yml` 定义了 Docker Action。把示例中的目标仓库地址换成你自己的：

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
    if: github.actor != 'git-sync-bot'   # 避免与反向同步形成循环
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

GitHub 会把 `with:` 参数注入为 `INPUT_*`，入口脚本自动映射为 `PLUGIN_*`，因此参数含义与参数表完全一致。`dependabot` 创建的分支还需要配置 [Dependabot Secrets](https://docs.github.com/en/code-security/dependabot/troubleshooting-dependabot/troubleshooting-dependabot-on-github-actions#accessing-secrets)。

在 GitHub Actions 中不指定 `branch` 时，脚本会先补齐 `origin` 的所有远程分支引用，再以 `refs/remotes/origin/*:refs/heads/*` 推送，确保全分支镜像生效。

发布到 Marketplace：推送 `v0.0.1` 这类版本 tag，创建 Release 时勾选 "Publish to GitHub Marketplace"。`action.yml` 默认 `image: Dockerfile`，每次运行构建镜像；若要提速，可先发布镜像再把 `image` 改为 `docker://<registry>/<image>:<tag>`，并保持镜像 tag 与 action tag 一致。

### 定时拉取（pull 模式）

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

`pull` 模式会把目标仓库的分支同步到 `origin`，因此 job 需要 `contents: write` 权限；建议只在一侧配置同步，避免双向循环。

## 在其他 CI 或本地使用 Docker

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

也可以把构建好的镜像发布到自己的 Registry，供任意 CI 以 `image:` 或 `docker run` 方式调用。所有参数都通过 `PLUGIN_*` 环境变量传入。

## 参数说明

| 参数名 | 必填 | 默认值 | 说明 |
| --- | --- | --- | --- |
| target_url | 是 | - | 目标仓库 URL，支持 HTTPS 或 SSH 格式 |
| auth_type | 否 | https | 认证类型，可选 `https` 或 `ssh` |
| username | 否* | - | HTTPS 认证的用户名（*HTTPS 时必填） |
| password | 否* | - | HTTPS 认证的密码或访问令牌（*HTTPS 时必填） |
| ssh_key | 否* | - | SSH 私钥内容（*SSH 时必填） |
| branch | 否 | - | 指定后只推这个分支，不指定时推送所有分支 |
| force | 否 | false | 是否强制推送，只接受 `true` / `false`（`rebase` 模式内部始终强推） |
| push_tags | 否 | false | 是否推送标签 |
| git_user | 否 | Git Sync | Git 提交时的用户名 |
| git_email | 否 | git-sync@users.noreply.github.com | Git 提交时的邮箱 |
| git_host | 否 | - | 自定义 Git 服务器域名 |
| sync_mode | 否 | push | 可选 `push` / `rebase` / `pull`，未知值直接报错 |
| fetch_options | 否 | - | 传递给 `git fetch` 的额外选项，例如 `--depth=1 --prune` |

## 安全建议

1. 使用访问令牌（Access Token）而不是实际密码
2. 敏感信息放在 CI 的 Secret 中（GitHub Secrets / Dependabot Secrets），不要写进配置文件或命令行
3. SSH 私钥使用最小权限，`known_hosts` 与凭据文件在容器内均为 600 权限
4. 目标仓库使用具备最小写入权限的专用账号
5. 双向同步时用专用账号配合 `if:` 过滤，避免互推形成循环

## 常见问题

1. HTTPS 认证失败
   - 检查用户名和令牌是否正确、令牌是否有足够权限
   - 验证目标仓库 URL 是否正确、令牌中的特殊字符是否已被妥善处理

2. 推送失败
   - 检查是否有目标仓库的写入权限
   - 确认分支名称是否正确，是否指定了只推某个分支
   - 遇到非快进冲突时再考虑 `force: 'true'`

3. 自定义 Git 服务器
   - 确保 `git_host` 参数设置正确
   - 检查服务器 SSH 指纹是否已加入 `known_hosts`

4. dependabot[bot] 创建的分支同步失败
   - GitHub Actions 默认不向 Dependabot 触发的 workflow 提供普通 Secrets，需要单独配置 [Dependabot Secrets](https://docs.github.com/en/code-security/dependabot/troubleshooting-dependabot/troubleshooting-dependabot-on-github-actions#accessing-secrets)

## License

[MIT License](LICENSE) — 保留原始版权声明，并追加本项目维护者 `h1s97x` 的版权声明。
