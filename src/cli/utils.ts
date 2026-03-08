import { createInterface } from 'node:readline';
import { stdin, stdout } from 'node:process';

export async function promptPassword(prompt: string): Promise<string> {
  return new Promise((resolve) => {
    const rl = createInterface({
      input: stdin,
      output: stdout
    });

    // Mute output for password input
    process.stdout.write(prompt);
    stdin.setRawMode?.(true);

    let password = '';
    const onData = (char: Buffer) => {
      const c = char.toString();

      if (c === '\n' || c === '\r') {
        stdin.setRawMode?.(false);
        stdin.removeListener('data', onData);
        console.log(); // New line after password
        rl.close();
        resolve(password);
      } else if (c === '\u0003') {
        // Ctrl+C
        stdin.setRawMode?.(false);
        process.exit(1);
      } else if (c === '\u007f') {
        // Backspace
        password = password.slice(0, -1);
      } else {
        password += c;
        process.stdout.write('*');
      }
    };

    stdin.on('data', onData);
    stdin.resume();
  });
}

export async function confirm(message: string): Promise<boolean> {
  const rl = createInterface({
    input: stdin,
    output: stdout
  });

  return new Promise((resolve) => {
    rl.question(`${message} [y/N]: `, (answer) => {
      rl.close();
      resolve(answer.toLowerCase() === 'y' || answer.toLowerCase() === 'yes');
    });
  });
}

export function formatRelativeTime(date: string | null): string {
  if (!date) return 'never';

  const now = Date.now();
  const then = new Date(date).getTime();
  const diffMs = now - then;

  const seconds = Math.floor(diffMs / 1000);
  const minutes = Math.floor(seconds / 60);
  const hours = Math.floor(minutes / 60);
  const days = Math.floor(hours / 24);

  if (days > 0) return `${days}d ago`;
  if (hours > 0) return `${hours}h ago`;
  if (minutes > 0) return `${minutes}m ago`;
  return 'just now';
}

export function formatTable(rows: string[][], headers: string[]): string {
  const allRows = [headers, ...rows];
  const colWidths = headers.map((_, i) =>
    Math.max(...allRows.map(row => (row[i] ?? '').length))
  );

  const formatRow = (row: string[]) =>
    row.map((cell, i) => (cell ?? '').padEnd(colWidths[i])).join('  ');

  return [
    formatRow(headers),
    ...rows.map(formatRow)
  ].join('\n');
}

export const colors = {
  green: (s: string) => `\x1b[32m${s}\x1b[0m`,
  red: (s: string) => `\x1b[31m${s}\x1b[0m`,
  yellow: (s: string) => `\x1b[33m${s}\x1b[0m`,
  dim: (s: string) => `\x1b[2m${s}\x1b[0m`,
  bold: (s: string) => `\x1b[1m${s}\x1b[0m`
};
