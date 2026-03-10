import { Command } from 'commander';
import { handleProxyRequest } from '../../tools/proxy-request.js';
import { colors } from '../utils.js';

export const proxyRequestCommand = new Command('proxy-request')
  .description('Make an HTTP request with credential substitution ({{SECRET_NAME}} placeholders)')
  .argument('<url>', 'Request URL')
  .option('-X, --method <method>', 'HTTP method', 'GET')
  .option('-H, --header <headers...>', 'Headers (key:value format)')
  .option('-d, --data <body>', 'Request body')
  .option('--timeout <ms>', 'Timeout in milliseconds', '30000')
  .action(async (url: string, options: { method: string; header?: string[]; data?: string; timeout: string }) => {
    const headers: Record<string, string> = {};
    if (options.header) {
      for (const h of options.header) {
        const colonIdx = h.indexOf(':');
        if (colonIdx === -1) {
          console.error(colors.red(`Invalid header format: "${h}" (expected key:value)`));
          process.exit(1);
        }
        headers[h.slice(0, colonIdx).trim()] = h.slice(colonIdx + 1).trim();
      }
    }

    const method = options.method.toUpperCase() as 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';
    const result = await handleProxyRequest({
      method,
      url,
      headers: Object.keys(headers).length > 0 ? headers : undefined,
      body: options.data,
      timeout: parseInt(options.timeout, 10),
    });

    if ('error' in result) {
      console.error(colors.red(`${result.error}: ${result.message}`));
      if ('hint' in result && result.hint) console.error(colors.dim(result.hint));
      process.exit(1);
    }

    console.log(`${colors.bold(`${result.status}`)} ${result.statusText}`);
    if (result.redacted) {
      console.log(colors.yellow('[response redacted — secret values removed]'));
    }
    console.log(result.body);
  });
