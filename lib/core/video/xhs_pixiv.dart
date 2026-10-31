// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import '../http.dart';
import '../json.dart';
import '../models.dart';
import '../text.dart';
import 'parsers.dart';
import 'video_http.dart';

// MARK: 小红书

/// 小红书：网页端笔记页对未登录会话一律拦截，必须带 web_session。
/// 先试 explore 页（桌面 UA），失败再试 discovery 页（移动 UA）；图片尽量换去水印原图，探测不到回退平台地址。
class XhsParser extends VideoParser {
  @override
  VideoPlatform get platform => VideoPlatform.xhs;

  static const _home = 'https://www.xiaohongshu.com';
  static const _cdn = 'https://sns-img-bd.xhscdn.com';
  static const _accept = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8';
  static const _loginMarkers = ['/login', 'website-login', 'captcha'];

  Map<String, String> _media(String cookie) =>
      {'User-Agent': UA.chrome, 'Referer': '$_home/', if (cookie.isNotEmpty) 'Cookie': cookie};

  @override
  Future<String?> validateCookie(String cookie) async {
    if (cookie.isEmpty) return null;
    try {
      final r = await VHttp.request('$_home/explore', headers: {'User-Agent': UA.chrome, 'accept': _accept, 'Cookie': cookie});
      return _loginMarkers.any(r.finalUrl.toString().contains) ? null : '';
    } catch (_) {
      return null;
    }
  }

  @override
  Future<VideoParseResult> parse(DetectedVideoLink link, String cookie) async {
    if (cookie.isEmpty) {
      throw VideoParseError(VideoErrorKind.unsupported, '小红书要求登录后才能查看笔记，请先到「账号」页登录小红书');
    }
    final q = link.url.contains('?') ? '?${link.url.split('?').skip(1).join('?')}' : '';
    Object? exploreError;
    try {
      final state = await _state('$_home/explore/${link.id}$q', {..._media(cookie), 'accept': _accept});
      final note = state['note']['noteDetailMap'][link.id]['note'];
      if (note.isMap) return await _build(note, link, cookie, 'nickname');
      exploreError = VideoParseError(VideoErrorKind.notFound, '小红书页面里没有该笔记数据');
    } on VideoParseError catch (e) {
      if (e.kind == VideoErrorKind.unsupported) rethrow;
      exploreError = e;
    } catch (e) {
      exploreError = e;
    }
    final state = await _state('$_home/discovery/item/${link.id}$q',
        {..._media(cookie), 'User-Agent': UA.iPhone, 'accept': _accept, 'origin': _home});
    final note = state['noteData']['data']['noteData'];
    if (!note.isMap) throw exploreError ?? VideoParseError(VideoErrorKind.notFound, '小红书分享链接失效或内容已删除');
    return _build(note, link, cookie, 'nickName');
  }

  Future<J> _state(String url, Map<String, String> headers) async {
    final r = await VHttp.request(url, headers: headers);
    VHttp.requireOk(r, '小红书笔记');
    if (_loginMarkers.any(r.finalUrl.toString().contains)) {
      throw VideoParseError(VideoErrorKind.unsupported, '小红书登录已失效或被风控，请到「账号」页重新登录小红书');
    }
    final raw = VHttp.inlineJson(r.text, 'window.__INITIAL_STATE__');
    final j = raw == null ? null : J.tryParse(raw.replaceAll('undefined', 'null'));
    if (j == null) throw VideoParseError(VideoErrorKind.unknown, '小红书页面里没有笔记数据（可能被风控拦截或页面改版）');
    return j;
  }

  /// 去水印原图：取图片 id（路径第 3 段起，去掉 ! 之后的样式）拼到原图 CDN
  String _clean(String raw) {
    final i = raw.indexOf('://');
    if (i < 0) return raw;
    final segs = raw.substring(i + 3).split('/').skip(1).skip(2).join('/');
    final id = segs.split('!').first;
    return id.isEmpty ? raw : '$_cdn/$id';
  }

  Future<VideoParseResult> _build(J note, DetectedVideoLink link, String cookie, String authorKey) async {
    final headers = _media(cookie);
    final title = note['title'].s;
    final base = fileBase(title, '小红书_${link.id}');
    final raw = note['imageList'].list.map((e) => e.any(['urlDefault', 'url'])).where((e) => e.isNotEmpty).toList();
    final medias = <VideoMedia>[];
    var cover = '';
    var notice = '';
    final stream = note['video']['media']['stream'];
    (String, String)? video;
    for (final (key, label) in const [('h265', 'H.265'), ('h264', 'H.264'), ('av1', 'AV1'), ('h266', 'H.266')]) {
      final url = stream[key][0].any(['masterUrl', 'master_url']);
      if (url.isNotEmpty) {
        video = (url, label);
        break;
      }
    }
    if (video != null) {
      cover = raw.isEmpty ? '' : _clean(raw.first);
      medias.add(VideoMedia(url: video.$1, kind: MediaKind.video, fileName: '$base.mp4', headers: headers, quality: video.$2));
    } else if (note['video'].isMap) {
      throw VideoParseError(VideoErrorKind.unknown, '小红书视频笔记没有取到视频直链');
    } else {
      var fallback = 0;
      final urls = await Future.wait(raw.map((u) async {
        final c = _clean(u);
        if (c == u) return u;
        try {
          final r = await VHttp.request(c, method: 'HEAD', headers: headers);
          if (r.status == 404 || r.status == 410) {
            fallback++;
            return u;
          }
        } catch (_) {}
        return c;
      }));
      for (var i = 0; i < urls.length; i++) {
        medias.add(VideoMedia(url: urls[i], kind: MediaKind.image, fileName: '${base}_${i + 1}.jpg', headers: headers, quality: '原图'));
      }
      if (fallback > 0) notice = '$fallback 张图片没有可用的去水印原图，已改用平台地址（可能带水印）';
      cover = urls.isEmpty ? '' : urls.first;
    }
    return VideoParseResult(
      platform: platform,
      title: title,
      author: note['user'][authorKey].s,
      avatar: note['user']['avatar'].s,
      cover: cover,
      text: note['desc'].s,
      timestamp: note['time'].i ~/ 1000,
      url: link.url,
      medias: medias,
      notice: notice,
    );
  }
}

// MARK: Pixiv

/// Pixiv：ajax/illust 取作品信息 + pages 取每页原图；R18 / 受限作品需要粘贴浏览器 Cookie（PHPSESSID）
class PixivParser extends VideoParser {
  @override
  VideoPlatform get platform => VideoPlatform.pixiv;

  Map<String, String> _h(String cookie, {bool json = false}) => {
        'User-Agent': UA.chrome,
        'Referer': 'https://www.pixiv.net/',
        if (json) 'Accept': 'application/json',
        if (cookie.isNotEmpty) 'Cookie': cookie,
      };

  @override
  Future<String?> validateCookie(String cookie) async {
    if (cookie.isEmpty) return null;
    try {
      final r = await VHttp.request('https://www.pixiv.net/dashboard/works', headers: _h(cookie, json: true), follow: false);
      if (r.status < 300 || r.status >= 400) return '';
      final loc = r.header('location') ?? '';
      return loc.contains('return_to=') || loc.contains('/login') || loc.contains('accounts.pixiv.net') ? null : '';
    } catch (_) {
      return '';
    }
  }

  @override
  Future<VideoParseResult> parse(DetectedVideoLink link, String cookie) async {
    final info = await VHttp.json('https://www.pixiv.net/ajax/illust/${link.id}', headers: _h(cookie, json: true), what: 'Pixiv 作品信息');
    if (info['error'].b) {
      final msg = info['message'].s;
      final lower = msg.toLowerCase();
      if (lower.contains('not found')) throw VideoParseError(VideoErrorKind.notFound, msg);
      if (lower.contains('login') || lower.contains('session') || cookie.isEmpty) {
        throw VideoParseError(
            VideoErrorKind.unsupported,
            cookie.isEmpty
                ? '该作品需要登录后才能解析（多为 R18 或受限作品），请在「账号」页粘贴浏览器里的 Cookie'
                : 'Pixiv 登录态已失效，请到「账号」页重新粘贴 Cookie');
      }
      throw VideoParseError(VideoErrorKind.blocked, 'Pixiv 作品信息返回错误：$msg');
    }
    final body = info['body'];
    if (body['illustType'].i == 2) throw VideoParseError(VideoErrorKind.unsupported, 'Pixiv 动图（ugoira）需要合成 GIF，当前版本暂不支持');
    final title = body['title'].s;
    final base = fileBase(title, 'pixiv_${link.id}');
    List<J> pages = const [];
    try {
      pages = (await VHttp.json('https://www.pixiv.net/ajax/illust/${link.id}/pages', headers: _h(cookie, json: true)))['body'].list;
    } catch (_) {}
    var urls = pages.map((p) => p['urls']['original'].s).where((e) => e.isNotEmpty).toList();
    if (urls.isEmpty && body['urls']['original'].s.isNotEmpty) urls = [body['urls']['original'].s];
    if (urls.isEmpty) throw VideoParseError(VideoErrorKind.notFound, 'Pixiv 未返回任何可下载的原图');
    String ext(String u) {
      final e = u.split('?').first.split('.').last.toLowerCase();
      return e.length <= 4 ? e : 'jpg';
    }

    return VideoParseResult(
      platform: platform,
      title: title,
      author: body['userName'].s,
      cover: urls.first,
      text: WeiboParser.cleanHtml(body['description'].s),
      timestamp: (DateTime.tryParse(body['createDate'].s)?.millisecondsSinceEpoch ?? 0) ~/ 1000,
      url: 'https://www.pixiv.net/artworks/${link.id}',
      medias: [
        for (var i = 0; i < urls.length; i++)
          VideoMedia(
            url: urls[i],
            kind: MediaKind.image,
            fileName: urls.length == 1 ? '$base.${ext(urls[i])}' : '${base}_${i + 1}.${ext(urls[i])}',
            headers: _h(cookie),
            quality: '原图',
          ),
      ],
    );
  }
}
