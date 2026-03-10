import { Command } from 'commander';
import { addCommand } from './commands/add.js';
import { listCommand } from './commands/list.js';
import { removeCommand } from './commands/remove.js';
import { rotateCommand } from './commands/rotate.js';
import { testCommand } from './commands/test.js';
import { installCommand } from './commands/install.js';
import { exportKeyCommand } from './commands/export-key.js';
import { showCommand } from './commands/show.js';
import { serveCommand } from './commands/serve.js';
import { exportCommand } from './commands/export.js';
import { importCommand } from './commands/import.js';
import { proxyRequestCommand } from './commands/proxy-request.js';
import { proxyExecCommand } from './commands/proxy-exec.js';

const program = new Command();

program
  .name('credential-proxy')
  .description('Secure credential management for Claude agents')
  .version('1.0.0');

program.addCommand(addCommand);
program.addCommand(listCommand);
program.addCommand(showCommand);
program.addCommand(removeCommand);
program.addCommand(rotateCommand);
program.addCommand(testCommand);
program.addCommand(installCommand);
program.addCommand(exportKeyCommand);
program.addCommand(serveCommand);
program.addCommand(exportCommand);
program.addCommand(importCommand);
program.addCommand(proxyRequestCommand);
program.addCommand(proxyExecCommand);

program.parse();
