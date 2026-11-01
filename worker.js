// 分发站 Worker：静态资源由 Cloudflare 全球 CDN 直接返回；
// builds.json / source.json 里的 __BASE__/ 占位符在这里替换成访问时的域名，
// 所以 workers.dev 和绑定的自定义域名都能拿到正确的绝对下载地址。
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const response = await env.ASSETS.fetch(request);
    if (url.pathname !== '/source.json' && url.pathname !== '/builds.json') return response;
    const text = (await response.text()).replaceAll('__BASE__/', url.origin + '/');
    const headers = new Headers(response.headers);
    headers.delete('content-length');
    headers.delete('etag');
    return new Response(text, { status: response.status, headers });
  },
};
