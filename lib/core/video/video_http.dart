// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import '../http.dart';
import '../json.dart';
import '../links.dart';
import '../models.dart';
import '../text.dart';
import 'parsers.dart';
import 'douyin.dart';
import 'xhs_pixiv.dart';

/// 单个视频平台的解析器
abstract class VideoParser {
  VideoPlatform get platform;
  Future<VideoParseResult> parse(DetectedVideoLink link, String cookie);

  /// 保存登录态前的校验：返回昵称（拿不到返回空串），无效返回 null
  Future<String?> validateCookie(String cookie) async => cookie.trim().isEmpty ? null : '';
}

/// 视频解析共用的 HTTP 小工具：把状态码翻译成 [VideoParseError]、展开短链、抠内嵌 JSON
class VHttp {
  static Future<RawResponse> request(String url,
      {String method = 'GET', Map<String, String> headers = const {}, List<int>? body, bool follow = true}) async {
    try {
      return await Http.send(url, method: method, headers: headers, body: body, followRedirects: follow);
    } catch (_) {
      throw VideoParseError(VideoErrorKind.network, '请求失败：$url');
    }
  }

  static void requireOk(RawResponse r, String what) {
    if (r.ok) return;
    if ([403, 418, 429].contains(r.status)) throw VideoParseError(VideoErrorKind.blocked, '$what 被风控拦截');
    if ([404, 410].contains(r.status)) throw VideoParseError(VideoErrorKind.notFound, '$what 不存在');
    throw VideoParseError(VideoErrorKind.unknown, '$what 请求失败（HTTP ${r.status}）');
  }

  static Future<String> text(String url, {Map<String, String> headers = const {}, String what = '解析'}) async {
    final r = await request(url, headers: headers);
    requireOk(r, what);
    return r.text;
  }

  static Future<J> json(String url, {Map<String, String> headers = const {}, String what = '解析'}) async {
    final j = J.tryParse(await text(url, headers: headers, what: what));
    if (j == null) throw VideoParseError(VideoErrorKind.unknown, '$what 返回的不是合法 JSON');
    return j;
  }

  /// 展开短链：只跟一次重定向；拿不到 Location 返回 null
  static Future<String?> expandRedirect(String url, {Map<String, String> headers = const {}}) async {
    final r = await request(url, headers: headers, follow: false);
    if (r.status >= 300 && r.status < 400) {
      final loc = r.header('location');
      return loc == null ? null : Uri.parse(url).resolve(loc).toString();
    }
    final f = r.finalUrl.toString();
    return f != url ? f : null;
  }

  /// 抠 `window.XXX = {...}</script>` 形式的内嵌 JSON 文本
  static String? inlineJson(String html, String key, {String stopAt = '</script>'}) {
    final v = RX.first('${RegExp.escape(key)}\\s*=\\s*(.*?)${RegExp.escape(stopAt)}', html, dotAll: true);
    return v?.trim().trimTrailing(';').trim();
  }
}

/// 解析入口：识别 → 展开短链 → 分发到平台解析器 → 直链升级 https
class VideoParseService {
  static final Map<VideoPlatform, VideoParser> parsers = {
    VideoPlatform.douyin: DouyinParser(),
    VideoPlatform.kuaishou: KuaishouParser(),
    VideoPlatform.weibo: WeiboParser(),
    VideoPlatform.acfun: AcFunParser(),
    VideoPlatform.bilibili: BilibiliParser(),
    VideoPlatform.xhs: XhsParser(),
    VideoPlatform.pixiv: PixivParser(),
  };

  static Future<VideoParseResult> parse(DetectedVideoLink link, String cookie) async {
    var resolved = link;
    if (link.isShort) resolved = await _expand(link);
    final parser = parsers[resolved.platform];
    if (parser == null) {
      throw VideoParseError(VideoErrorKind.unsupported, 'Flutter 版暂未支持解析${resolved.platform.displayName}，敬请期待');
    }
    final result = await parser.parse(resolved, cookie);
    for (final m in result.medias) {
      m.url = m.url.secureUrl;
      m.audioUrl = m.audioUrl.secureUrl;
      m.motionUrl = m.motionUrl.secureUrl;
    }
    result.cover = result.cover.secureUrl;
    result.avatar = result.avatar.secureUrl;
    return result;
  }

  static Future<DetectedVideoLink> _expand(DetectedVideoLink link) async {
    var current = link;
    final ua = link.platform == VideoPlatform.douyin || link.platform == VideoPlatform.kuaishou ? UA.iPhone : UA.chrome;
    for (var i = 0; i < 5; i++) {
      final next = await VHttp.expandRedirect(current.url, headers: {'User-Agent': ua});
      if (next == null) return current;
      final again = VideoLinkParser.parse(next);
      if (again == null) return DetectedVideoLink(current.platform, current.kind, current.id, next);
      if (!again.isShort) return again;
      current = again;
    }
    return current;
  }
}
