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
  query LccActiveIssues($after: String) {
    viewer {
      assignedIssues(
        filter: { state: { type: { in: ["backlog", "unstarted", "started"] } } }
        first: 250
        after: $after
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
        pageInfo {
          hasNextPage
          endCursor
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
  viewer: {
    assignedIssues: {
      nodes: RawIssue[];
      pageInfo: { hasNextPage: boolean; endCursor: string | null };
    };
  };
}

const MAX_PAGES = 10; // 250 × 10 = 2500 issues; safety cap to avoid runaway loops

async function fetchAllRaw(client: LinearClient): Promise<RawIssue[]> {
  const all: RawIssue[] = [];
  let after: string | null = null;
  for (let page = 0; page < MAX_PAGES; page++) {
    const result: { data?: RawResponse } = await client.client.rawRequest<
      RawResponse,
      { after: string | null }
    >(ACTIVE_ISSUES_QUERY, { after });
    const data = result.data;
    if (!data) throw new Error('Linear API returned no data');
    const conn = data.viewer.assignedIssues;
    all.push(...conn.nodes);
    if (!conn.pageInfo.hasNextPage || !conn.pageInfo.endCursor) break;
    after = conn.pageInfo.endCursor;
  }
  return all;
}

export async function fetchActiveIssues(
  client: LinearClient,
  activeStateNames: string[],
): Promise<ActiveIssue[]> {
  const raw = await fetchAllRaw(client);
  const wantedNames = new Set(activeStateNames.map((s) => s.toLowerCase()));
  const enriched: ActiveIssue[] = [];
  for (const issue of raw) {
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
