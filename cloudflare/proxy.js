// 分发站 Worker（从 main 分支部署时使用）：
// - 页面、图标等静态文件直接由 Cloudflare CDN 返回（site/ 目录）；
// - builds.json / source.json / IPA 由 CI 生成在 site-dist 分支，这里回源取回：
//   JSON 把 __BASE__/ 占位符换成访问域名，IPA 按内容哈希路径在边缘永久缓存。
const ORIGIN = 'https://raw.githubusercontent.com/cc1477/YunX-iOS/site-dist/public';
const JSON_PATHS = new Set(['/builds.json', '/source.json']);

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;
    const isIpa = /^\/ipa\/[0-9a-f]{16}\/[\w.-]+\.ipa$/.test(path);
    if (!isIpa && !JSON_PATHS.has(path)) return env.ASSETS.fetch(request);
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      return new Response('Method not allowed', { status: 405, headers: { Allow: 'GET, HEAD' } });
    }

    if (!isIpa) {
      const upstream = await fetch(ORIGIN + path, { cf: { cacheTtl: 60, cacheEverything: true } });
      if (!upstream.ok) return new Response('Not found', { status: 404 });
      const text = (await upstream.text()).replaceAll('__BASE__/', url.origin + '/');
      return new Response(request.method === 'HEAD' ? null : text, {
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
          'Cache-Control': 'no-cache',
          'Access-Control-Allow-Origin': '*',
        },
      });
    }

    const cache = caches.default;
    const key = new Request(url.origin + path);
    let response = await cache.match(key);
    if (!response) {
      const upstream = await fetch(ORIGIN + path);
      if (!upstream.ok) return new Response('Not found', { status: 404 });
      const headers = new Headers({
        'Content-Type': 'application/octet-stream',
        'Content-Disposition': `attachment; filename="${path.split('/').pop()}"`,
        'Cache-Control': 'public, max-age=31536000, immutable',
        'Access-Control-Allow-Origin': '*',
      });
      const length = upstream.headers.get('content-length');
      if (length) headers.set('Content-Length', length);
      response = new Response(upstream.body, { headers });
      ctx.waitUntil(cache.put(key, response.clone()));
      response.headers.set('X-YunX-Cache', 'MISS');
    } else {
      response = new Response(response.body, response);
      response.headers.set('X-YunX-Cache', 'HIT');
    }
    return request.method === 'HEAD' ? new Response(null, response) : response;
  },
};
