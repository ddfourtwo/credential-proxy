import { Command } from 'commander';
import { readFile, writeFile, mkdir, cp, chmod, symlink, unlink, rm } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { execSync } from 'node:child_process';
import { colors } from '../utils.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

const INSTALL_DIR = join(homedir(), '.claude', 'mcp-servers', 'credential-proxy');
const DATA_DIR = join(homedir(), '.local', 'share', 'credential-proxy');
const BIN_DIR = join(homedir(), '.local', 'bin');
const CLI_LINK = join(BIN_DIR, 'credential-proxy');
const CLAUDE_JSON = join(homedir(), '.claude.json');

function isGitRepo(dir: string): boolean {
  return existsSync(join(dir, '.git'));
}

export const installCommand = new Command('install')
  .description('Install to ~/.claude/mcp-servers/ and configure Claude')
  .option('--skip-build', 'Skip building from source')
  .action(async (opts: { skipBuild?: boolean }) => {
    try {
      // The CLI is at dist/cli/index.js, so repo root is ../..
      const repoRoot = join(__dirname, '..', '..');
      const distDir = join(__dirname, '..');
      const sourceIndexPath = join(distDir, 'index.js');

      // Step 1: Build from source if running from git clone
      if (!opts.skipBuild && isGitRepo(repoRoot)) {
        console.log(colors.dim('Building from source...'));

        // Ensure dependencies are installed
        if (!existsSync(join(repoRoot, 'node_modules'))) {
          console.log(colors.dim('Installing dependencies...'));
          execSync('npm install', { cwd: repoRoot, stdio: 'inherit' });
        }

        execSync('npm run build', { cwd: repoRoot, stdio: 'inherit' });
        console.log(colors.green('✓ Build completed'));
      }

      if (!existsSync(sourceIndexPath)) {
        console.error(colors.red('Error: Could not find dist/index.js. Run "npm run build" first.'));
        process.exit(1);
      }

      // Step 2: Create install directory and copy dist files
      if (existsSync(INSTALL_DIR)) {
        // Clean old installation but preserve nothing (data is in DATA_DIR)
        await rm(INSTALL_DIR, { recursive: true });
      }
      await mkdir(INSTALL_DIR, { recursive: true });

      await cp(distDir, INSTALL_DIR, { recursive: true });
      console.log(colors.green(`✓ Copied server files to ${INSTALL_DIR}`));

      // Copy package.json for runtime references
      const packageJsonSrc = join(repoRoot, 'package.json');
      if (existsSync(packageJsonSrc)) {
        await cp(packageJsonSrc, join(INSTALL_DIR, 'package.json'));
      }

      // Step 3: Copy production-only node_modules
      console.log(colors.dim('Installing production dependencies...'));
      // Copy package.json and package-lock.json to install dir, then npm ci --omit=dev
      const lockfileSrc = join(repoRoot, 'package-lock.json');
      if (existsSync(lockfileSrc)) {
        await cp(lockfileSrc, join(INSTALL_DIR, 'package-lock.json'));
      }
      execSync('npm ci --omit=dev', { cwd: INSTALL_DIR, stdio: 'inherit' });
      console.log(colors.green('✓ Production dependencies installed'));

      // Step 4: Register in ~/.claude.json
      let claudeConfig: Record<string, unknown> = {};
      if (existsSync(CLAUDE_JSON)) {
        const content = await readFile(CLAUDE_JSON, 'utf8');
        claudeConfig = JSON.parse(content);
      }

      const mcpServers = (claudeConfig.mcpServers ?? {}) as Record<string, unknown>;
      mcpServers['credential-proxy'] = {
        type: 'stdio',
        command: 'node',
        args: [join(INSTALL_DIR, 'index.js')]
      };
      claudeConfig.mcpServers = mcpServers;

      await writeFile(CLAUDE_JSON, JSON.stringify(claudeConfig, null, 2));
      console.log(colors.green(`✓ Updated ${CLAUDE_JSON}`));

      // Step 5: Symlink CLI to ~/.local/bin/credential-proxy
      await mkdir(BIN_DIR, { recursive: true });
      const cliTarget = join(INSTALL_DIR, 'cli', 'index.js');

      // Create a shell wrapper (symlink to .js won't be executable without node)
      const wrapperContent = `#!/bin/bash\nnode "${cliTarget}" "$@"\n`;
      if (existsSync(CLI_LINK)) {
        await unlink(CLI_LINK);
      }
      await writeFile(CLI_LINK, wrapperContent);
      await chmod(CLI_LINK, 0o755);
      console.log(colors.green(`✓ CLI installed: ${CLI_LINK}`));

      // Step 6: Create data directory with restricted permissions
      if (!existsSync(DATA_DIR)) {
        await mkdir(DATA_DIR, { recursive: true });
        await chmod(DATA_DIR, 0o700);
        console.log(colors.green(`✓ Created data directory: ${DATA_DIR}`));
      } else {
        console.log(colors.dim('Data directory already exists (credentials preserved)'));
      }

      console.log('');
      console.log(colors.green('Installation complete!'));
      console.log(colors.dim('Restart Claude Code to load the credential-proxy MCP server.'));
    } catch (error) {
      console.error(colors.red(`Error: ${error instanceof Error ? error.message : String(error)}`));
      process.exit(1);
    }
  });
