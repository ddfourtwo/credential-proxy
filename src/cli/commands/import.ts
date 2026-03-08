import { Command } from 'commander';
import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { addSecret, secretExists } from '../../storage/secrets-store.js';
import type { SecretPlacement } from '../../storage/types.js';

interface ExportedSecret {
  name: string;
  value: string;
  allowedDomains: string[];
  allowedPlacements: string[];
}

interface ExportData {
  version: number;
  exportedAt?: string;
  secrets: ExportedSecret[];
}

async function readStdin(): Promise<string> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) {
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString('utf8');
}

export const importCommand = new Command('import')
  .description('Import secrets from a JSON file')
  .argument('[file]', 'Input file path (or use --stdin)')
  .option('--stdin', 'Read from stdin instead of file')
  .option('--overwrite', 'Overwrite existing secrets', false)
  .option('--dry-run', 'Show what would be imported without making changes', false)
  .action(async (file: string | undefined, options) => {
    try {
      let content: string;

      if (options.stdin) {
        content = await readStdin();
      } else if (file) {
        if (!existsSync(file)) {
          console.error(`File not found: ${file}`);
          process.exit(1);
        }
        content = await readFile(file, 'utf8');
      } else {
        console.error('Error: either <file> argument or --stdin is required');
        process.exit(1);
      }
      let data: ExportData;
      
      try {
        data = JSON.parse(content);
      } catch {
        console.error('Invalid JSON file');
        process.exit(1);
      }

      if (!data.secrets || !Array.isArray(data.secrets)) {
        console.error('Invalid export file format: missing secrets array');
        process.exit(1);
      }

      console.log(`Found ${data.secrets.length} secret(s) to import`);
      if (data.exportedAt) {
        console.log(`Exported at: ${data.exportedAt}`);
      }
      console.log('');

      let imported = 0;
      let skipped = 0;
      let overwritten = 0;

      for (const secret of data.secrets) {
        if (!secret.name || !secret.value || !secret.allowedDomains) {
          console.log(`⚠️  Skipping invalid entry (missing required fields)`);
          skipped++;
          continue;
        }

        const exists = await secretExists(secret.name);
        
        if (exists && !options.overwrite) {
          console.log(`⏭️  Skipping ${secret.name} (already exists, use --overwrite to replace)`);
          skipped++;
          continue;
        }

        if (options.dryRun) {
          console.log(`📋 Would ${exists ? 'overwrite' : 'import'}: ${secret.name}`);
          console.log(`   Domains: ${secret.allowedDomains.join(', ')}`);
          console.log(`   Placements: ${(secret.allowedPlacements || ['header']).join(', ')}`);
        } else {
          const placements = (secret.allowedPlacements || ['header']) as SecretPlacement[];
          try {
            await addSecret(secret.name, secret.value, secret.allowedDomains, placements);
            
            if (exists) {
              console.log(`🔄 Overwritten: ${secret.name}`);
              overwritten++;
            } else {
              console.log(`✅ Imported: ${secret.name}`);
              imported++;
            }
          } catch (secretError) {
            console.error(`❌ Failed to import ${secret.name}:`, secretError instanceof Error ? secretError.message : String(secretError));
            skipped++;
          }
        }
      }

      console.log('');
      if (options.dryRun) {
        console.log('Dry run complete - no changes made');
      } else {
        console.log(`Done: ${imported} imported, ${overwritten} overwritten, ${skipped} skipped`);
      }
    } catch (error) {
      console.error('Import failed:', error instanceof Error ? error.message : String(error));
      if (error instanceof Error && error.stack) {
        console.error('Stack trace:', error.stack);
      }
      process.exit(1);
    }
  });
