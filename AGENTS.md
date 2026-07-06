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
- `src/http-server.ts` — HTTP server alternative (port 11111)
- `src/tools/` — MCP tool handlers: list_credentials, proxy_request, proxy_exec
- `src/storage/` — secrets store, encryption (AES-256-GCM), keyring (master key management)
- `src/utils/` — audit logger, domain matcher, redaction
- `src/cli/` — CLI with 11 commands (add, remove, list, show, rotate, test, install, export, import, export-key, serve)
- `tests/` — vitest tests

## Key Design Decisions

- Seal key derived from user PIN + salt (PBKDF2, 200k iterations) — no binary hash binding
- Secrets stored as AES-256-GCM encrypted `.sealed` files in `~/Library/Application Support/credential-proxy/secrets/`
- Metadata file (`secrets.json`) is HMAC-signed with the seal key to prevent agent tampering
- Daemon mode auto-enabled on unlock (key exported for headless operation)
- App auto-registers MCP server in `~/.claude.json` on first launch
- 1Password references supported as alternative to direct encryption

## Installation

```bash
./install.sh    # builds MCP relay, installs app to /Applications, sets up LaunchAgent
```

Or for end users: download the DMG, drag to Applications, open, set PIN.

## Update

```bash
./update.sh     # pulls latest, replaces binary + MCP relay, relaunches
```

## Building the DMG

```bash
./build-dmg.sh  # creates distributable DMG from installed app
```
