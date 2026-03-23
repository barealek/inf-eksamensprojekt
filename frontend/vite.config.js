import { defineConfig } from 'vite'
import solid from 'vite-plugin-solid'

/** Let the SPA handle navigations to /queues; only proxy API-style requests. */
function bypassQueuesToSpa(req) {
  const accept = req.headers.accept ?? ''
  if (accept.includes('text/html')) {
    return '/index.html'
  }
}

export default defineConfig({
  plugins: [solid()],
  server: {
    proxy: {
      '/auth': { target: 'http://127.0.0.1:8080', changeOrigin: true },
      '/queues': {
        target: 'http://127.0.0.1:8080',
        changeOrigin: true,
        bypass: bypassQueuesToSpa,
      },
      '/health': { target: 'http://127.0.0.1:8080', changeOrigin: true },
    },
  },
})
