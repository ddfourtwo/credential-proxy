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
    'Request the user to add a credential via the macOS UI. The user will see a window where they can paste the secret value. This call BLOCKS until the user saves or cancels, then returns the outcome — do not end your turn or tell the user to paste separately; just await the result and continue. A success result means the credential is already stored and ready to use. Use this when you need a credential that is not yet configured. If a credential with the same name already exists, the request will be denied unless overwrite is set to true.',
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
        description: 'Allowed command patterns for exec (e.g., ["git *"]). Required if this credential will be used with proxy_exec — a secret with no command allowlist cannot be used in exec.',
      },
      overwrite: {
        type: 'boolean',
        description: 'Set to true to overwrite an existing credential. Defaults to false.',
      },
    },
    required: ['name', 'domains'],
  },
};
