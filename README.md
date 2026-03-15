# credential-proxy

An MCP (Model Context Protocol) server that lets AI agents make authenticated API requests and run credentialed commands — without ever seeing the credential values.

The credential handling runs in a **compiled Swift binary** embedded in a macOS app. The agent communicates through a thin Node.js MCP relay that forwards tool calls to the native HTTP server. Since the agent can modify JavaScript but not compiled Swift, the security boundary is enforced at the binary level.

## How It Works

```
┌─────────────────────────────────────────────────────────────────────┐
│                    SECRET NEVER CROSSES THIS LINE                   │
├─────────────────────────────────────────────────────────────────────┤
│  Agent Context              │      Native Swift Server (Compiled)   │
│  (Untrusted)                │                                       │
│  • Sees secret NAMES only   │  • Stores values in macOS Keychain   │
│  • Uses {{PLACEHOLDER}}     │  • Validates domain allowlist        │
│  • Receives sanitized resp  │  • Executes actual requests          │
│  • Cannot exfiltrate        │  • Redacts leaked values from output │
└─────────────────────────────────────────────────────────────────────┘
```

```
Claude Code → MCP stdio relay (Node.js, thin) → HTTP :11111 (Swift, compiled) → Keychain
```

The agent asks: *"POST to `https://api.linear.app/graphql` with header `Authorization: Bearer {{LINEAR_API_KEY}}`"*

The server:
1. Validates `LINEAR_API_KEY` is allowed for `*.linear.app`
2. Validates the placement (`header`) is permitted
3. Retrieves the value from macOS Keychain and substitutes it
4. Executes the request
5. Scans the response for leaked secret values and redacts them
6. Returns the sanitized response to the agent

## Installation

**Requirements:** macOS 13+, Node.js 20+, Swift (Xcode Command Line Tools)

```bash
git clone https://github.com/ddfourtwo/credential-proxy.git
cd credential-proxy
bash install.sh
```

The installer:
1. Builds the MCP relay (Node.js stdio → HTTP bridge)
2. Builds the native macOS app (Swift HTTP server)
3. Creates `~/Applications/Credential Proxy.app`
4. Registers the MCP server in `~/.claude.json`
5. Sets up a LaunchAgent (auto-starts at login)
6. Launches the app

Restart Claude Code after install to load the MCP server.

### Updating

```bash
# 1. Click "Prepare for Update" in the menu bar (required — script blocks without it)
# 2. Run:
./reinstall.sh
# 3. Enter your PIN in the menu bar to complete migration
# 4. Restart Claude Code
```

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

# Import
npx credential-proxy import ~/secrets-backup.json
npx credential-proxy import ~/secrets-backup.json --overwrite   # replace existing

# Transfer between machines via SSH
credential-proxy export --stdout | ssh dest 'credential-proxy import --stdin'
```

> **Warning:** Export files contain decrypted secrets. Delete them immediately after use.

## MCP Tool Reference

The MCP server exposes three tools to the agent:

### `list_credentials`

Discover available credentials. Returns names and metadata only — never values.

```json
// Response
{
  "secrets": [
    {
      "name": "LINEAR_API_KEY",
      "sourceType": "keychain",
      "allowedDomains": ["*.linear.app"],
      "allowedPlacements": ["header"],
      "configured": true,
      "usageCount": 42
    }
  ]
}
```

### `proxy_request`

Make HTTP requests with credential substitution. Use `{{SECRET_NAME}}` placeholders in the URL, headers, or body.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `method` | `GET\|POST\|PUT\|PATCH\|DELETE` | yes | HTTP method |
| `url` | string | yes | Request URL |
| `headers` | object | no | Request headers |
| `body` | string or object | no | Request body |
| `timeout` | number | no | Timeout in ms (default: 30000) |

**Example — Linear GraphQL API:**

```json
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
```

**Example — GitHub REST API:**

```json
proxy_request({
  "method": "GET",
  "url": "https://api.github.com/user/repos?per_page=5",
  "headers": {
    "Authorization": "Bearer {{GITHUB_TOKEN}}"
  }
})
```

**Error responses:**

```json
// Domain not allowed
{ "error": "SECRET_DOMAIN_BLOCKED", "message": "Secret 'KEY' cannot be used with domain 'evil.com'" }

// Placement not allowed
{ "error": "SECRET_PLACEMENT_BLOCKED", "message": "Secret 'KEY' cannot be used in 'body'" }

// Secret not configured
{ "error": "SECRET_NOT_FOUND", "message": "Secret 'MISSING' is not configured" }
```

### `proxy_exec`

Execute shell commands with credential substitution. Secrets can be injected into command arguments or environment variables.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `command` | string[] | yes | Command and arguments as array |
| `env` | object | no | Environment variables to set |
| `cwd` | string | no | Working directory |
| `timeout` | number | no | Timeout in ms (default: 30000) |
| `stdin` | string | no | Input to send to stdin |

**Example — Git clone with token:**

```json
proxy_exec({
  "command": ["git", "clone", "https://{{GITHUB_TOKEN}}@github.com/org/private-repo.git"]
})
```

**Example — GitHub CLI with env var:**

```json
proxy_exec({
  "command": ["gh", "api", "/user"],
  "env": { "GH_TOKEN": "{{GITHUB_TOKEN}}" }
})
```

## Architecture

### Security Model

- **Secret storage** — values in macOS Keychain (via Security.framework), metadata in JSON
- **Compiled server** — HTTP server is a Swift binary; agents cannot modify it
- **Domain allowlists** — each secret specifies which domains it can be sent to. Wildcards supported (`*.github.com`)
- **Placement validation** — control whether a secret can appear in headers, body, query params, env vars, or command args
- **Response redaction** — all output scanned for secret values (>= 6 chars) and replaced with `[REDACTED:SECRET_NAME]`
- **Audit logging** — all usage logged to `~/Library/Application Support/credential-proxy/audit.log` with rotation at 10MB
- **Localhost only** — HTTP server binds to `127.0.0.1:11111`, not accessible from the network

### 1Password Integration

Reference secrets stored in 1Password instead of macOS Keychain. Values are fetched on-demand via the `op` CLI.

```bash
npx credential-proxy add GITHUB_TOKEN \
  --1password "op://Private/GitHub Token/password" \
  -d "*.github.com"
```

Requires the [1Password CLI](https://developer.1password.com/docs/cli/get-started/).

## Data Locations

| Path | Purpose |
|------|---------|
| `~/Applications/Credential Proxy.app` | macOS app (Swift HTTP server + MCP relay) |
| `~/Library/Application Support/credential-proxy/secrets.json` | Secret metadata (names, domains, placements) |
| `~/Library/Application Support/credential-proxy/audit.log` | Audit log |
| (in-memory only) | Management auth token (ephemeral, never written to disk) |
| macOS Keychain (`com.credential-proxy.secrets`) | Secret values |
| `~/.claude.json` | MCP server registration |
| `~/Library/LaunchAgents/com.credential-proxy.app.plist` | Auto-start at login |

## Development

```bash
npm install
npm run build       # build MCP relay with tsup
npm run dev         # watch mode
npm run test        # run tests (vitest)

# Build the Swift server
cd macos && swift build -c release

# Fresh install (builds everything + creates app bundle)
bash install.sh

# Update existing installation (requires "Prepare for Update" in menu bar)
./reinstall.sh
```

## License

MIT
