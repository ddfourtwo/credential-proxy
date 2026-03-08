import { listSecrets } from '../storage/secrets-store.js';

export interface ListCredentialsInput {
  filter?: string;
}

export interface CredentialInfo {
  name: string;
  allowedDomains: string[];
  allowedPlacements: string[];
  configured: boolean;
}

export interface ListCredentialsOutput {
  secrets: CredentialInfo[];
}

export const listCredentialsTool = {
  name: 'list_credentials',
  description: 'List configured secrets (names and metadata only, not values). Use this to discover what credentials are available before making authenticated requests with proxy_request.',
  inputSchema: {
    type: 'object' as const,
    properties: {
      filter: {
        type: 'string',
        description: 'Optional: filter by name pattern (e.g., "LINEAR*" or "*_TOKEN")'
      }
    }
  }
};

function matchesFilter(name: string, filter: string): boolean {
  // Convert wildcard pattern to regex
  const regexPattern = filter
    .replace(/[.+?^${}()|[\]\\]/g, '\\$&') // Escape special regex chars except *
    .replace(/\*/g, '.*'); // Convert * to .*
  const regex = new RegExp(`^${regexPattern}$`, 'i');
  return regex.test(name);
}

export async function handleListCredentials(input: ListCredentialsInput): Promise<ListCredentialsOutput> {
  let secrets = await listSecrets();

  if (input.filter) {
    secrets = secrets.filter(s => matchesFilter(s.name, input.filter!));
  }

  return {
    secrets: secrets.map(s => ({
      name: s.name,
      allowedDomains: s.allowedDomains,
      allowedPlacements: s.allowedPlacements,
      configured: true
    }))
  };
}
