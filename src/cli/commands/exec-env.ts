import { Command } from 'commander';
import { spawn } from 'node:child_process';
import { getSecret, secretExists } from '../../storage/secrets-store.js';
import { colors } from '../utils.js';

/**
 * exec-env resolves named secrets into environment variables and then runs a
 * command with those variables set, inheriting stdio so the child owns the TTY.
 *
 * Unlike `proxy-exec`, it does NOT capture/redact output and has no timeout — it
 * is meant for long-lived, interactive processes (e.g. an agent session in a
 * tmux pane). The secret value is never printed; it lives only in the child
 * process's environment. The parent is a thin shim that forwards signals and
 * exits with the child's status.
 */
function collectSecret(value: string, previous: string[]): string[] {
  previous.push(value);
  return previous;
}

export const execEnvCommand = new Command('exec-env')
  .description(
    'Resolve secrets into env vars, then exec a command with them set (stdio inherited, no capture/redaction/timeout). Use for long-lived/interactive processes. Pass the command after "--".'
  )
  .requiredOption(
    '-s, --secret <ENV=name>',
    'Set env var ENV to the resolved value of secret "name" (repeatable)',
    collectSecret,
    []
  )
  .argument('<cmd...>', 'Command and arguments to run (place after "--")')
  .action(async (cmd: string[], options: { secret: string[] }) => {
    if (!cmd || cmd.length === 0) {
      console.error(colors.red('exec-env: no command given'));
      process.exit(1);
    }

    const env: Record<string, string> = { ...process.env } as Record<string, string>;
    for (const assignment of options.secret) {
      const eq = assignment.indexOf('=');
      if (eq <= 0) {
        console.error(colors.red(`exec-env: invalid --secret "${assignment}" (expected ENV=secret-name)`));
        process.exit(1);
      }
      const envVar = assignment.slice(0, eq);
      const secretName = assignment.slice(eq + 1);
      if (!secretName) {
        console.error(colors.red(`exec-env: empty secret name for "${envVar}"`));
        process.exit(1);
      }
      if (!(await secretExists(secretName))) {
        console.error(colors.red(`exec-env: secret "${secretName}" not found`));
        process.exit(1);
      }
      const value = await getSecret(secretName);
      if (!value) {
        console.error(colors.red(`exec-env: could not resolve secret "${secretName}"`));
        process.exit(1);
      }
      env[envVar] = value;
    }

    const child = spawn(cmd[0], cmd.slice(1), { stdio: 'inherit', env });

    const signals: NodeJS.Signals[] = ['SIGINT', 'SIGTERM', 'SIGHUP', 'SIGQUIT'];
    for (const sig of signals) {
      process.on(sig, () => {
        try {
          child.kill(sig);
        } catch {
          // child already gone
        }
      });
    }

    child.on('error', (err: NodeJS.ErrnoException) => {
      console.error(colors.red(`exec-env: failed to launch "${cmd[0]}": ${err.message}`));
      process.exit(err.code === 'ENOENT' ? 127 : 126);
    });

    child.on('exit', (code, signal) => {
      if (signal) {
        // Re-raise so the parent's exit reflects the child's terminating signal.
        process.kill(process.pid, signal);
        return;
      }
      process.exit(code ?? 0);
    });
  });
