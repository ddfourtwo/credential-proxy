import { Command } from 'commander';
import { writeFile } from 'node:fs/promises';
import { stdin } from 'node:process';
import { cliListSecrets, cliGetSecret } from '../../cli/app-client.js';
import { confirm } from '../utils.js';

interface ExportedSecret {
  name: string;
  value: string;
  allowedDomains: string[];
  allowedPlacements: string[];
  allowedCommands?: string[];
}

interface ExportData {
  version: 1;
  exportedAt: string;
  secrets: ExportedSecret[];
}

export const exportCommand = new Command('export')
  .description('Export all secrets to a JSON file (includes decrypted values - handle with care!)')
  .argument('[file]', 'Output file path (required unless --stdout)')
  .option('--stdout', 'Print to stdout instead of file')
  .action(async (file: string | undefined, options) => {
    if (!file && !options.stdout) {
      console.error('Error: either <file> argument or --stdout is required');
      process.exit(1);
    }

    // Exporting writes every secret in plaintext. Require an interactive human
    // confirmation so an agent running non-interactively cannot silently dump them.
    if (!stdin.isTTY) {
      console.error('Error: export requires an interactive terminal (it exposes decrypted secrets). Refusing in a non-interactive session.');
      process.exit(1);
    }
    if (!await confirm('This will write ALL secrets in DECRYPTED plaintext. Continue?')) {
      console.log('Aborted.');
      return;
    }

    try {
      const secrets = await cliListSecrets();

      if (secrets.length === 0) {
        console.log('No secrets to export.');
        return;
      }

      const exportedSecrets: ExportedSecret[] = [];

      for (const secret of secrets) {
        const value = await cliGetSecret(secret.name);
        if (value) {
          exportedSecrets.push({
            name: secret.name,
            value,
            allowedDomains: secret.allowedDomains,
            allowedPlacements: secret.allowedPlacements,
            ...(secret.allowedCommands?.length && { allowedCommands: secret.allowedCommands }),
          });
        }
      }

      const exportData: ExportData = {
        version: 1,
        exportedAt: new Date().toISOString(),
        secrets: exportedSecrets,
      };

      const json = JSON.stringify(exportData, null, 2);

      if (options.stdout) {
        console.log(json);
      } else {
        await writeFile(file!, json, { mode: 0o600 });
        console.log(`✅ Exported ${exportedSecrets.length} secret(s) to ${file}`);
        console.log('⚠️  This file contains decrypted secrets - store securely and delete after use!');
      }
    } catch (error) {
      console.error('Export failed:', error instanceof Error ? error.message : error);
      process.exit(1);
    }
  });
