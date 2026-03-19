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
      const msg = commit.commit?.message?.split('\n')[0] || 'No message';
      return `${sha} ${msg}`;
    })
    .join(' ; ');
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
  if (rows.length === 0) return '_None_';
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
    { label: 'Fork', value: (r) => repoLink(r.repo) },
    { label: 'Upstream', value: (r) => upstreamLink(r.upstream) },
    { label: 'Behind Before', value: (r) => r.behind_by },
    { label: 'Action', value: (r) => r.action },
    { label: 'Recent Commits', value: (r) => summarizeCommits(r.commits) },
    { label: 'Updated At', value: (r) => r.updated_at }
  ]);

  const manualTable = renderTable(manualRows, [
    { label: 'Fork', value: (r) => repoLink(r.repo) },
    { label: 'Upstream', value: (r) => upstreamLink(r.upstream) },
    { label: 'Ahead', value: (r) => r.ahead_by },
    { label: 'Behind', value: (r) => r.behind_by },
    { label: 'Result', value: (r) => r.result },
    { label: 'Reason', value: (r) => r.reason }
  ]);

  const errorTable = renderTable(errorRows, [
    { label: 'Fork', value: (r) => repoLink(r.repo) },
    { label: 'Result', value: (r) => r.result },
    { label: 'Reason', value: (r) => r.reason }
  ]);

  const fleetTable = renderTable(report.repos, [
    { label: 'Fork', value: (r) => repoLink(r.repo) },
    { label: 'Upstream', value: (r) => upstreamLink(r.upstream) },
    { label: 'Branch', value: (r) => r.branch },
    { label: 'Ahead', value: (r) => r.ahead_by },
    { label: 'Behind', value: (r) => r.behind_by },
    { label: 'Status', value: (r) => r.status },
    { label: 'Result', value: (r) => r.result },
    { label: 'Last Checked', value: (r) => r.updated_at }
  ]);

  return [
    '# fork-updater',
    '',
    `自动巡检并同步 \`${owner}\` 账号下的 fork 仓库，并将结果汇总到本 README。`,
    '',
    '## Overview',
    '',
    `- Last run start: ${report.run_started_at}`,
    `- Last run finish: ${report.run_completed_at}`,
    `- Forks scanned: ${report.summary.scanned}`,
    `- Updated automatically: ${report.summary.updated}`,
    `- Already up to date: ${report.summary.up_to_date}`,
    `- Needs manual action: ${report.summary.manual}`,
    `- Errors: ${report.summary.errors}`,
    `- Auto-sync token configured: ${canAttemptSync ? 'Yes' : 'No'}`,
    '',
    '## Today\'s Changes',
    '',
    todayChanges,
    '',
    '## Needs Manual Action',
    '',
    manualTable,
    '',
    '## Errors',
    '',
    errorTable,
    '',
    '## Current Fleet Status',
    '',
    fleetTable,
    '',
    '## Notes',
    '',
    '- This repository updates itself after each scheduled run.',
    '- To enable automatic fork syncing across your fork repositories, set a repository secret named `FORK_SYNC_TOKEN`.',
    '- If `FORK_SYNC_TOKEN` is missing, the dashboard still reports which forks are behind upstream, but it will not sync them automatically.',
    `- Dashboard repo: [${repoSlug}](${serverUrl}/${repoSlug})`,
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
