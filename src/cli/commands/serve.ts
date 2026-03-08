import { Command } from 'commander';
import { startHttpServer } from '../../http-server.js';

export const serveCommand = new Command('serve')
  .description('Start HTTP server for credential proxy (allows non-MCP clients)')
  .option('-p, --port <port>', 'Port to listen on', '8787')
  .option('-H, --host <host>', 'Host to bind to', '127.0.0.1')
  .action(async (options) => {
    const port = parseInt(options.port, 10);
    const host = options.host;

    if (isNaN(port) || port < 1 || port > 65535) {
      console.error('Invalid port number');
      process.exit(1);
    }

    try {
      await startHttpServer({ port, host });
      // Keep the process running
      process.on('SIGINT', () => {
        console.log('\nShutting down...');
        process.exit(0);
      });
      process.on('SIGTERM', () => {
        console.log('\nShutting down...');
        process.exit(0);
      });
    } catch (error) {
      console.error('Failed to start server:', error instanceof Error ? error.message : error);
      process.exit(1);
    }
  });
