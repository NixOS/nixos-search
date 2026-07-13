#!/usr/bin/env node
// Local static server that mirrors the two `netlify.toml` redirect rules:
//   /backend/* → proxy to bonsai (Elasticsearch)
//   /*         → dist/index.html (SPA fallback)
import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import path from 'node:path';

const DIST = path.resolve(process.argv[2] ?? 'dist');
const BONSAI = 'nixos-search-7-1733963800.us-east-1.bonsaisearch.net';
const PORT = process.env.PORT ?? 8080;

const MIME = new Map([
  ['.html', 'text/html; charset=utf-8'],
  ['.js', 'application/javascript'],
  ['.css', 'text/css'],
  ['.json', 'application/json'],
  ['.svg', 'image/svg+xml'],
  ['.png', 'image/png'],
  ['.ico', 'image/x-icon'],
  ['.woff2', 'font/woff2'],
  ['.woff', 'font/woff'],
  ['.txt', 'text/plain'],
]);

http.createServer((req, res) => {
  const reqUrl = new URL(req.url, `http://localhost:${PORT}`);

  if (reqUrl.pathname.startsWith('/backend/')) {
    const targetPath = reqUrl.pathname.slice('/backend'.length) + reqUrl.search;
    const opts = {
      hostname: BONSAI,
      path: targetPath,
      method: req.method,
      headers: { ...req.headers, host: BONSAI },
    };
    // Avoid compressed responses we'd need to decompress before forwarding.
    delete opts.headers['accept-encoding'];
    const proxy = https.request(opts, (proxyRes) => {
      res.writeHead(proxyRes.statusCode, proxyRes.headers);
      proxyRes.pipe(res, { end: true });
    });
    proxy.on('error', (e) => { res.writeHead(502); res.end(String(e)); });
    req.pipe(proxy, { end: true });
    return;
  }

  let filePath = path.join(DIST, reqUrl.pathname);
  try {
    if (fs.statSync(filePath).isDirectory()) filePath = path.join(filePath, 'index.html');
  } catch {
    filePath = path.join(DIST, 'index.html');
  }
  if (!fs.existsSync(filePath)) filePath = path.join(DIST, 'index.html');

  const ext = path.extname(filePath);
  const headers = { 'Content-Type': MIME.get(ext) ?? 'application/octet-stream' };
  if (ext === '.html' && req.headers['save-data'] === 'on') {
    fs.readFile(filePath, 'utf8', (err, data) => {
      if (err) { res.writeHead(500); res.end(String(err)); return; }
      const rewritten = data.replace('<html', '<html data-save-data="on"');
      res.writeHead(200, headers);
      res.end(rewritten);
    });
    return;
  }
  res.writeHead(200, headers);
  fs.createReadStream(filePath).pipe(res, { end: true });
}).listen(PORT, () => {
  console.log(`Serving ${DIST} at http://localhost:${PORT}`);
  console.log(`Proxying /backend/* → https://${BONSAI}`);
});
