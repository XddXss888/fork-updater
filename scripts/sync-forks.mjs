import { writeFileSync, mkdirSync } from 'node:fs';

const owner = process.env.GITHUB_OWNER;
const repoSlug = process.env.GITHUB_REPOSITORY;
const serverUrl = process.env.GITHUB_SERVER_URL || 'https://github.com';
const dashboardToken = process.env.GITHUB_TOKEN;
const syncToken = process.env.FORK_SYNC_TOKEN || dashboardToken;
const canAttemptSync = Boolean(process.env.FORK_SYNC_TOKEN);

if (!owner || !repoSlug || !dashboardToken) {
  throw new Error('Missing required environment: GITHUB_OWNER, GITHUB_REPOSITORY, or GITHUB_TOKEN');
}

async function api(path, { method = 'GET', token = syncToken, body } = {}) {
  const response = await fetch(`https://api.github.com${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'fork-updater'
    },
    body: body ? JSON.stringify(body) : undefined
  });

  if (response.status === 204) return null;

  const text = await response.text();
  const data = text ? JSON.parse(text) : null;

  if (!response.ok) {
    const message = data?.message || text || `HTTP ${response.status}`;
    const error = new Error(message);
    error.status = response.status;
    error.payload = data;
    throw error;
  }

  return data;
}

async function paginate(path, token = syncToken) {
  const results = [];
  let page = 1;
  while (true) {
    const data = await api(`${path}${path.includes('?') ? '&' : '?'}per_page=100&page=${page}`, { token });
    if (!Array.isArray(data) || data.length === 0) break;
    results.push(...data);
    if (data.length < 100) break;
    page += 1;
  }
  return results;
}

function escapeCell(value) {
  return String(value ?? '').replace(/\|/g, '\\|').replace(/\n/g, ' ');
}

function repoLink(name) {
  return `[${name}](${serverUrl}/${owner}/${name})`;
}

function upstreamLink(fullName) {
  if (!fullName) return '';
  return `[${fullName}](${serverUrl}/${fullName})`;
}

function shortenSha(sha) {
  return sha ? sha.slice(0, 7) : '';
}

function summarizeCommits(commits = []) {
  return commits
    .slice(0, 3)
    .map((commit) => {
      const sha = shortenSha(commit.sha);
      const msg = commit.commit?.message?.split('\n')[0] || '无提交说明';
      return `${sha} ${msg}`;
    })
    .join('；');
}

function localizeStatus(status) {
  const map = {
    updated: '已自动同步',
    up_to_date: '已是最新',
    manual: '需要人工处理',
    error: '检查异常'
  };
  return map[status] || status;
}

function localizeResult(result) {
  const map = {
    synced: '同步成功',
    'already-current': '已是最新',
    diverged: '已分叉',
    archived: '仓库已归档',
    'sync-token-missing': '缺少同步令牌',
    'sync-failed': '自动同步失败',
    'compare-failed': '比较失败',
    'missing-parent': '缺少上游信息'
  };
  return map[result] || result;
}

function localizeReason(reason) {
  if (!reason) return '';
  return reason
    .replace('Fork metadata has no parent repository information.', 'Fork 元数据中缺少上游仓库信息。')
    .replace('Repository is archived and cannot be updated automatically.', '仓库已归档，无法自动更新。')
    .replace('Fork has local commits and is behind upstream. Manual review is required.', '当前 fork 有本地提交且落后于上游，需要人工处理。')
    .replace('FORK_SYNC_TOKEN is not configured, so auto-sync is disabled.', '未配置 FORK_SYNC_TOKEN，已禁用自动同步。')
    .replace('Auto-sync failed:', '自动同步失败：')
    .replace('Failed to compare fork with upstream:', '比较 fork 与上游失败：')
    .replace('Merged upstream branch ', '已合并上游分支 ');
}

async function getForkRepos() {
  const repos = await paginate('/user/repos?type=owner&sort=full_name', syncToken);
  return repos.filter((repo) => repo.fork);
}

async function inspectFork(repo) {
  const full = await api(`/repos/${owner}/${repo.name}`, { token: syncToken });
  const parent = full.parent;
  const branch = full.default_branch;
  const now = new Date().toISOString();

  if (!parent) {
    return {
      repo: repo.name,
      upstream: '',
      branch,
      ahead_by: 0,
      behind_by: 0,
      status: 'error',
      action: 'none',
      result: 'missing-parent',
      reason: 'Fork metadata has no parent repository information.',
      compare_url: full.html_url,
      updated_at: now,
      commits: []
    };
  }

  if (full.archived) {
    return {
      repo: repo.name,
      upstream: parent.full_name,
      branch,
      ahead_by: 0,
      behind_by: 0,
      status: 'manual',
      action: 'skip',
      result: 'archived',
      reason: 'Repository is archived and cannot be updated automatically.',
      compare_url: `${serverUrl}/${owner}/${repo.name}`,
      updated_at: now,
      commits: []
    };
  }

  try {
    const compare = await api(
      `/repos/${owner}/${repo.name}/compare/${encodeURIComponent(branch)}...${parent.owner.login}:${encodeURIComponent(parent.default_branch)}`,
      { token: syncToken }
    );

    const aheadBy = compare.ahead_by ?? 0;
    const behindBy = compare.behind_by ?? 0;
    const commits = compare.commits || [];

    const result = {
      repo: repo.name,
      upstream: parent.full_name,
      branch,
      ahead_by: aheadBy,
      behind_by: behindBy,
      status: 'up_to_date',
      action: 'none',
      result: 'already-current',
      reason: '',
      compare_url:
        compare.html_url ||
        `${serverUrl}/${owner}/${repo.name}/compare/${branch}...${parent.owner.login}:${parent.default_branch}`,
      updated_at: now,
      commits
    };

    if (behindBy === 0) return result;

    if (aheadBy > 0) {
      return {
        ...result,
        status: 'manual',
        action: 'skip',
        result: 'diverged',
        reason: 'Fork has local commits and is behind upstream. Manual review is required.'
      };
    }

    if (!canAttemptSync) {
      return {
        ...result,
        status: 'manual',
        action: 'not-configured',
        result: 'sync-token-missing',
        reason: 'FORK_SYNC_TOKEN is not configured, so auto-sync is disabled.'
      };
    }

    try {
      await api(`/repos/${owner}/${repo.name}/merge-upstream`, {
        method: 'POST',
        token: syncToken,
        body: { branch: parent.default_branch }
      });

      return {
        ...result,
        status: 'updated',
        action: 'merge-upstream',
        result: 'synced',
        reason: `Merged upstream branch ${parent.default_branch}.`
      };
    } catch (error) {
      return {
        ...result,
        status: 'manual',
        action: 'merge-upstream',
        result: 'sync-failed',
        reason: `Auto-sync failed: ${error.message}`
      };
    }
  } catch (error) {
    return {
      repo: repo.name,
      upstream: parent.full_name,
      branch,
      ahead_by: 0,
      behind_by: 0,
      status: 'error',
      action: 'none',
      result: 'compare-failed',
      reason: `Failed to compare fork with upstream: ${error.message}`,
      compare_url: `${serverUrl}/${owner}/${repo.name}`,
      updated_at: now,
      commits: []
    };
  }
}

function renderTable(rows, columns) {
  if (rows.length === 0) return '_无_';
  const header = `| ${columns.map((c) => c.label).join(' | ')} |`;
  const divider = `| ${columns.map(() => '---').join(' | ')} |`;
  const body = rows
    .map((row) => `| ${columns.map((c) => escapeCell(c.value(row))).join(' | ')} |`)
    .join('\n');
  return `${header}\n${divider}\n${body}`;
}

function renderReadme(report) {
  const updatedRows = report.repos.filter((r) => r.status === 'updated');
  const manualRows = report.repos.filter((r) => r.status === 'manual');
  const errorRows = report.repos.filter((r) => r.status === 'error');

  const todayChanges = renderTable(updatedRows, [
    { label: 'Fork 仓库', value: (r) => repoLink(r.repo) },
    { label: '上游仓库', value: (r) => upstreamLink(r.upstream) },
    { label: '同步前落后提交数', value: (r) => r.behind_by },
    { label: '执行动作', value: (r) => r.action === 'merge-upstream' ? '合并上游更新' : r.action },
    { label: '最近提交', value: (r) => summarizeCommits(r.commits) },
    { label: '更新时间', value: (r) => r.updated_at }
  ]);

  const manualTable = renderTable(manualRows, [
    { label: 'Fork 仓库', value: (r) => repoLink(r.repo) },
    { label: '上游仓库', value: (r) => upstreamLink(r.upstream) },
    { label: '领先提交数', value: (r) => r.ahead_by },
    { label: '落后提交数', value: (r) => r.behind_by },
    { label: '结果', value: (r) => localizeResult(r.result) },
    { label: '原因', value: (r) => localizeReason(r.reason) }
  ]);

  const errorTable = renderTable(errorRows, [
    { label: 'Fork 仓库', value: (r) => repoLink(r.repo) },
    { label: '结果', value: (r) => localizeResult(r.result) },
    { label: '原因', value: (r) => localizeReason(r.reason) }
  ]);

  const fleetTable = renderTable(report.repos, [
    { label: 'Fork 仓库', value: (r) => repoLink(r.repo) },
    { label: '上游仓库', value: (r) => upstreamLink(r.upstream) },
    { label: '默认分支', value: (r) => r.branch },
    { label: '领先提交数', value: (r) => r.ahead_by },
    { label: '落后提交数', value: (r) => r.behind_by },
    { label: '状态', value: (r) => localizeStatus(r.status) },
    { label: '结果', value: (r) => localizeResult(r.result) },
    { label: '最后检查时间', value: (r) => r.updated_at }
  ]);

  return [
    '# fork-updater',
    '',
    `自动巡检并同步 \`${owner}\` 账号下的 fork 仓库，并将结果汇总到本 README。`,
    '',
    '## 概览',
    '',
    `- 本次运行开始时间：${report.run_started_at}`,
    `- 本次运行结束时间：${report.run_completed_at}`,
    `- 已扫描 fork 仓库数：${report.summary.scanned}`,
    `- 自动同步成功数：${report.summary.updated}`,
    `- 已是最新数：${report.summary.up_to_date}`,
    `- 需要人工处理数：${report.summary.manual}`,
    `- 检查异常数：${report.summary.errors}`,
    `- 是否已配置自动同步令牌：${canAttemptSync ? '是' : '否'}`,
    '',
    '## 今日更新',
    '',
    todayChanges,
    '',
    '## 需要人工处理',
    '',
    manualTable,
    '',
    '## 检查异常',
    '',
    errorTable,
    '',
    '## 当前全部 Fork 状态',
    '',
    fleetTable,
    '',
    '## 说明',
    '',
    '- 本仓库会在每次定时运行后自动更新自身 README 与状态数据。',
    '- 如需自动同步你账号下的 fork 仓库，请在仓库 Secrets 中配置 `FORK_SYNC_TOKEN`。',
    '- 如果未配置 `FORK_SYNC_TOKEN`，系统仍会检查并展示哪些 fork 落后于上游，但不会自动同步。',
    `- 仪表盘仓库： [${repoSlug}](${serverUrl}/${repoSlug})`,
    ''
  ].join('\n');
}

async function main() {
  mkdirSync('data', { recursive: true });
  const report = {
    run_started_at: new Date().toISOString(),
    run_completed_at: null,
    summary: {
      scanned: 0,
      updated: 0,
      up_to_date: 0,
      manual: 0,
      errors: 0
    },
    repos: []
  };

  const forks = await getForkRepos();
  for (const repo of forks) {
    const result = await inspectFork(repo);
    report.repos.push(result);
  }

  report.repos.sort((a, b) => a.repo.localeCompare(b.repo));
  report.summary.scanned = report.repos.length;
  report.summary.updated = report.repos.filter((r) => r.status === 'updated').length;
  report.summary.up_to_date = report.repos.filter((r) => r.status === 'up_to_date').length;
  report.summary.manual = report.repos.filter((r) => r.status === 'manual').length;
  report.summary.errors = report.repos.filter((r) => r.status === 'error').length;
  report.run_completed_at = new Date().toISOString();

  writeFileSync('data/last-run.json', `${JSON.stringify(report, null, 2)}\n`);
  writeFileSync('README.md', renderReadme(report));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
