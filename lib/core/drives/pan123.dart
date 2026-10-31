// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../http.dart';
import '../json.dart';
import '../models.dart';
import '../text.dart';
import 'resolver.dart';

/// 标准 CRC-32（IEEE 802.3）
class Crc32 {
  static final List<int> _table = List.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    }
    return c;
  });

  static int of(List<int> bytes) {
    var crc = 0xFFFFFFFF;
    for (final b in bytes) {
      crc = _table[(crc ^ b) & 0xFF] ^ (crc >>> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static String hex(String text) => of(utf8.encode(text)).toRadixString(16);
}

/// 123 云盘：分享列表匿名可读；取直链需要登录（账号密码换 JWT）+ auth-key/auth-value 签名。
class Pan123Resolver implements ShareResolver {
  static const webUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36';
  static const dartUA = 'Dart/3.12 (dart:io)';
  static const referer = 'https://yun.123pan.cn/';
  static const _signTable = 'adefghlmyijnopkqrstubcvwsz';
  static String? _uuid;

  /// 设备标识：同一设备长期不变、不参与签名
  static Future<String> loginUuid() async {
    if (_uuid != null) return _uuid!;
    final prefs = await SharedPreferences.getInstance();
    var value = prefs.getString('pan123.loginuuid') ?? '';
    if (value.isEmpty) {
      final rnd = Random.secure();
      value = List.generate(32, (_) => '0123456789abcdef'[rnd.nextInt(16)]).join();
      await prefs.setString('pan123.loginuuid', value);
    }
    return _uuid = value;
  }

  /// auth-key = crc32(UTC「ts+16h」的 yyyyMMddHHmm 逐位查表)；auth-value = "ts-random-crc32(ts|random|path|web|3|key)"
  static (String, String) makeSign(String path) {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final t = DateTime.fromMillisecondsSinceEpoch((ts + 57600) * 1000, isUtc: true);
    String two(int n) => n.toString().padLeft(2, '0');
    final minute = '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}${two(t.hour)}${two(t.minute)}';
    final substituted = minute.split('').map((d) => _signTable[int.parse(d)]).join();
    final key = Crc32.hex(substituted);
    final random = Random().nextInt(10000000);
    return (key, '$ts-$random-${Crc32.hex('$ts|$random|$path|web|3|$key')}');
  }

  static Future<Map<String, String>> _auth(String path, String token,
      {String platform = 'web', String appVersion = '3'}) async {
    final (key, value) = makeSign(path);
    return {
      'platform': platform,
      'app-version': appVersion,
      'authorization': 'Bearer $token',
      'loginuuid': await loginUuid(),
      'auth-key': key,
      'auth-value': value,
      'User-Agent': webUA,
      'Accept': 'application/json, text/plain, */*',
    };
  }

  static void _checkOk(J json, String fallback) {
    final code = json['code'].exists ? json['code'].i : -1;
    if (code != 0) throw ResolveError('${json['message'].s.ifEmpty(fallback)}（code=$code）');
  }

  /// 账号密码登录：user.123pan.cn（另一个站），成功判定是 code == 200
  static Future<String> passwordLogin(String account, String password) async {
    final passport = account.trim();
    if (passport.isEmpty || password.isEmpty) throw ResolveError('请输入账号和密码');
    final RawResponse r;
    try {
      r = await Http.postJson('https://user.123pan.cn/api/user/sign_in',
          {'passport': passport, 'password': password, 'remember': false},
          headers: {
            'platform': 'web',
            'app-version': '132',
            'loginuuid': await loginUuid(),
            'Origin': 'https://user.123pan.cn',
            'Referer': 'https://user.123pan.cn/',
            'User-Agent': webUA,
          });
    } catch (_) {
      throw ResolveError('网络异常，无法连接 123 登录服务，请稍后重试');
    }
    final json = J.tryParse(r.text);
    final token = json?['data']['token'].s ?? '';
    if (r.ok && json?['code'].i == 200 && token.isNotEmpty) return token;
    final message = (json?['message'].s ?? '').toLowerCase();
    bool has(List<String> words) => words.any(message.contains);
    if (r.status == 429 || has(['频繁', '频率', '次数', '稍后'])) throw ResolveError('123 登录请求过于频繁，请稍后重试');
    if (has(['验证码', '滑块', '安全验证', 'captcha', 'verify'])) throw ResolveError('123 要求额外安全验证，请稍后重试');
    if (has(['冻结', '封禁', '封停', '注销', '禁用'])) throw ResolveError('123 账号暂时不可登录，请先在官方客户端检查账号状态');
    throw ResolveError('123 登录失败，请检查账号和密码后重试');
  }

  static Future<String?> fetchNickname(String token) async {
    try {
      final r = await Http.send('https://yun.123pan.cn/b/api/user/info', headers: await _auth('/b/api/user/info', token));
      final json = J.tryParse(r.text);
      return json != null && json['code'].i == 0 && json['data'].isMap ? json['data']['Nickname'].s : null;
    } catch (_) {
      return null;
    }
  }

  Future<(List<ShareFile>, bool)> _page(String shareKey, String pwd, String parent, int page) async {
    var url = 'https://yun.123pan.cn/b/api/share/get?limit=100&next=0&orderBy=file_name&orderDirection=asc'
        '&shareKey=${Http.q(shareKey)}&ParentFileId=$parent&Page=$page';
    // 无提取码时不能传 SharePwd（传空值会 400）
    if (pwd.isNotEmpty) url += '&SharePwd=${Http.q(pwd)}';
    final r = await Http.send(url, headers: {'User-Agent': dartUA});
    final json = J.tryParse(r.text);
    if (json == null) throw ResolveError('123 响应解析失败（HTTP ${r.status}）');
    _checkOk(json, '获取文件列表失败');
    final data = json['data'];
    if (data['Expired'].b) throw ResolveError('分享已失效');
    final files = data['InfoList'].list
        .map((item) => ShareFile(
              id: item['FileId'].s,
              name: item['FileName'].s,
              size: item['Size'].i,
              isDir: item['Type'].i == 1,
              parentId: item['ParentFileId'].s,
              token: '${item['S3KeyFlag'].s}|${item['Etag'].s}',
              modified: item['UpdateAt'].s.take(16).replaceAll('T', ' '),
            ))
        .toList();
    return (files, data['Next'].s != '-1');
  }

  @override
  Future<ShareSession> open(ParsedShare share, String? pwd, String cookie) async {
    final code = pwd ?? '';
    final (files, _) = await _page(share.shareId, code, '0', 1);
    final title = files.length == 1 ? files.first.name : share.shareId;
    return ShareSession(SharePlatform.pan123, share.shareId, code, title.ifEmpty('123 分享'), '0');
  }

  @override
  Future<List<ShareFile>> list(ShareSession session, String dirId, String cookie) async {
    final all = <ShareFile>[];
    for (var page = 1; page < 50; page++) {
      final (files, more) = await _page(session.shareId, session.token, dirId, page);
      all.addAll(files);
      if (files.isEmpty || !more) break;
    }
    return all;
  }

  @override
  Future<DownloadLink> downloadLink(ShareSession session, ShareFile file, String cookie) async {
    if (cookie.isEmpty) throw ResolveError('123 云盘需要登录后才能下载，请先在「账号」页登录');
    final parts = file.token.split('|');
    const path = '/b/api/share/download/info';
    final r = await Http.postJson(
      'https://www.123865.com$path',
      {
        'ShareKey': session.shareId,
        'FileID': file.id,
        'S3KeyFlag': parts.isNotEmpty ? parts[0] : '',
        'Size': file.size,
        'Etag': parts.length > 1 ? parts[1] : '',
      },
      headers: await _auth(path, cookie, platform: 'android', appVersion: '39'),
    );
    final json = J.tryParse(r.text);
    if (json == null) throw ResolveError('123 响应解析失败（HTTP ${r.status}）');
    if (json['code'].i == 401) throw ResolveError('123 登录已过期，请在「账号」页重新登录');
    _checkOk(json, '获取下载链接失败');
    final raw = json['data']['DownloadURL'].s;
    if (raw.isEmpty) throw ResolveError('123 未返回下载链接');
    final real = await _followRedirect(decodeDownloadUrl(raw) ?? raw);
    return DownloadLink(file.name, real, file.size, const {'User-Agent': webUA, 'Referer': referer});
  }

  /// 下载地址两种形态：整段 base64，或 download-v2?params=<URL-safe base64>
  static String? decodeDownloadUrl(String raw) {
    String? decode(String v) {
      var n = v.replaceAll('-', '+').replaceAll('_', '/');
      while (n.length % 4 != 0) {
        n += '=';
      }
      try {
        return utf8.decode(base64.decode(n));
      } catch (_) {
        return null;
      }
    }

    final t = raw.trim();
    if (!t.contains('://')) {
      final d = decode(t);
      return d != null && d.toLowerCase().startsWith('http') ? d : null;
    }
    final i = t.indexOf('params=');
    if (i < 0) return null;
    return decode(t.substring(i + 7).split('&').first);
  }

  /// 带 auto_redirect=0 的直链 GET 回来是小 JSON：{"data":{"redirect_url":...}}，可能多跳
  Future<String> _followRedirect(String start) async {
    var url = start;
    for (var i = 0; i < 5; i++) {
      try {
        final r = await Http.send(url, headers: {'Referer': referer, 'User-Agent': dartUA, 'Range': 'bytes=0-8191'});
        if (r.bytes.length > 8192 || !r.text.trimLeft().startsWith('{')) return url;
        final next = J.tryParse(r.text)?['data']['redirect_url'].s ?? '';
        if (next.isEmpty) return url;
        url = next;
      } catch (_) {
        return url;
      }
    }
    return url;
  }
}
