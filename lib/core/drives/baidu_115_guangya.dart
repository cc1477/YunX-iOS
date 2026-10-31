// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../http.dart';
import '../json.dart';
import '../models.dart';
import '../text.dart';
import 'resolver.dart';

J _json(RawResponse r, String name) {
  final j = J.tryParse(r.text);
  if (j == null) throw ResolveError('$name 响应解析失败（HTTP ${r.status}）');
  return j;
}

String _hex(int n) {
  final rnd = Random.secure();
  return List.generate(n, (_) => '0123456789abcdef'[rnd.nextInt(16)]).join();
}

// MARK: 百度

/// 百度网盘分享：verify（randsk）→ xpan share list → 转存临时目录 → locatedownload 取 CDN 直链 → 删除转存。
/// 浏览公共分享无需登录；取直链必须登录（BDUSS）。
class BaiduResolver implements ShareResolver {
  static const webUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';
  static const netdiskUA = 'netdisk;12.24.6;piano;android-android;16;JSbridge4.4.0;jointBridge;1.1.0';
  static const _appId = '250528';
  static const _tempDir = '/YunX临时转存';
  String? _bdstoken;
  final Map<String, (String, String)> _shareInfo = {};

  static Future<J?> _template(String cookie, String fields) async {
    try {
      final r = await Http.send(
          'https://pan.baidu.com/api/gettemplatevariable?clienttype=0&app_id=$_appId&web=1&fields=${Http.q(fields)}',
          headers: {'Cookie': cookie, 'User-Agent': webUA});
      final j = J.tryParse(r.text);
      return j != null && j['errno'].i == 0 ? j['result'] : null;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> fetchNickname(String cookie) async {
    if (!cookie.contains('BDUSS=')) return null;
    return (await _template(cookie, '["username"]'))?['username'].s;
  }

  Future<String> _token(String cookie) async {
    if (_bdstoken != null && _bdstoken!.isNotEmpty) return _bdstoken!;
    final v = (await _template(cookie, '["bdstoken"]'))?['bdstoken'].s ?? '';
    if (v.isEmpty) throw ResolveError('获取 bdstoken 失败，请在「账号」页重新登录百度网盘');
    return _bdstoken = v;
  }

  static void _errno(J j, String fallback) {
    final e = j['errno'].i;
    if (e != 0) throw ResolveError('${j.any(['err_msg', 'show_msg']).ifEmpty(fallback)}（errno=$e）');
  }

  @override
  Future<ShareSession> open(ParsedShare share, String? pwd, String cookie) async {
    var sekey = '';
    if (pwd != null && pwd.isNotEmpty) {
      final r = await Http.postForm('https://pan.baidu.com/share/verify?surl=${share.shareId}',
          [MapEntry('pwd', pwd), const MapEntry('vcode_str', ''), const MapEntry('vcode', '')],
          headers: {'Cookie': cookie, 'User-Agent': webUA, 'Referer': 'https://pan.baidu.com/s/${share.shareId}'});
      final j = _json(r, '百度');
      _errno(j, '验证提取码失败');
      sekey = j['randsk'].s;
      if (sekey.isEmpty) throw ResolveError('百度未返回分享密钥');
    }
    final (title, files) = await _page(share.shareId, sekey, '/', cookie, 1);
    return ShareSession(SharePlatform.baidu, share.shareId, sekey,
        title.ifEmpty(files.length == 1 ? files.first.name : '百度分享'), '/');
  }

  @override
  Future<List<ShareFile>> list(ShareSession session, String dirId, String cookie) async {
    final all = <ShareFile>[];
    for (var p = 1; p <= 100; p++) {
      final (_, files) = await _page(session.shareId, session.token, dirId, cookie, p);
      all.addAll(files);
      if (files.length < 100) break;
    }
    return all;
  }

  Future<(String, List<ShareFile>)> _page(String surl, String sekey, String dir, String cookie, int page) async {
    final root = dir.isEmpty || dir == '/';
    var url = 'https://pan.baidu.com/rest/2.0/xpan/share?method=list&shorturl=$surl&page=$page&num=100'
        '&root=${root ? 1 : 0}&dir=${Http.q(root ? '/' : dir)}';
    if (sekey.isNotEmpty) url += '&sekey=$sekey';
    var auth = cookie;
    if (sekey.isNotEmpty && !cookie.contains('BDCLND=')) auth = cookie.isEmpty ? 'BDCLND=$sekey' : '$cookie; BDCLND=$sekey';
    final j = _json(
        await Http.send(url,
            headers: {'User-Agent': webUA, 'Referer': 'https://pan.baidu.com/s/$surl', if (auth.isNotEmpty) 'Cookie': auth}),
        '百度');
    final e = j['errno'].i;
    if (e != 0) {
      if (sekey.isEmpty) {
        throw ResolveError(e == -6 ? '该分享需要提取码，或需要先在「账号」页登录百度网盘' : '该分享需要提取码（errno=$e）');
      }
      _errno(j, '获取分享文件列表失败');
    }
    _shareInfo[surl] = (j['share_id'].s, j['uk'].s);
    final files = j['list'].list.map((item) {
      final isDir = item['isdir'].s == '1';
      final path = item['path'].s;
      return ShareFile(
        id: isDir ? path : item['fs_id'].s,
        name: item['server_filename'].s,
        size: item['size'].i,
        isDir: isDir,
        parentId: path,
        token: path,
        modified: Fmt.date(item['server_mtime'].i),
      );
    }).toList();
    return (j['title'].s, files);
  }

  @override
  Future<DownloadLink> downloadLink(ShareSession session, ShareFile file, String cookie) async {
    if (!cookie.contains('BDUSS=')) throw ResolveError('百度网盘需要登录后才能下载，请先在「账号」页登录');
    if (!_shareInfo.containsKey(session.shareId)) await _page(session.shareId, session.token, '/', cookie, 1);
    final info = _shareInfo[session.shareId];
    if (info == null || info.$1.isEmpty) throw ResolveError('百度分享信息缺失，请重新解析');
    final bdstoken = await _token(cookie);
    final dir = await _ensureTempDir(cookie, bdstoken);
    final auth = cookie.contains('BDCLND=') || session.token.isEmpty ? cookie : '$cookie; BDCLND=${session.token}';
    final transfer = _json(
        await Http.postForm(
            'https://pan.baidu.com/share/transfer?shareid=${info.$1}&from=${info.$2}&channel=chunlei'
            '&sekey=${session.token}&ondup=newcopy&web=1&app_id=$_appId&bdstoken=$bdstoken&clienttype=0',
            [MapEntry('fsidlist', '["${file.id}"]'), MapEntry('path', dir)],
            headers: {
              'Cookie': auth,
              'User-Agent': webUA,
              'Origin': 'https://pan.baidu.com',
              'Referer': 'https://pan.baidu.com/s/',
            }),
        '百度');
    _errno(transfer, '转存失败（百度网盘空间不足或文件过多时会失败）');
    final saved = transfer['extra']['list'][0]['to'].s.ifEmpty('$dir/${file.name}');
    try {
      final time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final url = 'https://d.pcs.baidu.com/rest/2.0/pcs/file?method=locatedownload&app_id=$_appId&clienttype=17&ver=4.0'
          '&ant=1&check_blue=1&es=1&esl=1&apn_id=1_-1&freeisp=0&queryfree=0&use=1&dtype=1&eck=1&ehps=1&err_ver=1.0'
          '&network_type=WIFI&channel=0&path=${Http.q(saved)}&time=$time'
          '&rand=5ed606e9da222cde0474cdf70eda884b&devuid=0F1E9FC2E084472DA5A61C4CF4C759AF&cuid=0F1E9FC2E084472DA5A61C4CF4C759AF'
          '&deviceid=348642637967375013&psign=860a071f77c860e8cea06e4e54c518f3&version=2.2.111.34&version_app=12.24.6&vip=0';
      final located = _json(
          await Http.send(url,
              method: 'POST',
              headers: {'Cookie': cookie, 'User-Agent': netdiskUA, 'Content-Type': 'application/x-www-form-urlencoded'},
              body: utf8.encode('0')),
          '百度');
      _errno(located, '获取高速下载链接失败');
      final c = located['urls'].list.where((u) => u['url'].s.isNotEmpty).toList();
      J? pick(bool Function(J) test) {
        for (final u in c) {
          if (test(u)) return u;
        }
        return null;
      }

      final direct = pick((u) => u['encrypt'].exists && u['encrypt'].i == 0 && u['url'].s.startsWith('https')) ??
          pick((u) => u['encrypt'].exists && u['encrypt'].i == 0) ??
          pick((u) => u['url'].s.startsWith('https')) ??
          (c.isEmpty ? null : c.first);
      if (direct == null) throw ResolveError('百度未返回下载链接');
      return DownloadLink(file.name, direct['url'].s, file.size, {'Cookie': cookie, 'User-Agent': netdiskUA});
    } finally {
      // appall 直链不依赖转存文件存活：取链后立即删除，网盘不留残留
      Http.postForm(
          'https://pan.baidu.com/api/filemanager?async=2&onnest=fail&opera=delete&bdstoken=$bdstoken&newVerify=1&clienttype=0&app_id=$_appId&web=1',
          [MapEntry('filelist', '["$saved"]')],
          headers: {'Cookie': cookie, 'User-Agent': netdiskUA}).catchError((_) => RawResponse(0, utf8.encode(''), {}, {}, Uri()));
    }
  }

  Future<String> _ensureTempDir(String cookie, String bdstoken) async {
    try {
      final r = await Http.send(
          'https://yun.baidu.com/api/list?clienttype=0&app_id=$_appId&web=1&order=time&desc=1&dir=%2F&num=100&page=1',
          headers: {'Cookie': cookie, 'User-Agent': netdiskUA});
      if ((J.tryParse(r.text)?['list'].list ?? const []).any((e) => e['path'].s == _tempDir)) return _tempDir;
      final c = await Http.postForm(
          'https://pan.baidu.com/api/create?a=commit&channel=chunlei&web=1&app_id=$_appId&clienttype=0&bdstoken=$bdstoken',
          [
            const MapEntry('path', _tempDir),
            const MapEntry('isdir', '1'),
            const MapEntry('size', ''),
            const MapEntry('block_list', '[]'),
            const MapEntry('method', 'post'),
            const MapEntry('dataType', 'json'),
          ],
          headers: {'Cookie': cookie, 'User-Agent': netdiskUA, 'Referer': 'https://yun.baidu.com/disk/main'});
      if (J.tryParse(c.text)?['errno'].i == 0) return _tempDir;
    } catch (_) {}
    return '/';
  }
}

// MARK: 115

/// 115 网盘分享：share/snap 列目录（匿名）→ share/downurl 取直链（需要登录 Cookie + 115 客户端 UA）。
/// 下载时 CDN 同时校验登录 Cookie 与取链响应下发的 CDN Cookie，两份拼在一起发。
class Pan115Resolver implements ShareResolver {
  static const webUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36';
  static const _api = 'https://webapi.115.com';
  String _version = '36.0.1';
  bool _versionFetched = false;

  String get _clientUA => 'Mozilla/5.0 115Browser/$_version';

  static String _referer(String code, String pwd) =>
      pwd.isEmpty ? 'https://115cdn.com/s/$code' : 'https://115cdn.com/s/$code?password=$pwd&';

  static Map<String, String> _headers(String cookie, String referer, {String ua = webUA}) => {
        'User-Agent': ua,
        'Accept': 'application/json, text/plain, */*',
        'X-Requested-With': 'XMLHttpRequest',
        'Referer': referer,
        if (cookie.isNotEmpty) 'Cookie': cookie,
      };

  static bool hasLogin(String cookie) => cookie.split(';').any((p) => p.trim().startsWith('UID='));

  static void _state(J j, String fallback) {
    if (j['state'].b) return;
    final e = j['errno'].exists ? j['errno'].i : j['errNo'].i;
    final raw = j.any(['error', 'msg']);
    final msg = switch (e) {
      990001 => '登录已过期，请在「账号」页重新登录 115 网盘',
      4100012 => '该分享需要访问码，请填写访问码后重试',
      4100008 => '访问码错误，请检查后重试',
      4100026 => '分享链接不存在或已被删除',
      990009 => '上一次操作还没完成，请稍后重试',
      50028 => '115 拒绝向网页端下发该文件的直链（文件过大），请改用 115 官方客户端下载',
      50029 => '115 判定当前标识版本过低、拒绝下发直链，请改用 115 官方客户端下载',
      _ => raw.ifEmpty(fallback),
    };
    throw ResolveError(e != 0 && !msg.contains('$e') ? '$msg（errno=$e）' : msg);
  }

  static Future<String?> fetchNickname(String cookie) async {
    if (!hasLogin(cookie)) return null;
    try {
      final r = await Http.send('$_api/user/info?ct=json', headers: _headers(cookie, 'https://115.com/'));
      final j = J.tryParse(r.text);
      if (j == null || !j['state'].b) return null;
      return j['data'].isMap ? j['data'].any(['user_name', 'name']) : j['data'].s;
    } catch (_) {
      return null;
    }
  }

  Future<(List<ShareFile>, int, String, String)> _snap(String code, String pwd, String cid, String cookie, int offset) async {
    final url = '$_api/share/snap?share_code=${Http.q(code)}&receive_code=${Http.q(pwd)}&offset=$offset&limit=100'
        '&asc=0&cid=${Http.q(cid.ifEmpty('0'))}&format=json';
    final j = _json(await Http.send(url, headers: _headers(cookie, _referer(code, pwd))), '115');
    _state(j, '获取分享列表失败');
    final data = j['data'];
    final files = <ShareFile>[];
    for (final item in data['list'].list) {
      final fid = item['fid'].s;
      final isDir = (item['fc'].exists ? item['fc'].i : (fid.isEmpty ? 0 : 1)) == 0;
      final id = isDir ? item['cid'].s : fid;
      if (id.isEmpty) continue;
      files.add(ShareFile(
        id: id,
        name: item['n'].s,
        size: isDir ? 0 : item['s'].i,
        isDir: isDir,
        parentId: isDir ? item['pid'].s : item['cid'].s,
        modified: Fmt.date(item['t'].i),
      ));
    }
    return (files, data['count'].i, data['userinfo']['user_id'].s, data['shareinfo']['share_title'].s);
  }

  (String, String) _decode(String token) {
    final i = token.indexOf('|');
    return i < 0 ? (token, '') : (token.substring(0, i), token.substring(i + 1));
  }

  @override
  Future<ShareSession> open(ParsedShare share, String? pwd, String cookie) async {
    final code = pwd ?? '';
    final (_, _, userId, title) = await _snap(share.shareId, code, '0', cookie, 0);
    return ShareSession(SharePlatform.pan115, share.shareId, '$code|$userId', title.ifEmpty(share.shareId), '0');
  }

  @override
  Future<List<ShareFile>> list(ShareSession session, String dirId, String cookie) async {
    final (pwd, _) = _decode(session.token);
    final all = <ShareFile>[];
    var offset = 0;
    for (var i = 0; i < 200; i++) {
      final (files, total, _, _) = await _snap(session.shareId, pwd, dirId, cookie, offset);
      all.addAll(files);
      offset += files.length;
      if (files.length < 100 || (total > 0 && all.length >= total)) break;
    }
    return all;
  }

  Future<void> _refreshVersion() async {
    if (_versionFetched) return;
    _versionFetched = true;
    try {
      final r = await Http.send('https://appversion.115.com/1/web/1.0/api/chrome', headers: {'User-Agent': webUA});
      final v = J.tryParse(r.text)?['data']['win']['version_code'].s ?? '';
      if (v.isNotEmpty && v.length <= 16 && RegExp(r'^[\d.]+$').hasMatch(v)) _version = v;
    } catch (_) {}
  }

  @override
  Future<DownloadLink> downloadLink(ShareSession session, ShareFile file, String cookie) async {
    if (!hasLogin(cookie)) throw ResolveError('115 网盘需要登录后才能下载，请先在「账号」页登录');
    final (pwd, userId) = _decode(session.token);
    if (userId.isEmpty) throw ResolveError('缺少分享者标识，请重新解析分享链接');
    await _refreshVersion();
    var url = '$_api/share/downurl?dl=1&user_id=${Http.q(userId)}&share_code=${Http.q(session.shareId)}&file_id=${Http.q(file.id)}';
    if (pwd.isNotEmpty) url += '&receive_code=${Http.q(pwd)}';
    final ua = _clientUA;
    final r = await Http.send(url, headers: _headers(cookie, _referer(session.shareId, pwd), ua: ua));
    final j = _json(r, '115');
    _state(j, '获取下载链接失败');
    final data = j['data'];
    final fileUrl = [data['file_url_302'].s, data['file_url'].s, data['url']['url'].s]
        .firstWhere((e) => e.isNotEmpty, orElse: () => '');
    if (fileUrl.isEmpty) throw ResolveError('115 未返回下载链接');
    // CDN Cookie：优先 path 不是 "/" 的那一条
    String? cdn;
    for (final line in r.setCookieLines) {
      final pair = line.split(';').first.trim();
      if (!pair.contains('=')) continue;
      cdn ??= pair;
      final path = RX.first(r'[;\s]path=([^;]+)', line)?.trim();
      if (path != null && path.isNotEmpty && path != '/') {
        cdn = pair;
        break;
      }
    }
    final merged = [cookie, cdn ?? ''].where((e) => e.isNotEmpty).join('; ');
    return DownloadLink(data['fn'].s.ifEmpty(file.name), fileUrl, int.tryParse(data['fs'].s) ?? file.size,
        {'Cookie': merged, 'User-Agent': ua, 'Referer': 'https://115.com/'});
  }
}

// MARK: 光鸭

/// 光鸭云盘分享：匿名取分享访问令牌 → 游标分页 → 签名直链（受限分享需登录后转存，暂不支持）。
class GuangYaResolver implements ShareResolver {
  static const _api = 'https://api.guangyapan.com/userres/v1';
  final Map<String, String> _pwds = {};
  static String? _did;

  static Future<String> _deviceId() async {
    if (_did != null) return _did!;
    final prefs = await SharedPreferences.getInstance();
    var v = prefs.getString('guangya.deviceid') ?? '';
    if (v.isEmpty) {
      v = _hex(32);
      await prefs.setString('guangya.deviceid', v);
    }
    return _did = v;
  }

  Future<J> _post(String path, Map<String, Object?> body) async {
    final r = await Http.postJson('$_api/$path', body, headers: {
      'Accept': 'application/json, text/plain, */*',
      'User-Agent': UA.chrome,
      'Origin': 'https://www.guangyapan.com',
      'Referer': 'https://www.guangyapan.com/',
      'dt': '4',
      'traceparent': '00-${_hex(32)}-${_hex(16)}-01',
      'did': await _deviceId(),
    });
    return _json(r, '光鸭');
  }

  static void _check(J j, String fallback) {
    final code = j['code'].s;
    final ok = (!j['success'].exists || j['success'].b) && j['error'].s.isEmpty && (code.isEmpty || code == '0');
    if (ok) return;
    throw ResolveError(switch (code) {
      '209' => '光鸭分享提取码错误或缺失',
      '200' || '201' || '202' => '光鸭分享已取消、过期或不可访问',
      '205' || '206' || '207' || '504' => '光鸭分享下载受限（需要登录后转存，暂不支持），请在官网确认下载权限',
      _ => j.any(['msg', 'message', 'error_description']).ifEmpty('$fallback（code=$code）'),
    });
  }

  static J _data(J j) => j['data'].exists ? j['data'] : j;

  Future<String> _accessToken(String shareId, String pwd) async {
    final j = await _post('get_share_access_token', {'shareId': shareId, 'code': pwd});
    _check(j, '获取分享访问令牌失败');
    final t = _data(j).any(['accessToken', 'access_token']);
    if (t.isEmpty) throw ResolveError('光鸭分享链接无效');
    return t;
  }

  @override
  Future<ShareSession> open(ParsedShare share, String? pwd, String cookie) async {
    final code = pwd ?? '';
    _pwds[share.shareId] = code;
    final token = await _accessToken(share.shareId, code);
    var title = '光鸭分享';
    try {
      final t = _data(await _post('get_share_summary', {'shareId': share.shareId})).any(['title', 'shareName']);
      if (t.isNotEmpty) title = t;
    } catch (_) {}
    return ShareSession(SharePlatform.guangya, share.shareId, token, title, '');
  }

  /// 访问令牌有时效：每次列目录 / 取链前刷新一次，失败再用会话里那份
  Future<String> _fresh(ShareSession s) async {
    try {
      return await _accessToken(s.shareId, _pwds[s.shareId] ?? '');
    } catch (_) {
      return s.token;
    }
  }

  ShareFile _parse(J item) {
    final name = item.any(['fileName', 'name', 'filename', 'dirName', 'title']);
    final resType = item['resType'].s;
    final isDir = resType == '2'
        ? true
        : resType == '1'
            ? false
            : item['isDir'].b ||
                item['isdir'].b ||
                item['dir'].b ||
                item['isFolder'].b ||
                item['dirName'].s.isNotEmpty ||
                const ['folder', 'dir', 'directory', '0'].contains(item['type'].s.toLowerCase()) ||
                (!name.contains('.') && item['dirType'].s == '1');
    return ShareFile(
      id: item.any(['fileId', 'file_id', 'id', 'resId', 'resourceId']),
      name: name,
      size: int.tryParse(item.any(['fileSize', 'size', 'file_size'])) ?? 0,
      isDir: isDir,
      parentId: item.any(['parentId', 'parentFileId', 'parent_id']),
      modified: item.any(['updatedAt', 'updateAt', 'updateTime', 'mtime', 'createdAt', 'createTime']),
    );
  }

  @override
  Future<List<ShareFile>> list(ShareSession session, String dirId, String cookie) async {
    final token = await _fresh(session);
    final all = <ShareFile>[];
    final seen = <String>{};
    String? cursor;
    for (var i = 0; i < 1000; i++) {
      final j = await _post('get_share_page_files_list', {
        'parentId': dirId,
        'pageSize': 100,
        'orderBy': 0,
        'sortType': 0,
        'accessToken': token,
        if (cursor != null) 'cursor': int.tryParse(cursor) ?? cursor,
      });
      _check(j, '获取分享文件列表失败');
      final data = _data(j);
      final items = data.first(['list', 'items', 'files', 'records', 'content']).list.map(_parse).toList();
      for (final f in items) {
        if (seen.add(f.id)) all.add(f);
      }
      final next = data['cursor'].s;
      final bool more;
      if (data['hasMore'].exists) {
        more = data['hasMore'].b;
      } else if (data['total'].exists) {
        more = data['total'].i > 0 && (int.tryParse(next) ?? all.length) < data['total'].i;
      } else {
        more = items.length >= 100 && next.isNotEmpty;
      }
      if (!more || next.isEmpty) break;
      cursor = next;
    }
    return all;
  }

  @override
  Future<DownloadLink> downloadLink(ShareSession session, ShareFile file, String cookie) async {
    final j = await _post('get_share_download_url', {'fileId': file.id, 'accessToken': await _fresh(session)});
    _check(j, '获取下载地址失败');
    final data = _data(j);
    final url = data.any(['signedURL', 'signedUrl', 'downloadUrl', 'download_url', 'url', 'cdnUrl']);
    if (url.isEmpty) throw ResolveError('光鸭未返回有效下载地址，请确认下载权限');
    return DownloadLink(file.name, url, int.tryParse(data['size'].s) ?? file.size,
        const {'User-Agent': UA.chrome, 'Referer': 'https://www.guangyapan.com/'});
  }
}
