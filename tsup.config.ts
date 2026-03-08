import { defineConfig } from 'tsup';

export default defineConfig([
  // MCP Server entry
  {
    entry: { 'index': 'src/index.ts' },
    format: ['esm'],
    dts: true,
    clean: true,
    sourcemap: true,
    target: 'node20',
    shims: true
  },
  // CLI entry
  {
    entry: { 'cli/index': 'src/cli/index.ts' },
    format: ['esm'],
    dts: true,
    sourcemap: true,
    target: 'node20',
    shims: true,
    banner: {
      js: '#!/usr/bin/env node'
    }
  }
]);
