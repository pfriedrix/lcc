import type { Issue, LinearClient } from '@linear/sdk';

export interface ActiveIssue {
  id: string;
  identifier: string;
  title: string;
  branchName: string;
  stateName: string;
  stateType: string;
  priority: number;
  url: string;
  updatedAt: Date;
  raw: Issue;
}

export async function fetchActiveIssues(
  client: LinearClient,
  activeStateNames: string[],
): Promise<ActiveIssue[]> {
  const me = await client.viewer;
  const result = await me.assignedIssues({
    filter: { state: { type: { in: ['backlog', 'unstarted', 'started'] } } },
    first: 100,
  });
  const wantedNames = new Set(activeStateNames.map((s) => s.toLowerCase()));
  const enriched: ActiveIssue[] = [];
  for (const issue of result.nodes) {
    const state = await issue.state;
    const stateName = state?.name ?? 'Unknown';
    if (!wantedNames.has(stateName.toLowerCase())) continue;
    enriched.push({
      id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      branchName: issue.branchName,
      stateName,
      stateType: state?.type ?? 'unknown',
      priority: issue.priority,
      url: issue.url,
      updatedAt: issue.updatedAt,
      raw: issue,
    });
  }
  // Preserve the order from `activeStateNames` (so Todo before In Progress, etc.),
  // then most recently updated first within each state.
  const stateOrder = new Map(activeStateNames.map((s, i) => [s.toLowerCase(), i]));
  enriched.sort((a, b) => {
    const ai = stateOrder.get(a.stateName.toLowerCase()) ?? 99;
    const bi = stateOrder.get(b.stateName.toLowerCase()) ?? 99;
    if (ai !== bi) return ai - bi;
    return b.updatedAt.getTime() - a.updatedAt.getTime();
  });
  return enriched;
}
