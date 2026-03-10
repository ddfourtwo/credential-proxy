import { Command } from 'commander';
import { handleProxyExec } from '../../tools/proxy-exec.js';
import { colors } from '../utils.js';

export const proxyExecCommand = new Command('proxy-exec')
  .description('Execute a command with credential substitution ({{SECRET_NAME}} placeholders)')
  .argument('<cmd...>', 'Command and arguments')
  .option('-e, --env <vars...>', 'Environment variables (KEY=value format)')
  .option('--cwd <dir>', 'Working directory')
  .option('--timeout <ms>', 'Timeout in milliseconds', '30000')
  .option('--stdin <input>', 'Input to send to stdin')
  .action(async (cmd: string[], options: { env?: string[]; cwd?: string; timeout: string; stdin?: string }) => {
    const env: Record<string, string> = {};
    if (options.env) {
      for (const e of options.env) {
        const eqIdx = e.indexOf('=');
        if (eqIdx === -1) {
          console.error(colors.red(`Invalid env format: "${e}" (expected KEY=value)`));
          process.exit(1);
        }
        env[e.slice(0, eqIdx)] = e.slice(eqIdx + 1);
      }
    }

    const result = await handleProxyExec({
      command: cmd,
      env: Object.keys(env).length > 0 ? env : undefined,
      cwd: options.cwd,
      timeout: parseInt(options.timeout, 10),
      stdin: options.stdin,
    });

    if ('error' in result) {
      console.error(colors.red(`${result.error}: ${result.message}`));
      if ('hint' in result && result.hint) console.error(colors.dim(result.hint));
      process.exit(1);
    }

    if (result.redacted) {
      console.error(colors.yellow('[output redacted — secret values removed]'));
    }
    if (result.timedOut) {
      console.error(colors.yellow('[command timed out]'));
    }
    if (result.stdout) process.stdout.write(result.stdout);
    if (result.stderr) process.stderr.write(result.stderr);
    process.exit(result.exitCode);
  });
