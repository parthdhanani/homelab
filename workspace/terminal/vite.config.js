import { defineConfig } from 'vite';
import wasm from 'vite-plugin-wasm';
import topLevelAwait from 'vite-plugin-top-level-await';

export default defineConfig({
  root: 'frontend',
  // Relative asset URLs so the app works both at the tunnel root
  // (term.psidex.com/) and under a proxy prefix (code-server's
  // /proxy/8085/). The default base '/' emitted absolute /assets/... paths,
  // which 404'd under the prefix and left the page stuck on "loading".
  base: './',
  plugins: [wasm(), topLevelAwait()],
  build: {
    outDir: '../dist',
    emptyOutDir: true,
  },
});
