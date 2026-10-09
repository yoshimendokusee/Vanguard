import { defineConfig } from 'vite';

export default defineConfig({
  root: 'public',
  publicDir: false,
  server: {
    host: '0.0.0.0',
    port: 3301,
    strictPort: true,
    ws: { clientPort: 3301 },
    watch: { usePolling: process.env.VITE_USE_POLLING === 'true', interval: 250 },
    proxy: { '/api': process.env.VITE_API_TARGET || 'http://127.0.0.1:3000' },
  },
  build: { outDir: '../dist', emptyOutDir: true },
});
