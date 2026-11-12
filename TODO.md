# TODO

> 记录 `v0.0.1` 之后的待办事项。当前版本是 Pre-release，尚未正式发布。

## 上线前必做

- [ ] **Marketplace 上架**：在 GitHub 的 Release 编辑页勾选 "Publish to GitHub Marketplace"（Release API 不支持该选项）。等功能验证完成再发正式版。
- [ ] **配置 GitHub Secret**：在仓库 Settings → Secrets 添加 `GIT_SYNC_TOKEN`（对目标仓库有写权限），供真实 workflow 使用。
- [ ] **真机端到端验证**：跑一次实际 GitHub Actions workflow，逐项确认
  - `image: Dockerfile` 在 runner 上能正常构建并启动；
  - HTTPS 认证与 `target_url` 推送成功（含令牌含特殊字符的情况）；
  - Git LFS 对象的同步行为；
  - 全分支 refspec（`refs/remotes/origin/*:refs/heads/*`）在真实 `actions/checkout` 下生效；
  - `rebase` / `pull` 模式（目前只有离线静态检查，没有自动化测试）。

## 工程化

- [ ] 增加不依赖 Secret 的自检 workflow：在 runner 上跑 `sh -n entrypoint.sh`、YAML 结构校验，并做一次容器构建冒烟测试。
- [ ] 引入 `shellcheck` 到 CI，清理现有告警。
- [ ] 补一次 `action.yml` 的完整 YAML 解析验证（本地环境没有 YAML 解析器，此前只做过文本结构检查）。
- [ ] 评估基础镜像升级（`alpine:3.18`）与非 root 运行。

## 版本演进

- [ ] 0.x 阶段保持精确版本引用（`@v0.0.1`），不建浮动 `v0` / `v1` tag；稳定到 `1.0.0` 后再考虑浮动的 `v1`。
- [ ] 每次发版同步更新 4 处 `uses:` 示例与 2 处发布说明中的版本号（中英文 README）。
- [ ] 若发布预构建镜像以替代 `image: Dockerfile`，需保持镜像 tag 与 action tag 一致。

## 运维

- [ ] 确认 GitHub PAT 与 CNB 临时令牌已全部撤销。
- [ ] 全局 `credential.helper` 仍指向已删除的凭据文件，本地后续推送需重新配置 PAT / SSH。
