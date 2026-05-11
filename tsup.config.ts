import { defineConfig } from 'tsup';

export default defineConfig({
  entry: ['src/index.ts'],
  format: ['esm'],
  target: 'node20',
  platform: 'node',
  clean: true,
  shims: true,
  banner: { js: '#!/usr/bin/env node' },
  outDir: 'dist',
});
