// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import '../models.dart';
import 'lanzou.dart';
import 'pan123.dart';
import 'quark_uc.dart';

/// 分享解析公共接口：打开分享 → 列目录 → 取直链（免转存）。
abstract class ShareResolver {
  Future<ShareSession> open(ParsedShare share, String? pwd, String cookie);
  Future<List<ShareFile>> list(ShareSession session, String dirId, String cookie);
  Future<DownloadLink> downloadLink(ShareSession session, ShareFile file, String cookie);
}

class ShareResolvers {
  static final _quark = QuarkResolver();
  static final _uc = UCResolver();
  static final _pan123 = Pan123Resolver();
  static final _lanzou = LanzouResolver();

  static ShareResolver of(SharePlatform platform) => switch (platform) {
        SharePlatform.quark => _quark,
        SharePlatform.uc => _uc,
        SharePlatform.pan123 => _pan123,
        SharePlatform.lanzou => _lanzou,
        _ => throw ResolveError('Flutter 版暂未支持${platform.displayName}，敬请期待'),
      };

  /// 登录态校验：返回昵称，无效返回 null
  static Future<String?> validate(SharePlatform platform, String cookie) => switch (platform) {
        SharePlatform.quark => QuarkResolver.fetchNickname(cookie),
        SharePlatform.uc => UCResolver.fetchNickname(cookie),
        SharePlatform.pan123 => Pan123Resolver.fetchNickname(cookie),
        _ => Future.value(cookie.trim().isEmpty ? null : ''),
      };
}
