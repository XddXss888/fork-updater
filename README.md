# fork-updater

自动巡检并同步 `XddXss888` 账号下的 fork 仓库，并将结果汇总到本仓库 README。

## 能力

- 每天定时扫描当前账号下的所有 fork 仓库
- 检查 upstream 是否有新提交
- 对可自动同步的 fork 调用 GitHub API 自动同步
- 对存在分叉、冲突、归档、权限不足等情况的仓库输出人工处理提示
- 生成最新一次运行汇总和全量状态面板

## 工作方式

- 入口工作流：`.github/workflows/daily-sync.yml`
- 核心脚本：`scripts/sync-forks.mjs`
- 状态数据：`data/last-run.json`

## 权限说明

默认 `GITHUB_TOKEN` 用于：
- 读取 fork 仓库状态
- 更新本仓库 README 和数据文件

如果你希望**自动同步 fork 到最新 upstream**，建议在本仓库 Secrets 中额外配置：

- `FORK_SYNC_TOKEN`

这个 token 需要对目标 fork 仓库拥有足够权限，以便调用 GitHub 的 `merge-upstream` 接口。

如果没有配置 `FORK_SYNC_TOKEN`，本仓库仍会每天输出状态面板，但会把“可更新但未自动同步”的仓库标记出来。

## 当前状态

首次工作流运行后，这里会自动生成最新同步摘要。
