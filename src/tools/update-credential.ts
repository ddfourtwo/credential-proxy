import { updateSecretMetadata } from '../storage/secrets-store.js';
import type { SecretPlacement } from '../storage/types.js';

export interface UpdateCredentialInput {
  name: string;
  domains?: string[];
  placements?: string[];
  commands?: string[] | null;
}

export const updateCredentialTool = {
  name: 'update_credential',
  description:
    'Update metadata (allowed domains, placements, commands) for an existing credential without changing the secret value. Use this to grant additional placements like "env" for proxy_exec.',
  inputSchema: {
    type: 'object' as const,
    properties: {
      name: {
        type: 'string',
        description: 'Credential name (e.g., CODA_API_TOKEN)',
      },
      domains: {
        type: 'array',
        items: { type: 'string' },
        description: 'New allowed domains. Omit to keep unchanged.',
      },
      placements: {
        type: 'array',
        items: { type: 'string' },
        description:
          'New allowed placements: header, body, query, env, arg. Omit to keep unchanged.',
      },
      commands: {
        type: ['array', 'null'],
        items: { type: 'string' },
        description: 'New allowed command patterns for exec. Null to remove. Omit to keep unchanged.',
      },
    },
    required: ['name'],
  },
};

export async function handleUpdateCredential(
  args: UpdateCredentialInput
): Promise<{ success: boolean; error?: string }> {
  if (!args.name) {
    return { success: false, error: 'name is required' };
  }

  if (!args.domains && !args.placements && args.commands === undefined) {
    return { success: false, error: 'At least one of domains, placements, or commands must be provided' };
  }

  const updated = await updateSecretMetadata(args.name, {
    allowedDomains: args.domains,
    allowedPlacements: args.placements as SecretPlacement[] | undefined,
    allowedCommands: args.commands,
  });

  if (!updated) {
    return { success: false, error: `Credential '${args.name}' not found` };
  }

  return { success: true };
}
