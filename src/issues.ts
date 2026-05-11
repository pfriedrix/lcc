import type { LinearClient } from '@linear/sdk';

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
}

const ACTIVE_ISSUES_QUERY = /* GraphQL */ `
  query LccActiveIssues {
    viewer {
      assignedIssues(
        filter: { state: { type: { in: ["backlog", "unstarted", "started"] } } }
        first: 100
      ) {
        nodes {
          id
          identifier
          title
          branchName
          priority
          url
          updatedAt
          state {
            name
            type
          }
        }
      }
    }
  }
`;

interface RawIssue {
  id: string;
  identifier: string;
  title: string;
  branchName: string;
  priority: number;
  url: string;
  updatedAt: string;
  state: { name: string; type: string } | null;
}

interface RawResponse {
  viewer: { assignedIssues: { nodes: RawIssue[] } };
}

export async function fetchActiveIssues(
  client: LinearClient,
  activeStateNames: string[],
): Promise<ActiveIssue[]> {
  const { data } = await client.client.rawRequest<RawResponse, Record<string, never>>(
    ACTIVE_ISSUES_QUERY,
    {},
  );
  if (!data) throw new Error('Linear API returned no data');
  const wantedNames = new Set(activeStateNames.map((s) => s.toLowerCase()));
  const enriched: ActiveIssue[] = [];
  for (const issue of data.viewer.assignedIssues.nodes) {
    const stateName = issue.state?.name ?? 'Unknown';
    if (!wantedNames.has(stateName.toLowerCase())) continue;
    enriched.push({
      id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      branchName: issue.branchName,
      stateName,
      stateType: issue.state?.type ?? 'unknown',
      priority: issue.priority,
      url: issue.url,
      updatedAt: new Date(issue.updatedAt),
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
