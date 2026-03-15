export interface RequestCredentialInput {
  name: string;
  domains: string[];
  placements?: string[];
  commands?: string[];
  overwrite?: boolean;
}

export const requestCredentialTool = {
  name: 'request_credential',
  description:
    'Request the user to add a credential via the macOS UI. The user will see a window where they can paste the secret value. Use this when you need a credential that is not yet configured. If a credential with the same name already exists, the request will be denied unless overwrite is set to true.',
  inputSchema: {
    type: 'object' as const,
    properties: {
      name: {
        type: 'string',
        description: 'Credential name in SCREAMING_SNAKE_CASE (e.g., GITHUB_TOKEN)',
      },
      domains: {
        type: 'array',
        items: { type: 'string' },
        description: 'Allowed domains (e.g., ["*.github.com"])',
      },
      placements: {
        type: 'array',
        items: { type: 'string' },
        description:
          'Where the secret can appear: header, body, query, env, arg. Defaults to ["header"]',
      },
      commands: {
        type: 'array',
        items: { type: 'string' },
        description: 'Allowed command patterns for exec (e.g., ["git *"]). Optional.',
      },
      overwrite: {
        type: 'boolean',
        description: 'Set to true to overwrite an existing credential. Defaults to false.',
      },
    },
    required: ['name', 'domains'],
  },
};
