// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import 'dart:async';
import 'dart:collection';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../http.dart';
import '../json.dart';
import '../models.dart';
import '../text.dart';
import 'video_http.dart';

/// 抖音：
/// 1. 先走 SSR：注册 ttwid → iesdouyin 分享页 `window._ROUTER_DATA` → 视频再探测 aweme play 接口最高清晰度；
/// 2. SSR 拿不到时，用无界面 WebView 打开网页版，拦截 aweme/detail 响应兜底。
class DouyinParser extends VideoParser {
  @override
  VideoPlatform get platform => VideoPlatform.douyin;

  static String? _ttwid;
  static const _ratios = ['1080p', '720p', '540p', '360p'];

  String _type(DetectedVideoLink link) =>
      RX.first(r'/(?:share/)?(video|note|slides)/', link.url) == 'note' ? 'note' : 'video';

  @override
  Future<VideoParseResult> parse(DetectedVideoLink link, String cookie) async {
    Object? ssrError;
    try {
      final r = await _ssr(link, cookie);
      if (r.medias.isNotEmpty) return r;
    } catch (e) {
      ssrError = e;
    }
    final web = await _webView(link);
    if (web != null) return web;
    if (ssrError != null) throw ssrError;
    throw VideoParseError(VideoErrorKind.unknown, '抖音没有返回该作品的媒体地址');
  }

  Future<VideoParseResult> _ssr(DetectedVideoLink link, String cookie) async {
    final shareUrl = 'https://www.iesdouyin.com/share/${_type(link)}/${link.id}/';
    final ttwid = await _getTtwid();
    final html = await VHttp.text(shareUrl,
        headers: {
          'User-Agent': UA.iPhone,
          'Referer': 'https://www.iesdouyin.com/',
          'Cookie': cookie.isEmpty ? ttwid : '$ttwid; $cookie',
        },
        what: '抖音分享页');
    final raw = VHttp.inlineJson(html, 'window._ROUTER_DATA');
    final router = raw == null ? null : J.tryParse(raw);
    if (router == null) {
      _ttwid = null;
      throw VideoParseError(VideoErrorKind.unknown, '抖音分享页里没有作品数据（作品可能已删除或页面改版）');
    }
    final loader = router['loaderData'];
    final page = loader['video_(id)/page'].isMap ? loader['video_(id)/page'] : loader['note_(id)/page'];
    final item = page.first(['videoInfoRes', 'video_info_res']).first(['item_list', 'itemList'])[0];
    if (!item.isMap) throw VideoParseError(VideoErrorKind.unknown, '抖音没有返回该作品的数据（可能已删除、不可见或被风控）');

    final headers = {'User-Agent': UA.iPhone, 'Referer': shareUrl};
    final title = item['desc'].s;
    final base = fileBase(title, 'douyin_${link.id}');
    final medias = <VideoMedia>[];
    var cover = '';
    final images = item['images'].list;
    if (images.isNotEmpty) {
      for (var i = 0; i < images.length; i++) {
        final url = _firstUrl(images[i]);
        if (url == null) continue;
        if (cover.isEmpty) cover = url;
        medias.add(VideoMedia(url: url, kind: MediaKind.image, fileName: '${base}_${i + 1}.jpg', headers: headers, quality: '原图'));
      }
    } else if (item['video'].isMap) {
      final video = item['video'];
      cover = _firstUrl(video['cover']) ?? '';
      final resolved = await _resolveVideo(video.first(['play_addr', 'playAddr']), headers);
      if (resolved != null) {
        medias.add(VideoMedia(url: resolved.$1, kind: MediaKind.video, fileName: '$base.mp4', size: resolved.$2, headers: headers));
      }
    }
    final author = item['author'];
    return VideoParseResult(
      platform: platform,
      title: title,
      author: author['nickname'].s,
      avatar: _firstUrl(author.first(['avatar_thumb', 'avatar_medium'])) ?? '',
      cover: cover,
      timestamp: item.first(['create_time', 'createTime']).i,
      url: link.url,
      medias: medias,
    );
  }

  String? _firstUrl(J node) {
    for (final u in node.first(['url_list', 'urlList']).list) {
      if (u.s.isNotEmpty) return u.s;
    }
    return null;
  }

  /// 用 video_id 逐档探测 play 接口，取体积最大的一档；都失败退回去水印的 playwm 地址
  Future<(String, int)?> _resolveVideo(J playAddr, Map<String, String> headers) async {
    var token = playAddr['uri'].s;
    if (token.isEmpty) {
      for (final u in playAddr.first(['url_list', 'urlList']).list) {
        final id = RX.first(r'[?&]video_id=([^&\s]+)', u.s);
        if (id != null) {
          token = id;
          break;
        }
      }
    }
    if (token.isNotEmpty) {
      (String, int)? best;
      for (final ratio in _ratios) {
        try {
          final url = 'https://aweme.snssdk.com/aweme/v1/play/?video_id=$token&ratio=$ratio';
          final r = await VHttp.request(url, headers: {...headers, 'Range': 'bytes=0-1'});
          if (!r.ok) continue;
          final range = r.header('content-range');
          final size = range != null
              ? int.tryParse(RX.first(r'/(\d+)\s*$', range) ?? '') ?? 0
              : int.tryParse(r.header('content-length') ?? '') ?? 0;
          if (size <= 0) continue;
          if (best == null || size > best.$2) best = (r.finalUrl.toString(), size);
        } catch (_) {}
      }
      if (best != null) return best;
    }
    final fallback = _firstUrl(playAddr)?.replaceAll('playwm', 'play');
    return fallback == null ? null : (fallback, -1);
  }

  static Future<String> _getTtwid() async {
    if (_ttwid != null) return _ttwid!;
    const headers = {'User-Agent': UA.iPhone, 'Referer': 'https://www.iesdouyin.com/'};
    final RawResponse r;
    try {
      r = await Http.postJson('https://ttwid.bytedance.com/ttwid/union/register/', {
        'region': 'cn',
        'aid': 1768,
        'needFid': false,
        'service': 'www.iesdouyin.com',
        'union': true,
        'fid': '',
      }, headers: headers);
    } catch (_) {
      throw VideoParseError(VideoErrorKind.network, 'ttwid 注册请求失败');
    }
    if (!r.ok) throw VideoParseError(VideoErrorKind.unknown, 'ttwid 注册失败（HTTP ${r.status}）');
    final redirect = J.tryParse(r.text)?['redirect_url'].s ?? '';
    if (redirect.isNotEmpty) {
      try {
        final cb = await Http.send(redirect, headers: headers, followRedirects: false);
        final v = cb.cookies['ttwid'];
        if (v != null && v.isNotEmpty) return _ttwid = 'ttwid=$v';
      } catch (_) {}
    }
    final v = r.cookies['ttwid'];
    if (v != null && v.isNotEmpty) return _ttwid = 'ttwid=$v';
    throw VideoParseError(VideoErrorKind.unknown, 'ttwid 注册未返回可用 Cookie');
  }

  // MARK: WebView 兜底

  Future<VideoParseResult?> _webView(DetectedVideoLink link) async {
    final text = await HeadlessExtractor.run(
      url: 'https://www.douyin.com/${_type(link)}/${link.id}',
      userAgent: UA.chrome,
      readyJs: _readyJs,
      extractJs: _extractJs,
      startScripts: const [_hookJs],
    );
    final payload = text == null ? null : J.tryParse(text);
    if (payload == null || payload['error'].s.isNotEmpty) return null;
    final images = payload['images'].list.map((e) => e.s).where((e) => e.isNotEmpty).toList();
    final motions = payload['motions'].list.map((e) => e.s).toList();
    final video = payload['video'].s;
    if (images.isEmpty && video.isEmpty) return null;
    const headers = {'User-Agent': UA.iPhone, 'Referer': 'https://www.douyin.com/'};
    final title = payload['title'].s;
    final base = fileBase(title, 'douyin_${link.id}');
    final medias = <VideoMedia>[];
    if (images.isNotEmpty) {
      for (var i = 0; i < images.length; i++) {
        final motion = i < motions.length ? motions[i] : '';
        medias.add(VideoMedia(
            url: images[i],
            kind: MediaKind.image,
            fileName: '${base}_${i + 1}.jpg',
            headers: headers,
            quality: motion.isEmpty ? '' : '动图',
            motionUrl: motion));
      }
    } else {
      medias.add(VideoMedia(url: video, kind: MediaKind.video, fileName: '$base.mp4', headers: headers));
    }
    return VideoParseResult(
      platform: platform,
      title: title,
      author: payload['author'].s,
      cover: payload['cover'].s.ifEmpty(images.isEmpty ? '' : images.first),
      url: link.url,
      medias: medias,
    );
  }

  static const _hookJs = r'''
(function () {
  try {
    if (window.__yunxHook) return; window.__yunxHook = true;
    var open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (m, u) { this.__u = String(u || ''); return open.apply(this, arguments); };
    XMLHttpRequest.prototype.send = function () {
      var x = this;
      x.addEventListener('load', function () {
        try {
          if ((x.__u || '').indexOf('aweme/v1/web/aweme/detail') < 0 || x.status !== 200) return;
          var t = x.responseText || '';
          if (t) window.__yunxAwemeDetail = t;
        } catch (e) {}
      });
      return send.apply(this, arguments);
    };
  } catch (e) {}
})();
''';

  static const _readyJs = r'''
(function () {
  if (typeof window.__yunxAwemeDetail === 'string' && window.__yunxAwemeDetail.length) return 'true';
  var imgs = document.querySelectorAll('img');
  for (var i = 0; i < imgs.length; i++) {
    var s = imgs[i].src || '';
    if (s.indexOf('douyinpic.com') >= 0 && s.indexOf('WEBPC_RELATED') < 0 &&
        (s.indexOf('biz_tag=aweme_images') >= 0 || s.indexOf('tplv-dy-aweme-images') >= 0)) return 'true';
  }
  return 'false';
})()
''';

  static const _extractJs = r'''
(function () {
  try {
    function first(n) { if (!n) return ''; var l = n.url_list || n.urlList; return (l && l.length) ? String(l[0] || '') : ''; }
    function motion(it) {
      var v = it && it.video; if (!v) return '';
      return first(v.playAddr) || first(v.play_addr) || first(v.play_addr_h264) || first(v.download_addr) || '';
    }
    var hooked = null;
    try {
      var r = JSON.parse(window.__yunxAwemeDetail || 'null');
      hooked = r && (r.aweme_detail || r.awemeDetail || (r.data && r.data.aweme_detail));
    } catch (e) {}
    var ssr = null;
    try {
      var node = document.querySelector('#RENDER_DATA');
      if (node) { var app = JSON.parse(decodeURIComponent(node.textContent)).app; ssr = app && app.videoDetail; }
    } catch (e) {}
    var d = hooked || ssr;
    var list = (ssr && ssr.images) || (hooked && hooked.images) ||
               (hooked && hooked.image_post_info && hooked.image_post_info.images) || [];
    var images = [], motions = [];
    for (var i = 0; i < list.length; i++) {
      var u = first(list[i]) || first(list[i].display_image) || first(list[i].owner_watermark_image);
      if (u) { images.push(u); motions.push(motion(list[i])); }
    }
    if (!images.length) {
      var all = document.querySelectorAll('img');
      for (var j = 0; j < all.length; j++) {
        var s = all[j].src || '';
        if (s.indexOf('douyinpic') >= 0 && s.indexOf('WEBPC_RELATED') < 0 &&
            (s.indexOf('biz_tag=aweme_images') >= 0 || s.indexOf('tplv-dy-aweme-images') >= 0) &&
            images.indexOf(s) < 0) { images.push(s); motions.push(''); }
      }
    }
    var v = (hooked && hooked.video) || (ssr && ssr.video) || null, video = '';
    if (v) {
      video = first(v.play_addr) || first(v.playAddr) || first(v.play_addr_h264);
      if (!video && v.bit_rate) for (var k = 0; k < v.bit_rate.length; k++) { video = first(v.bit_rate[k].play_addr); if (video) break; }
      video = video.replace('/playwm/', '/play/');
    }
    var author = (d && d.author && (d.author.nickname || d.author.unique_id)) ||
                 (d && d.authorInfo && (d.authorInfo.nickname || d.authorInfo.nickName)) || '';
    var title = (d && d.desc) || (document.title || '').replace(/ - 抖音$/, '');
    return JSON.stringify({ title: title, author: author, video: video, images: images, motions: motions,
             cover: (v && (first(v.cover) || first(v.origin_cover))) || '' });
  } catch (e) { return JSON.stringify({ error: 'js: ' + e }); }
})()
''';
}

/// 无界面 WebView：加载页面 → 轮询就绪脚本 → 执行提取脚本拿字符串
class HeadlessExtractor {
  static Future<String?> run({
    required String url,
    required String userAgent,
    required String readyJs,
    required String extractJs,
    List<String> startScripts = const [],
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final created = Completer<InAppWebViewController>();
    final headless = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSettings: InAppWebViewSettings(userAgent: userAgent, mediaPlaybackRequiresUserGesture: true),
      initialUserScripts: UnmodifiableListView(startScripts
          .map((s) => UserScript(source: s, injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START))
          .toList()),
      onWebViewCreated: (c) {
        if (!created.isCompleted) created.complete(c);
      },
    );
    try {
      await headless.run();
      final controller = await created.future.timeout(const Duration(seconds: 10));
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 600));
        final ready = await controller.evaluateJavascript(source: readyJs);
        if ('$ready' == 'true') break;
      }
      await Future.delayed(const Duration(milliseconds: 800));
      final result = await controller.evaluateJavascript(source: extractJs);
      return result?.toString();
    } catch (_) {
      return null;
    } finally {
      await headless.dispose();
    }
  }
}
