// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import 'package:flutter/material.dart';

import 'http.dart';

enum LoginKind { none, web, password, manual }

/// 网盘平台
enum SharePlatform {
  quark('夸克网盘', 'quark', 0xFF3B6CF6),
  uc('UC 网盘', 'uc', 0xFFF5821F),
  xunlei('迅雷网盘', 'xunlei', 0xFF2A8CF0),
  baidu('百度网盘', 'baidu', 0xFF2468F2),
  c139('139 网盘', 'c139', 0xFF00A1E9),
  pan123('123 云盘', '123pan', 0xFF597DFC),
  pan115('115 网盘', 'pan115', 0xFF2777F8),
  guangya('光鸭云盘', 'guangya', 0xFF7B61FF),
  ilanzou('蓝奏云优享', 'ilanzou', 0xFF3A9BFF),
  lanzou('蓝奏云', 'lanzou', 0xFF1E88E5);

  const SharePlatform(this.displayName, this._logo, this._tint);
  final String displayName;
  final String _logo;
  final int _tint;

  String get logo => 'assets/logos/logo_$_logo.png';
  Color get tint => Color(_tint);

  /// 已移植完成的平台；其余能识别，但解析时提示「即将支持」
  bool get isAvailable => const {quark, uc, pan123, lanzou}.contains(this);

  LoginKind get loginKind => switch (this) {
        quark || uc => LoginKind.web,
        pan123 => LoginKind.password,
        _ => LoginKind.none,
      };

  String? get loginUrl => switch (this) {
        quark => 'https://pan.quark.cn/?fr=pc&platform=pc',
        uc => 'https://drive.uc.cn/',
        _ => null,
      };

  String get cookieDomain => switch (this) {
        quark => 'quark.cn',
        uc => 'uc.cn',
        _ => '',
      };

  List<String> get requiredCookies => switch (this) {
        quark || uc => const ['__pus'],
        _ => const [],
      };

  String get loginBenefit => switch (this) {
        quark => '未登录可下载约 50MB 以内的文件；登录后免转存直接取链，不受大小限制',
        uc => '未登录可游客下载；登录后视频可取原画直链',
        pan123 => '浏览分享无需登录；下载需要账号密码登录',
        lanzou => '蓝奏云分享无需登录即可解析下载',
        _ => 'Flutter 版正在移植中',
      };
}

/// 视频平台
enum VideoPlatform {
  douyin('抖音', 'douyin', 0xFF111111),
  xhs('小红书', 'xhs', 0xFFFF2442),
  kuaishou('快手', 'kuaishou', 0xFFFF5000),
  weibo('微博', 'weibo', 0xFFE6162D),
  acfun('AcFun', 'acfun', 0xFFFD4C5D),
  bilibili('哔哩哔哩', 'bilibili', 0xFFFB7299),
  pixiv('Pixiv', 'pixiv', 0xFF0096FA);

  const VideoPlatform(this.displayName, this._logo, this._tint);
  final String displayName;
  final String _logo;
  final int _tint;

  String get logo => 'assets/logos/logo_$_logo.png';
  Color get tint => Color(_tint);
  bool get isAvailable => this != xhs && this != pixiv;

  LoginKind get loginKind => switch (this) {
        bilibili || xhs => LoginKind.web,
        pixiv => LoginKind.manual,
        _ => LoginKind.none,
      };

  String? get loginUrl => switch (this) {
        bilibili => 'https://passport.bilibili.com/login',
        xhs => 'https://www.xiaohongshu.com/login',
        _ => null,
      };

  String get cookieDomain => switch (this) {
        bilibili => 'bilibili.com',
        xhs => 'xiaohongshu.com',
        pixiv => 'pixiv.net',
        _ => '',
      };

  List<String> get requiredCookies => switch (this) {
        bilibili => const ['SESSDATA'],
        xhs => const ['web_session'],
        pixiv => const ['PHPSESSID'],
        _ => const [],
      };

  String get loginBenefit => switch (this) {
        bilibili => '登录后可解析 1080P 及以上清晰度（音视频分轨，下载后自动合并）',
        xhs => '小红书网页端要求登录后才能查看笔记',
        pixiv => '粘贴浏览器 Cookie 后可解析全部作品',
        _ => '无需登录，直接解析',
      };
}

/// 账号存储用的统一键
class AccountKey {
  const AccountKey.drive(SharePlatform this.drive) : video = null;
  const AccountKey.video(VideoPlatform this.video) : drive = null;

  final SharePlatform? drive;
  final VideoPlatform? video;

  String get storageKey => drive != null ? 'drive.${drive!.name}' : 'video.${video!.name}';
  String get displayName => drive?.displayName ?? video!.displayName;
  String get logo => drive?.logo ?? video!.logo;
  String? get loginUrl => drive?.loginUrl ?? video!.loginUrl;
  String get cookieDomain => drive?.cookieDomain ?? video!.cookieDomain;
  List<String> get requiredCookies => drive?.requiredCookies ?? video!.requiredCookies;
  LoginKind get loginKind => drive?.loginKind ?? video!.loginKind;

  @override
  bool operator ==(Object other) => other is AccountKey && other.storageKey == storageKey;
  @override
  int get hashCode => storageKey.hashCode;
}

// MARK: 网盘

class ParsedShare {
  const ParsedShare(this.shareId, this.pwd, this.platform, this.url);
  final String shareId;
  final String? pwd;
  final SharePlatform platform;
  final String url;
}

class ShareSession {
  const ShareSession(this.platform, this.shareId, this.token, this.title, this.rootId);
  final SharePlatform platform;
  final String shareId;

  /// 分享访问凭证（夸克 stoken / 蓝奏提取码）
  final String token;
  final String title;
  final String rootId;
}

class ShareFile {
  const ShareFile({
    required this.id,
    required this.name,
    required this.size,
    required this.isDir,
    this.parentId = '',
    this.token = '',
    this.modified = '',
  });

  final String id;
  final String name;
  final int size;
  final bool isDir;
  final String parentId;

  /// 平台附加凭证（夸克 share_fid_token / 蓝奏成员页地址 / 123 S3KeyFlag|Etag）
  final String token;
  final String modified;

  FileKind get kind => FileKind.of(name, isDir: isDir);
}

class DownloadLink {
  const DownloadLink(this.fileName, this.url, this.size, this.headers);
  final String fileName;
  final String url;
  final int size;
  final Map<String, String> headers;
}

class ResolveError extends AppError {
  ResolveError(super.message);
}

// MARK: 视频

enum MediaKind { video, image, audio }

class VideoMedia {
  VideoMedia({
    required this.url,
    required this.kind,
    this.fileName = '',
    this.size = -1,
    this.isHls = false,
    this.headers = const {},
    this.quality = '',
    this.audioUrl = '',
    this.audioHeaders = const {},
    this.motionUrl = '',
  });

  String url;
  final MediaKind kind;
  final String fileName;
  final int size;
  final bool isHls;
  final Map<String, String> headers;
  final String quality;
  String audioUrl;
  final Map<String, String> audioHeaders;
  String motionUrl;
}

class VideoParseResult {
  VideoParseResult({
    required this.platform,
    required this.title,
    this.author = '',
    this.avatar = '',
    this.cover = '',
    this.text = '',
    this.timestamp = 0,
    this.url = '',
    this.medias = const [],
    this.notice = '',
  });

  final VideoPlatform platform;
  final String title;
  final String author;
  String avatar;
  String cover;
  final String text;
  final int timestamp;
  final String url;
  final List<VideoMedia> medias;
  final String notice;

  List<VideoMedia> get videos => medias.where((m) => m.kind == MediaKind.video).toList();
  List<VideoMedia> get images => medias.where((m) => m.kind == MediaKind.image).toList();
}

class DetectedVideoLink {
  const DetectedVideoLink(this.platform, this.kind, this.id, this.url);
  final VideoPlatform platform;
  final String kind;
  final String id;
  final String url;
  bool get isShort => kind == 'short';
}

enum VideoErrorKind { blocked, notFound, network, unsupported, unknown }

class VideoParseError extends AppError {
  VideoParseError(this.kind, String detail) : super(_text(kind, detail));
  final VideoErrorKind kind;

  static String _text(VideoErrorKind kind, String detail) => switch (kind) {
        VideoErrorKind.blocked => '平台风控拦截了本次请求，请稍后重试',
        VideoErrorKind.notFound => '内容不存在、已删除或不可见',
        VideoErrorKind.network => '网络请求失败，请检查网络后重试',
        VideoErrorKind.unsupported => detail.isEmpty ? '暂不支持该链接' : detail,
        VideoErrorKind.unknown => detail.isEmpty ? '解析失败，请稍后重试' : detail,
      };
}

// MARK: 文件类型

enum FileKind {
  folder(Icons.folder_rounded, 0xFFF5B83D),
  video(Icons.play_circle_fill_rounded, 0xFFFF5A5F),
  image(Icons.image_rounded, 0xFF34C759),
  audio(Icons.music_note_rounded, 0xFFAF52DE),
  archive(Icons.folder_zip_rounded, 0xFFFF9500),
  document(Icons.description_rounded, 0xFF007AFF),
  app(Icons.inventory_2_rounded, 0xFF5AC8FA),
  code(Icons.code_rounded, 0xFF8E8E93),
  other(Icons.insert_drive_file_rounded, 0xFF8E8E93);

  const FileKind(this.icon, this._color);
  final IconData icon;
  final int _color;
  Color get color => Color(_color);

  static FileKind of(String name, {bool isDir = false}) {
    if (isDir) return folder;
    final dot = name.lastIndexOf('.');
    final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
    const groups = {
      video: ['mp4', 'mkv', 'mov', 'avi', 'flv', 'wmv', 'm4v', 'ts', 'webm', 'rmvb'],
      image: ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'bmp', 'tiff', 'avif'],
      audio: ['mp3', 'flac', 'wav', 'aac', 'm4a', 'ogg', 'ape', 'wma'],
      archive: ['zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'iso', 'dmg'],
      document: ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'md', 'epub', 'csv'],
      app: ['apk', 'ipa', 'exe', 'msi', 'deb', 'pkg'],
      code: ['json', 'xml', 'html', 'js', 'py', 'swift', 'kt', 'java', 'c', 'cpp', 'sh', 'yml', 'yaml', 'dart'],
    };
    for (final entry in groups.entries) {
      if (entry.value.contains(ext)) return entry.key;
    }
    return other;
  }
}
