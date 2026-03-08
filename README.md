# credential-proxy

An MCP (Model Context Protocol) server that lets AI agents make authenticated API requests and run credentialed commands — without ever seeing the credential values.

Agents reference secrets by name using `{{PLACEHOLDER}}` syntax. The MCP server substitutes real values server-side, enforces domain allowlists, validates placement rules, and redacts any leaked values from responses. The agent never has access to the actual secret.

## How It Works

```
┌─────────────────────────────────────────────────────────────────────┐
│                    SECRET NEVER CROSSES THIS LINE                   │
├─────────────────────────────────────────────────────────────────────┤
│  Agent Context              │      MCP Server (Trusted)             │
│  (Untrusted)                │                                       │
│  • Sees secret NAMES only   │  • Stores encrypted VALUES           │
│  • Uses {{PLACEHOLDER}}     │  • Validates domain allowlist        │
│  • Receives sanitized resp  │  • Executes actual requests          │
│  • Cannot exfiltrate        │  • Redacts leaked values from output │
└─────────────────────────────────────────────────────────────────────┘
```

The agent asks: *"POST to `https://api.linear.app/graphql` with header `Authorization: Bearer {{LINEAR_API_KEY}}`"*

The MCP server:
1. Validates `LINEAR_API_KEY` is allowed for `*.linear.app`
2. Validates the placement (`header`) is permitted
3. Substitutes the real value and executes the request
4. Scans the response for leaked secret values and redacts them
5. Returns the sanitized response to the agent

## Installation

**Requirements:** Node.js >= 20.0.0

```bash
# Clone and build
git clone https://github.com/yourusername/credential-proxy.git
cd credential-proxy
npm install
npm run build

# Install to Claude Code as an MCP server
npx credential-proxy install
```

The `install` command registers the MCP server in `~/.claude.json` and copies the built files to `~/.claude/mcp-servers/credential-proxy/`.

## Quick Start

```bash
# 1. Add a credential with domain restrictions
npx credential-proxy add LINEAR_API_KEY -d "*.linear.app"
# You'll be prompted to enter (and confirm) the secret value

# 2. The agent can now use it via MCP tools:
#    proxy_request({
#      method: "POST",
#      url: "https://api.linear.app/graphql",
#      headers: { "Authorization": "Bearer {{LINEAR_API_KEY}}" },
#      body: { "query": "{ viewer { id name } }" }
#    })
```

## CLI Reference

### `add` — Store a credential

```bash
# Basic: enter value interactively
npx credential-proxy add SECRET_NAME -d "*.example.com"

# With multiple domains and placement types
npx credential-proxy add GITHUB_TOKEN -d "*.github.com,api.github.com" -p "header,env,arg"

# With command restrictions for exec proxy
npx credential-proxy add GIT_TOKEN -d "*.github.com" -p "arg,env" -c "git *"

# Using 1Password instead of local storage
npx credential-proxy add GITHUB_TOKEN --1password "op://Private/GitHub/token" -d "*.github.com"
npx credential-proxy add DEPLOY_KEY --op "op://Work/Deploy Key/password" -d "*.example.com" -p "env,arg"
```

**Options:**

| Flag | Description | Default |
|------|-------------|---------|
| `-d, --domains` | Comma-separated allowed domains (required) | — |
| `-p, --placements` | Where the secret can appear: `header`, `body`, `query`, `env`, `arg` | `header` |
| `-c, --commands` | Allowed command patterns for `proxy_exec` (e.g., `"git *,npm *"`) | any |
| `--1password <ref>` / `--op <ref>` | 1Password reference (e.g., `op://vault/item/field`) | — |

Secret names must be `SCREAMING_SNAKE_CASE` (e.g., `API_KEY`, `GITHUB_TOKEN`).

### `list` — Show configured credentials

```bash
npx credential-proxy list          # human-readable
npx credential-proxy list --json   # JSON output
```

### `remove` — Delete a credential

```bash
npx credential-proxy remove LINEAR_API_KEY
```

### `rotate` — Replace a credential value

```bash
npx credential-proxy rotate LINEAR_API_KEY
# Prompts for a new value; preserves domain/placement config
```

### `test` — Verify a credential is readable

```bash
npx credential-proxy test LINEAR_API_KEY
```

### `export` / `import` — Backup and transfer

```bash
# Export (includes decrypted values!)
npx credential-proxy export ~/secrets-backup.json
npx credential-proxy export --stdout

# Import
npx credential-proxy import ~/secrets-backup.json
npx credential-proxy import ~/secrets-backup.json --dry-run     # preview
npx credential-proxy import ~/secrets-backup.json --overwrite   # replace existing

# Transfer between machines via SSH
credential-proxy export --stdout | ssh dest 'source ~/.zshrc && credential-proxy import --stdin'
ssh source 'source ~/.zshrc && credential-proxy export --stdout' | credential-proxy import --stdin
```

> **Warning:** Export files contain decrypted secrets. Delete them immediately after use.

### `serve` — HTTP server mode

Run as an HTTP server for non-MCP clients:

```bash
credential-proxy serve                    # default: localhost:8787
credential-proxy serve --port 9000        # custom port
credential-proxy serve --host 0.0.0.0     # all interfaces (use with caution)
```

**Endpoints:**

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Health check |
| GET | `/credentials` | List configured credentials |
| POST | `/proxy` | HTTP request with credential substitution |
| POST | `/exec` | Command execution with credential substitution |

## MCP Tool Reference

The MCP server exposes three tools to the agent:

### `list_credentials`

Discover available credentials. Returns names and metadata only — never values.

```json
// Request
list_credentials()

// Response
{
  "secrets": [
    {
      "name": "LINEAR_API_KEY",
      "sourceType": "encrypted",
      "allowedDomains": ["*.linear.app"],
      "allowedPlacements": ["header"],
      "configured": true,
      "usageCount": 42
    },
    {
      "name": "GITHUB_TOKEN",
      "sourceType": "1password",
      "allowedDomains": ["*.github.com"],
      "allowedPlacements": ["header", "env", "arg"],
      "allowedCommands": ["git *"],
      "configured": true,
      "usageCount": 7
    }
  ]
}
```

### `proxy_request`

Make HTTP requests with credential substitution. Use `{{SECRET_NAME}}` placeholders in the URL, headers, or body. The server substitutes real values, executes the request, and returns a sanitized response.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `method` | `GET\|POST\|PUT\|PATCH\|DELETE` | yes | HTTP method |
| `url` | string | yes | Request URL |
| `headers` | object | no | Request headers |
| `body` | string or object | no | Request body |
| `timeout` | number | no | Timeout in ms (default: 30000) |

**Example — Linear GraphQL API:**

```json
// Request
proxy_request({
  "method": "POST",
  "url": "https://api.linear.app/graphql",
  "headers": {
    "Authorization": "Bearer {{LINEAR_API_KEY}}",
    "Content-Type": "application/json"
  },
  "body": {
    "query": "{ issues(first: 10) { nodes { id title state { name } } } }"
  }
})

// Response
{
  "status": 200,
  "statusText": "OK",
  "headers": { "content-type": "application/json" },
  "body": "{\"data\":{\"issues\":{\"nodes\":[...]}}}",
  "redacted": false
}
```

**Example — GitHub REST API:**

```json
proxy_request({
  "method": "GET",
  "url": "https://api.github.com/user/repos?per_page=5",
  "headers": {
    "Authorization": "Bearer {{GITHUB_TOKEN}}",
    "Accept": "application/vnd.github+json"
  }
})
```

**Example — Secret in query parameter:**

```json
proxy_request({
  "method": "GET",
  "url": "https://api.example.com/data?key={{API_KEY}}"
})
```

**Error responses:**

```json
// Domain not allowed
{
  "error": "SECRET_DOMAIN_BLOCKED",
  "message": "Secret 'LINEAR_API_KEY' cannot be used with domain 'evil.com'",
  "allowedDomains": ["*.linear.app"]
}

// Placement not allowed
{
  "error": "SECRET_PLACEMENT_BLOCKED",
  "message": "Secret 'API_KEY' cannot be used in 'body'",
  "allowedPlacements": ["header"]
}

// Secret not configured
{
  "error": "SECRET_NOT_FOUND",
  "message": "Secret 'MISSING_KEY' is not configured",
  "hint": "Use 'credential-proxy add MISSING_KEY' to configure"
}
```

### `proxy_exec`

Execute shell commands with credential substitution. Secrets can be injected into command arguments or environment variables. All secret values are redacted from stdout/stderr before returning to the agent.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `command` | string[] | yes | Command and arguments as array |
| `env` | object | no | Environment variables to set |
| `cwd` | string | no | Working directory |
| `timeout` | number | no | Timeout in ms (default: 30000) |
| `stdin` | string | no | Input to send to stdin |

**Example — Git clone with token in URL:**

```json
proxy_exec({
  "command": ["git", "clone", "https://{{GITHUB_TOKEN}}@github.com/org/private-repo.git"],
  "cwd": "/tmp"
})

// Response
{
  "exitCode": 0,
  "stdout": "Cloning into 'private-repo'...\n",
  "stderr": "",
  "redacted": false,
  "timedOut": false
}
```

**Example — GitHub CLI with token as env var:**

```json
proxy_exec({
  "command": ["gh", "api", "/user"],
  "env": { "GH_TOKEN": "{{GITHUB_TOKEN}}" }
})
```

**Example — npm publish with auth token:**

```json
proxy_exec({
  "command": ["npm", "publish", "--registry", "https://registry.example.com"],
  "env": { "NPM_TOKEN": "{{NPM_AUTH_TOKEN}}" },
  "cwd": "/path/to/package"
})
```

**Security constraints for `proxy_exec`:**
- Secrets must have `arg` or `env` in their `allowedPlacements`
- If `allowedCommands` is set, the full command string must match at least one pattern (glob-style via [minimatch](https://github.com/isaacs/minimatch))
- All secret values are redacted from stdout and stderr before returning

## Security Model

### Encryption at Rest

- Secrets are encrypted with **AES-256-GCM** (authenticated encryption)
- Each secret gets a unique IV and auth tag
- The master encryption key is stored in the **macOS Keychain** (via [keytar](https://github.com/nicedoc/keytar))
- Fallback to file-based key storage (`~/.local/share/credential-proxy/secrets.key`) on systems without a keyring
- Secret files are written with `chmod 600` (owner read/write only)

### Domain Allowlists

Every credential has a list of allowed domains. The server validates the target domain before substituting any secret:

```bash
# This secret can only be sent to Linear's API
npx credential-proxy add LINEAR_API_KEY -d "*.linear.app"

# Wildcards match subdomains: *.github.com matches api.github.com, raw.github.com, etc.
npx credential-proxy add GITHUB_TOKEN -d "*.github.com"
```

If an agent attempts to use a credential with an unauthorized domain, the request is blocked and the attempt is audit-logged.

### Placement Validation

Control exactly where a secret can appear in requests:

- `header` — HTTP headers (default)
- `body` — HTTP request body
- `query` — URL query parameters
- `env` — Environment variables (for `proxy_exec`)
- `arg` — Command-line arguments (for `proxy_exec`)

A secret configured with `-p header` cannot be placed in the request body, even if the domain matches.

### Response Redaction

After every request or command execution, the server scans all output (response body, stdout, stderr) for the actual secret values. Any matches are replaced with `[REDACTED:SECRET_NAME]` before the response reaches the agent.

### Audit Logging

All secret usage is logged to `~/.local/share/credential-proxy/logs/secrets-audit.log`:

```
[2025-12-31T10:00:00Z] SECRET_USED secret=LINEAR_API_KEY domain=api.linear.app method=POST status=200 duration=234ms
[2025-12-31T10:00:05Z] SECRET_BLOCKED secret=LINEAR_API_KEY domain=evil.com reason=DOMAIN_NOT_ALLOWED
```

Logged events include: secret added, secret used (with domain/command, status, duration), secret blocked (with reason), and secret values redacted from output.

### No Plaintext Exposure

The agent never sees credential values at any point:
1. **Storage** — encrypted with AES-256-GCM, key in system keychain
2. **Substitution** — happens server-side in the MCP process
3. **Response** — scanned and redacted before returning to agent
4. **Audit** — logs record usage metadata, never values

## 1Password Integration

Instead of storing encrypted secrets locally, reference secrets stored in 1Password. Values are fetched on-demand via the `op` CLI with a 1-minute cache.

```bash
# Add a 1Password-backed credential
npx credential-proxy add GITHUB_TOKEN \
  --1password "op://Private/GitHub Token/password" \
  -d "*.github.com" -p "header,env,arg"
```

**Requirements:** Install and authenticate the [1Password CLI](https://developer.1password.com/docs/cli/get-started/) (`op signin`).

**Benefits:**
- No local secret storage — values fetched from 1Password on each use
- Automatic rotation — update in 1Password, credential-proxy picks it up
- Short-lived cache (1 minute) balances security and performance

## Configuration & Data Locations

| Path | Purpose |
|------|---------|
| `~/.claude/mcp-servers/credential-proxy/` | MCP server installation |
| `~/.local/share/credential-proxy/secrets.json` | Encrypted secrets store |
| `~/.local/share/credential-proxy/secrets.key` | Encryption key (keyring fallback) |
| `~/.local/share/credential-proxy/logs/secrets-audit.log` | Audit log |

## Development

```bash
npm install
npm run build       # build with tsup
npm run dev         # watch mode
npm run test        # run tests (vitest)
npm run typecheck   # type-check without emitting
npm run lint        # eslint
```

## License

MIT
