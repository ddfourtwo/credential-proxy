import { Command } from 'commander';
import { readFile, writeFile, mkdir, cp, chmod } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { colors } from '../utils.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

export const installCommand = new Command('install')
  .description('Install to ~/.claude/mcp-servers/ and configure Claude')
  .action(async () => {
    try {
      const mcpServersDir = join(homedir(), '.claude', 'mcp-servers', 'credential-proxy');
      const claudeJsonPath = join(homedir(), '.claude.json');

      // Create directory
      if (!existsSync(mcpServersDir)) {
        await mkdir(mcpServersDir, { recursive: true });
        console.log(colors.green(`✓ Created ${mcpServersDir}`));
      }

      // Find the dist directory (relative to the CLI)
      // The CLI is at dist/cli/index.js, so dist is at ..
      const distDir = join(__dirname, '..');
      const sourceIndexPath = join(distDir, 'index.js');

      if (!existsSync(sourceIndexPath)) {
        console.error(colors.red('Error: Could not find dist/index.js. Run "npm run build" first.'));
        process.exit(1);
      }

      // Copy the dist files
      const targetIndexPath = join(mcpServersDir, 'index.js');
      await cp(distDir, mcpServersDir, { recursive: true });
      console.log(colors.green(`✓ Copied server files to ${mcpServersDir}`));

      // Also copy package.json for any node_modules references
      const packageJsonSrc = join(distDir, '..', 'package.json');
      if (existsSync(packageJsonSrc)) {
        await cp(packageJsonSrc, join(mcpServersDir, 'package.json'));
      }

      // Copy node_modules
      const nodeModulesSrc = join(distDir, '..', 'node_modules');
      const nodeModulesDst = join(mcpServersDir, 'node_modules');
      if (existsSync(nodeModulesSrc) && !existsSync(nodeModulesDst)) {
        console.log(colors.dim('Copying node_modules (this may take a moment)...'));
        await cp(nodeModulesSrc, nodeModulesDst, { recursive: true });
        console.log(colors.green(`✓ Copied node_modules`));
      }

      // Update ~/.claude.json
      let claudeConfig: { mcpServers?: Record<string, unknown> } = {};
      if (existsSync(claudeJsonPath)) {
        const content = await readFile(claudeJsonPath, 'utf8');
        claudeConfig = JSON.parse(content);
      }

      claudeConfig.mcpServers = claudeConfig.mcpServers || {};
      claudeConfig.mcpServers['credential-proxy'] = {
        type: 'stdio',
        command: 'node',
        args: [join(mcpServersDir, 'index.js')]
      };

      await writeFile(claudeJsonPath, JSON.stringify(claudeConfig, null, 2));
      console.log(colors.green(`✓ Updated ${claudeJsonPath}`));

      console.log('');
      console.log(colors.green('Installation complete!'));
      console.log(colors.dim('Restart Claude Code to load the credential-proxy MCP server.'));
    } catch (error) {
      console.error(colors.red(`Error: ${error instanceof Error ? error.message : String(error)}`));
      process.exit(1);
    }
  });
