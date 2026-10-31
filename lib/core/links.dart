// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import 'models.dart';
import 'text.dart';

class _ShareRule {
  const _ShareRule(this.platform, this.pattern, this.pwdPattern, {this.dropFirst = false});
  final SharePlatform platform;
  final String pattern;
  final String pwdPattern;

  /// 百度 surl 不含开头的 1
  final bool dropFirst;
}

/// 从整段分享文案中提取 share_id 与提取码（规则逐条对齐安卓版 ShareLinkParser）
class ShareLinkParser {
  static const _pwdInUrl = r'[?&]pwd=([A-Za-z0-9]+)';
  static const _pwdIn115 = r'[?&]password=([A-Za-z0-9]+)';
  static const _pwdInLanzou = r'[?&](?:pwd|pass|passcode|password)=([A-Za-z0-9]+)';
  static const _pwdInText = r'(?:提取码|访问码|密码)[：:]\s*([A-Za-z0-9]{4,8})';

  /// 顺序即优先级：蓝奏云优享版必须先于蓝奏云判断
  static const _rules = [
    _ShareRule(SharePlatform.quark, r'pan\.quark\.cn/s/([A-Za-z0-9]+)', _pwdInUrl),
    _ShareRule(SharePlatform.uc, r'drive\.uc\.cn/s/([A-Za-z0-9]+)', _pwdInUrl),
    _ShareRule(SharePlatform.xunlei, r'pan\.xunlei\.com/s/([A-Za-z0-9_-]+)', _pwdInUrl),
    _ShareRule(SharePlatform.baidu, r'pan\.baidu\.com/s/(1[A-Za-z0-9_-]+)', _pwdInUrl, dropFirst: true),
    _ShareRule(SharePlatform.c139, r'yun\.139\.com/shareweb/.*?/w/i/([A-Za-z0-9_-]+)', _pwdInUrl),
    _ShareRule(SharePlatform.pan123, r'123(?:865|pan)\.(?:com|cn)/s/([A-Za-z0-9]+-[A-Za-z0-9]+)', _pwdInUrl),
    _ShareRule(SharePlatform.pan123, r'share\.123pan\.cn/123pan/([A-Za-z0-9-]+)', _pwdInUrl),
    _ShareRule(SharePlatform.pan123, r'api/srr\?sk=([A-Za-z0-9-]+)', _pwdInUrl),
    _ShareRule(SharePlatform.pan115, r'115(?:cdn|rc)?\.com/s/(sw[A-Za-z0-9]+)', _pwdIn115),
    _ShareRule(SharePlatform.guangya, r'guangyapan\.com/s/([A-Za-z0-9_-]+)', _pwdInUrl),
    _ShareRule(SharePlatform.ilanzou, r'(?:^|[/.])ilanzou\.(?:com|net|org|cn)/s/([A-Za-z0-9_-]+)', _pwdInLanzou),
    _ShareRule(SharePlatform.lanzou,
        r'(?:^|[/.])(?:lanzou[a-z0-9-]*|lan[zs]o[ux]|lanzn)\.(?:com|net|org|cn)/([A-Za-z0-9]+)', _pwdInLanzou),
  ];

  static String? extractUrl(String text) =>
      RX.first(r'https?://[^\s]+', text.trim(), group: 0, ignoreCase: false)?.trimTrailing('。，,；;)]}"\'');

  static ParsedShare? parse(String text) {
    final url = extractUrl(text);
    if (url == null) return null;
    for (final rule in _rules) {
      final id = RX.first(rule.pattern, url);
      if (id == null) {
        // 115 口令形式 https://115.com/sws8lxs36jf-n307/（code-提取码）
        if (rule.platform == SharePlatform.pan115) {
          final c = RX.groups(r'115(?:cdn|rc)?\.com/(sw[A-Za-z0-9]{8,})-([A-Za-z0-9]{4,8})', url);
          if (c != null) return ParsedShare(c[1], c[2], SharePlatform.pan115, url);
        }
        continue;
      }
      final pwd = RX.first(rule.pwdPattern, url, ignoreCase: false) ?? RX.first(_pwdInText, text, ignoreCase: false);
      return ParsedShare(rule.dropFirst ? id.substring(1) : id, pwd, rule.platform, url);
    }
    return null;
  }
}

class _VideoRule {
  const _VideoRule(this.platform, this.kind, this.pattern);
  final VideoPlatform platform;
  final String kind;
  final String pattern;
}

/// 视频链接识别（规则对齐安卓版 VideoLinkParser）。只在链接上匹配，不看链接外的文案。
class VideoLinkParser {
  static const _rules = [
    _VideoRule(VideoPlatform.douyin, 'short', r'v\.douyin\.com/[A-Za-z0-9_\-]+'),
    _VideoRule(VideoPlatform.douyin, 'short', r'jx\.douyin\.com/[A-Za-z0-9_\-]+'),
    _VideoRule(VideoPlatform.douyin, 'video', r'(?:www\.)?douyin\.com/(video|note)/(\d{10,})'),
    _VideoRule(VideoPlatform.douyin, 'video', r'douyin\.com/[^\s]*[?&]modal_id=(\d{10,})'),
    _VideoRule(VideoPlatform.douyin, 'video', r'iesdouyin\.com/share/(?:slides|video|note)/(\d{10,})'),
    _VideoRule(VideoPlatform.douyin, 'video', r'm\.douyin\.com/share/(?:slides|video|note)/(\d{10,})'),
    _VideoRule(VideoPlatform.douyin, 'video', r'jingxuan\.douyin\.com/m/(?:slides|video|note)/(\d{10,})'),
    _VideoRule(VideoPlatform.xhs, 'short', r'xhslink\.(?:com|cn)/[A-Za-z0-9._?%&+=/#@\-]+'),
    _VideoRule(VideoPlatform.xhs, 'note', r'xiaohongshu\.com/(?:explore|discovery/item|discovery)/([0-9a-zA-Z]{10,})'),
    _VideoRule(VideoPlatform.kuaishou, 'short', r'v\.kuaishou\.com/[A-Za-z\d._?%&+\-=/#]+'),
    _VideoRule(VideoPlatform.kuaishou, 'photo', r'(?:www\.)?kuaishou\.com/(?:short-video|fw/photo|fw/long-video)/([A-Za-z\d]+)'),
    _VideoRule(VideoPlatform.kuaishou, 'photo', r'(?:www\.)?kuaishou\.com/f/([A-Za-z\d]+)'),
    _VideoRule(VideoPlatform.kuaishou, 'photo', r'(?:v\.m\.)?chenzhongtech\.com/fw/(?:photo|long-video)/([A-Za-z\d]+)'),
    _VideoRule(VideoPlatform.weibo, 'tv', r'weibo\.com/tv/show/\d{4}:\d+\?mid=(\d+)'),
    _VideoRule(VideoPlatform.weibo, 'fid', r'video\.weibo\.com/show\?fid=(\d+:\d+)'),
    _VideoRule(VideoPlatform.weibo, 'status', r'weibo\.cn/(?:status|statuses|detail)/([0-9a-zA-Z]+)'),
    _VideoRule(VideoPlatform.weibo, 'status', r'weibo\.com/\d+/([0-9a-zA-Z]{6,})'),
    _VideoRule(VideoPlatform.acfun, 'ac', r'acfun\.cn/.*(?:ac=|/ac)(\d+)'),
    _VideoRule(VideoPlatform.bilibili, 'short', r'b23\.tv/[A-Za-z\d]+'),
    _VideoRule(VideoPlatform.bilibili, 'short', r'bili2233\.cn/[A-Za-z\d]+'),
    _VideoRule(VideoPlatform.bilibili, 'video', r'bilibili\.com/video/(BV[0-9a-zA-Z]{10}|av\d+)'),
    _VideoRule(VideoPlatform.pixiv, 'artwork', r'pixiv\.net/(?:[a-z]{2}/)?artworks/(\d+)'),
    _VideoRule(VideoPlatform.pixiv, 'artwork', r'pixiv\.net/member_illust\.php\?[^\s]*illust_id=(\d+)'),
  ];

  static DetectedVideoLink? parse(String text) {
    final raw = RX.first(r'https?://[^\s]+', text.trim(), group: 0, ignoreCase: false);
    if (raw == null) return null;
    final url = raw.trimTrailing('。，,；;)]}"\'、！？…');
    for (final rule in _rules) {
      final g = RX.groups(rule.pattern, url);
      if (g == null) continue;
      final isShort = rule.kind == 'short';
      final id = g.skip(1).lastWhere((e) => e.isNotEmpty, orElse: () => '');
      return DetectedVideoLink(rule.platform, rule.kind, isShort ? '' : id, url.startsWith('http') ? url : 'https://$url');
    }
    return null;
  }
}

/// 解析页统一入口：先视频、再网盘
class DetectedLink {
  DetectedLink._(this.share, this.video);
  final ParsedShare? share;
  final DetectedVideoLink? video;

  static DetectedLink? detect(String text) {
    final v = VideoLinkParser.parse(text);
    if (v != null) return DetectedLink._(null, v);
    final s = ShareLinkParser.parse(text);
    if (s != null) return DetectedLink._(s, null);
    return null;
  }

  String get displayName => share?.platform.displayName ?? video!.platform.displayName;
  String get logo => share?.platform.logo ?? video!.platform.logo;
  bool get isAvailable => share?.platform.isAvailable ?? video!.platform.isAvailable;
}
