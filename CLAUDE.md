# credential-proxy

MCP server for secure credential management. Agents make authenticated HTTP requests and run commands without seeing credential values.

## Build & Test

```bash
npm install        # install dependencies
npm run build      # build with tsup
npm test           # run tests (vitest)
npm run typecheck  # type-check without emitting
```

## Project Structure

- `src/index.ts` — MCP server entry point (stdio transport)
- `src/http-server.ts` — HTTP server alternative (port 8787)
- `src/tools/` — MCP tool handlers: list_credentials, proxy_request, proxy_exec
- `src/storage/` — secrets store, encryption (AES-256-GCM), keyring (master key management)
- `src/utils/` — audit logger, domain matcher, redaction
- `src/cli/` — CLI with 11 commands (add, remove, list, show, rotate, test, install, export, import, export-key, serve)
- `tests/` — vitest tests

## Key Design Decisions

- Master key stored in `~/.local/share/credential-proxy/secrets.key` (file-based by default, macOS Keychain opt-in via `CREDENTIAL_PROXY_USE_KEYCHAIN=1`)
- Multi-instance support via `CREDENTIAL_PROXY_INSTANCE` env var (falls back to `CLAUDETMUX_INSTANCE` for backward compat)
- Data dir override: `CREDENTIAL_PROXY_DATA_DIR`
- Secrets file format is versioned (currently v2) with automatic migration from v1
- 1Password references supported as alternative to direct encryption

## Installation

```bash
npm run build
node dist/cli/index.js install   # copies to ~/.claude/mcp-servers/, registers in ~/.claude.json
```

## Update Procedure

**Before updating, always confirm the user has clicked "Prepare for Update" in the macOS menu bar UI.** This ensures the app is ready to be replaced. Do not proceed without confirmation.

1. Pull latest changes: `git pull`
2. Build and install the MCP server:
   ```bash
   npm run build && node dist/cli/index.js install
   ```
3. Build and install the macOS app:
   ```bash
   cd macos && swift build -c release
   cp .build/release/CredentialProxy ~/Applications/Credential\ Proxy.app/Contents/MacOS/CredentialProxy
   ```
4. Relaunch the macOS app:
   ```bash
   pkill -x CredentialProxy; sleep 1; open ~/Applications/Credential\ Proxy.app
   ```
5. User restarts Claude Code to load the updated MCP server.
