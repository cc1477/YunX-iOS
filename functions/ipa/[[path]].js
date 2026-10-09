export async function onRequest({ request, params, env, waitUntil }) {
  if (!['GET', 'HEAD'].includes(request.method)) {
    return new Response('Method not allowed', { status: 405, headers: { Allow: 'GET, HEAD' } });
  }
  const [sha, filename, extra] = params.path || [];
  if (!/^[a-f0-9]{64}$/.test(sha || '') || filename !== 'YunX-unsigned.ipa' || extra) {
    return new Response('Not found', { status: 404 });
  }
  const url = new URL(request.url);
  url.search = '';
  const key = new Request(url.href);
  const cached = await caches.default.match(new Request(url.href, { headers: request.headers }));
  if (cached) {
    const response = new Response(request.method === 'HEAD' ? null : cached.body, cached);
    response.headers.set('X-YunX-Cache', 'HIT');
    return response;
  }
  const objectKey = `ipa/yunx/${sha}/${filename}`;
  const object = request.method === 'HEAD' ? await env.IPA_BUCKET.head(objectKey) : await env.IPA_BUCKET.get(objectKey);
  if (!object) return new Response('Not found', { status: 404 });
  const headers = new Headers({
    'Content-Type': 'application/octet-stream',
    'Content-Disposition': 'attachment; filename="YunX-unsigned.ipa"',
    'Content-Length': String(object.size),
    'Cache-Control': 'public, max-age=31536000, immutable',
    'ETag': object.httpEtag,
  });
  // Cloudflare's Cache API handles byte ranges after the full object is cached.
  const response = new Response(request.method === 'HEAD' ? null : object.body, { headers });
  if (request.method === 'GET') waitUntil(caches.default.put(key, response.clone()));
  response.headers.set('X-YunX-Cache', 'MISS');
  return response;
}
