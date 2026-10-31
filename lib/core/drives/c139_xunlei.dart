// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../http.dart';
import '../json.dart';
import '../models.dart';
import 'resolver.dart';

String _md5(String s) =>
    MD5Digest().process(Uint8List.fromList(utf8.encode(s))).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String _rand(String pool, int n) {
  final r = Random.secure();
  return List.generate(n, (_) => pool[r.nextInt(pool.length)]).join();
}

// MARK: 139

/// 139 网盘（和彩云）分享：请求体 AES-128-CBC 加密（随机 IV 拼在密文前），响应同样加密、可能再 gzip 一层。
/// 列目录匿名可用；取直链需要登录账号 + Authorization，并带 mcloud-sign 签名头。
class C139Resolver implements ShareResolver {
  static const pcUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  static const _mobileUA =
      'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Mobile Safari/537.36';
  static final _key = Uint8List.fromList(utf8.encode('PVGDwmcvfs1uV3d1'));
  static const _base = 'https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/IOutLink';

  static String? _cookie(String cookie, String name) {
    for (final part in cookie.split(';')) {
      final kv = part.trim();
      if (kv.startsWith('$name=') && kv.length > name.length + 1) return kv.substring(name.length + 1);
    }
    return null;
  }

  static bool isValidCookie(String c) =>
      _cookie(c, 'authorization') != null || (_cookie(c, 'Os_SSo_Sid') != null && _cookie(c, 'RMKEY') != null);

  static String? _b64(String text) {
    try {
      var t = Uri.decodeComponent(text);
      while (t.length % 4 != 0) {
        t += '=';
      }
      return utf8.decode(base64.decode(t));
    } catch (_) {
      return null;
    }
  }

  static String? account(String cookie) {
    final enc = _cookie(cookie, 'ORCHES-I-ACCOUNT-ENCRYPT');
    final decoded = enc == null ? null : _b64(enc);
    if (decoded != null && decoded.isNotEmpty) return decoded;
    final auth = _cookie(cookie, 'authorization');
    if (auth != null) {
      final parts = _b64(auth.replaceAll('Basic', '').trim())?.split(':') ?? const [];
      if (parts.length > 1 && parts[1].isNotEmpty) return parts[1];
    }
    return _cookie(cookie, 'Login_UserNumber');
  }

  static Uint8List _aes(bool encrypt, Uint8List input, Uint8List iv) {
    final cipher = PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(AESEngine()))
      ..init(encrypt, PaddedBlockCipherParameters(ParametersWithIV(KeyParameter(_key), iv), null));
    return cipher.process(input);
  }

  static String encrypt(String plain) {
    final r = Random.secure();
    final iv = Uint8List.fromList(List.generate(16, (_) => r.nextInt(256)));
    return base64.encode([...iv, ..._aes(true, Uint8List.fromList(utf8.encode(plain)), iv)]);
  }

  static String? decrypt(String b64) {
    try {
      final raw = base64.decode(b64.trim());
      if (raw.length <= 16) return null;
      var plain = _aes(false, Uint8List.fromList(raw.sublist(16)), Uint8List.fromList(raw.sublist(0, 16)));
      if (plain.length > 2 && plain[0] == 0x1f && plain[1] == 0x8b) plain = Uint8List.fromList(gzip.decode(plain));
      return utf8.decode(plain);
    } catch (_) {
      return null;
    }
  }

  /// 与 JS encodeURIComponent 一致（Java URLEncoder + 替换），`~` 会被编码
  static String _encodeURIComponent(String s) {
    const keep = '-_.*!\'()';
    final out = StringBuffer();
    for (final b in utf8.encode(s)) {
      final c = String.fromCharCode(b);
      final alnum = (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a);
      if (b < 0x80 && (alnum || keep.contains(c))) {
        out.write(c);
      } else {
        out.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }

  static String sign(String body) {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final ts = '${n.year}-${two(n.month)}-${two(n.day)} ${two(n.hour)}:${two(n.minute)}:${two(n.second)}';
    final rand = _rand('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789', 16);
    final sorted = (_encodeURIComponent(body).split('')..sort()).join();
    final b64 = base64.encode(utf8.encode(sorted));
    return '$ts,$rand,${_md5(_md5(b64) + _md5('$ts:$rand')).toUpperCase()}';
  }

  Future<J> _post(String path, Map<String, Object?> object, {String? authorization, bool signed = false}) async {
    final plain = jsonEncode(object);
    final r = await Http.send('$_base/$path', method: 'POST', headers: {
      'hcy-cool-flag': '1',
      'x-deviceinfo': '||3|12.27.0|||||chrome 150.0.0.0|360X444|zh-cn|||',
      'x-huawei-channelsrc': '10245500',
      'x-mm-source': '0002',
      'Content-Type': 'application/json;charset=UTF-8',
      'User-Agent': _mobileUA,
      'Origin': 'https://yun.139.com',
      'Referer': 'https://yun.139.com/',
      'Accept': 'application/json, text/plain, */*',
      if (authorization != null && authorization.isNotEmpty) 'Authorization': authorization,
      if (signed) 'mcloud-sign': sign(plain),
    }, body: utf8.encode(encrypt(plain)));
    final decrypted = decrypt(r.text);
    final j = (decrypted == null ? null : J.tryParse(decrypted)) ?? J.tryParse(r.text);
    if (j == null) throw ResolveError('139 响应解析失败（HTTP ${r.status}）');
    return j;
  }

  static void _check(J j, String fallback) {
    final code = j['resultCode'].s;
    if ((code.isNotEmpty && code != '0') || (j['success'].exists && !j['success'].b)) {
      final desc = j['desc'].s;
      throw ResolveError(desc.isEmpty ? '$fallback（$code）' : '139：$desc');
    }
  }

  @override
  Future<ShareSession> open(ParsedShare share, String? pwd, String cookie) async {
    final j = await _post('getOutLinkGeneral', {
      'getOutLinkGeneralReq': {'linkID': share.shareId, 'isPasswd': 1, 'account': ''}
    });
    final g = j['data']['getOutLinkGeneralResp']['outLinkGeneral'][0];
    // 分享接口会直接回带提取码，用户没填时用它
    final code = (pwd ?? '').isEmpty ? g['passwd'].s : pwd!;
    final title = g['lkName'].s;
    return ShareSession(SharePlatform.c139, share.shareId, code, title.isEmpty ? share.shareId : title, 'root');
  }

  @override
  Future<List<ShareFile>> list(ShareSession session, String dirId, String cookie) async {
    final pca = dirId.isEmpty || dirId == '0' ? 'root' : dirId;
    final all = <ShareFile>[];
    for (var begin = 1; begin <= 20000; begin += 200) {
      final j = await _post('getOutLinkInfoV6', {
        'getOutLinkInfoReq': {
          'account': '',
          'linkID': session.shareId,
          'passwd': session.token,
          'caSrt': 1,
          'coSrt': 1,
          'srtDr': 0,
          'bNum': begin,
          'pCaID': pca,
          'eNum': begin + 199,
        }
      });
      _check(j, '获取文件列表失败');
      final data = j['data'];
      final batch = [
        for (final c in data['caLst'].list)
          ShareFile(id: c['caID'].s, name: c['caName'].s, size: 0, isDir: true, parentId: pca, modified: c.any(['udTime', 'ctTime'])),
        for (final c in data['coLst'].list)
          ShareFile(
            id: c['coID'].s,
            name: c['coName'].s,
            size: c['coSize'].i,
            isDir: c['isdir'].exists ? c['isdir'].b : c['coType'].i == 2,
            parentId: pca,
            modified: c.any(['udTime', 'ctTime']),
          ),
      ];
      all.addAll(batch);
      if (batch.length < 200) break;
    }
    return all;
  }

  @override
  Future<DownloadLink> downloadLink(ShareSession session, ShareFile file, String cookie) async {
    final acc = account(cookie);
    if (acc == null) throw ResolveError('139 网盘需要登录后才能下载，请先在「账号」页登录');
    final j = await _post(
        'dlFromOutLinkV3',
        {
          'dlFromOutLinkReqV3': {
            'account': acc,
            'linkID': session.shareId,
            'coIDLst': {
              'item': [file.id]
            },
            'commonAccountInfo': {'account': acc, 'accountType': 1},
          }
        },
        authorization: _cookie(cookie, 'authorization'),
        signed: true);
    _check(j, '获取下载链接失败');
    final url = j['data']['redrUrl'].s;
    if (url.isEmpty) throw ResolveError('139 未返回下载链接');
    return DownloadLink(file.name, url, file.size, const {'User-Agent': pcUA});
  }
}

// MARK: 迅雷

class XunleiTokens {
  XunleiTokens(this.access, this.deviceId, this.captcha, this.sub, this.nickname);
  final String access, deviceId, captcha, sub, nickname;
}

/// 迅雷网盘分享：浏览匿名即可；下载需要网页登录态（pan.xunlei.com 的 localStorage 凭证），
/// 转存到临时目录 → 取文件直链 → 删除转存。登录态接口都要带网页端 captcha 令牌。
class XunleiResolver implements ShareResolver {
  static const webClientId = 'Xqp0kJBXWhwaTpB6';
  static const _webVersion = '1.93.10';
  static const _webHost = 'pan.xunlei.com';
  static const _salts = [
    'DVM8BRQfJWDsIE0JbH5GCUM0z0jU1yGymBTj4Eyloazv1F+w0G7ig',
    'T',
    'a1fUxfjOO1/dW++DpGupRgw9P93L',
    'aktKbp+/lQc3MvlMHIupt65LjAgJOL6ttMFvTKK+7+WKubSf9rT',
    'SB/ne9FQUnQmWz4Wuv9KqKfGOBOCUubpHpECxOHfD4hNoMclYA2Yq',
    'sOZFBQ8IMFy3OFjAIf/eA65iqFvS9TIKzLyrhiT6',
    'ZhJdLgL7MGh2GanboB0yk',
    'Osf',
    'v',
  ];
  static const appUA =
      'ANDROID-com.xunlei.downloadprovider/8.31.0.9726 netWorkType/5G appid/40 deviceName/Xiaomi_M2004j7ac deviceModel/M2004J7AC OSVersion/12 protocolVersion/301 platformVersion/10 sdkVersion/512000 Oauth2Client/0.9 (Linux 4_14_186-perf-gddfs8vbb238b) (JAVA 0)';
  static const _webUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';
  static const _pan = 'https://api-pan.xunlei.com/drive/v1';
  final Map<String, (String, DateTime)> _captchas = {};
  final Map<String, String> _passCodes = {};
  static String? _guest;

  /// 在登录页里读 localStorage 凭证（返回 encodeURIComponent 过的 JSON；没登录返回空串）
  static const readScript = '''
(function(){try{
  var prefix='credentials_$webClientId';
  var sub=localStorage.getItem('current_sub');
  var raw=sub?localStorage.getItem(prefix+'@'+sub):localStorage.getItem(prefix);
  if(!raw)return '';
  var data=JSON.parse(raw);
  if(!data||typeof data!=='object'||Array.isArray(data))return '';
  try{var c=JSON.parse(localStorage.getItem('captcha_$webClientId')||'{}');
    if(c&&c.token&&Date.parse(c.expires_at)>Date.now())data.captcha_token=c.token;}catch(e){}
  try{var all=document.cookie.split(';');
    for(var i=0;i<all.length;i++){var s=all[i].trim();if(s.indexOf('deviceid=')!==0)continue;
      var d=decodeURIComponent(s.slice(9));data.device_id=(d.indexOf('.')>-1&&d.length>32)?d.split('.')[1].slice(0,32):d;break;}}catch(e){}
  return encodeURIComponent(JSON.stringify(data));
}catch(e){return ''}})()
''';

  static String _jwt(String token, String key) {
    final parts = token.split('.');
    if (parts.length < 2) return '';
    try {
      return J.tryParse(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))))?[key].s ?? '';
    } catch (_) {
      return '';
    }
  }

  static XunleiTokens? tokens(String stored) {
    String text;
    try {
      text = Uri.decodeComponent(stored);
    } catch (_) {
      text = stored;
    }
    final j = J.tryParse(text);
    if (j == null) return null;
    final access = j.any(['access_token', 'accessToken']);
    if (access.isEmpty) return null;
    var sub = j.any(['sub', 'user_id', 'userId']);
    if (sub.isEmpty) sub = _jwt(access, 'sub');
    return XunleiTokens(access, j.any(['device_id', 'deviceId']), j.any(['captcha_token', 'captchaToken']), sub,
        j.any(['nick_name', 'nickname', 'name', 'user_name']));
  }

  /// 保存前校验：拿到凭证且 access_token 未过期
  static String? validate(String stored) {
    final t = tokens(stored);
    if (t == null) return null;
    final exp = int.tryParse(_jwt(t.access, 'exp')) ?? 0;
    if (exp > 0 && exp < DateTime.now().millisecondsSinceEpoch ~/ 1000) return null;
    return t.nickname;
  }

  static Future<String> _guestDevice() async {
    if (_guest != null) return _guest!;
    final prefs = await SharedPreferences.getInstance();
    var v = prefs.getString('xunlei.deviceid') ?? '';
    if (v.isEmpty) {
      v = _rand('0123456789abcdef', 32);
      await prefs.setString('xunlei.deviceid', v);
    }
    return _guest = v;
  }

  Future<String> _captcha(String device, String action, String sub, String fallback, {bool force = false}) async {
    final cached = _captchas[device];
    if (!force && cached != null && cached.$2.isAfter(DateTime.now())) return cached.$1;
    final ts = DateTime.now().millisecondsSinceEpoch;
    var h = '$webClientId$_webVersion$_webHost$device$ts';
    for (final s in _salts) {
      h = _md5(h + s);
    }
    try {
      final r = await Http.send('https://xluser-ssl.xunlei.com/v1/shield/captcha/init',
          method: 'POST',
          headers: {
            'Accept': '*/*',
            'Content-Type': 'text/plain;charset=UTF-8',
            'Origin': 'https://pan.xunlei.com',
            'Referer': 'https://pan.xunlei.com/',
            'User-Agent': UA.chrome,
          },
          body: utf8.encode(jsonEncode({
            'client_id': webClientId,
            'action': action,
            'device_id': device,
            'meta': {
              'username': '',
              'phone_number': '',
              'email': '',
              'package_name': _webHost,
              'client_version': _webVersion,
              'captcha_sign': '1.$h',
              'timestamp': '$ts',
              'user_id': sub,
            },
          })));
      final j = J.tryParse(r.text);
      final token = j?['captcha_token'].s ?? '';
      if (token.isEmpty) return fallback;
      final ttl = max(60, j!['expires_in'].exists ? j['expires_in'].i : 300);
      _captchas[device] = (token, DateTime.now().add(Duration(seconds: ttl - 30)));
      return token;
    } catch (_) {
      return fallback;
    }
  }

  Future<J> _call(String url, String action, XunleiTokens? t, {String method = 'GET', Object? body}) async {
    final device = t != null && t.deviceId.isNotEmpty ? t.deviceId : await _guestDevice();
    var captcha = t == null ? '' : await _captcha(device, action, t.sub, t.captcha);
    for (var attempt = 0; attempt < 2; attempt++) {
      final r = await Http.send(url,
          method: method,
          headers: {
            'User-Agent': _webUA,
            'X-Device-Id': device,
            'X-Client-Version': '8.31.0.9726',
            'Content-Type': 'application/json',
            'Origin': 'https://pan.xunlei.com',
            'Referer': 'https://pan.xunlei.com/',
            if (t != null) 'Authorization': 'Bearer ${t.access}',
            if (captcha.isNotEmpty) 'X-Captcha-Token': captcha,
          },
          body: body == null ? null : utf8.encode(jsonEncode(body)));
      final j = J.tryParse(r.text);
      if (j == null) throw ResolveError('迅雷响应解析失败（HTTP ${r.status}）');
      final err = j['error'].s;
      if (r.ok && err.isEmpty) return j['data'].isMap ? j['data'] : j;
      if (r.status == 401 || err == 'unauthenticated') throw ResolveError('迅雷登录已过期，请在「账号」页重新登录');
      if (err == 'captcha_invalid' && attempt == 0 && t != null) {
        captcha = await _captcha(device, action, t.sub, '', force: true);
        if (captcha.isNotEmpty) continue;
      }
      final msg = j.any(['error_description', 'message']);
      throw ResolveError(msg.isEmpty ? (err.isEmpty ? '迅雷请求失败（HTTP ${r.status}）' : err) : '迅雷：$msg');
    }
    throw ResolveError('迅雷验证码刷新后仍失败，请稍后重试');
  }

  static List<ShareFile> _files(J data) => data['files']
      .list
      .map((f) => ShareFile(
            id: f['id'].s,
            name: f['name'].s,
            size: f['size'].i,
            isDir: f['kind'].s == 'drive#folder',
            parentId: f['parent_id'].s,
            modified: (f['modified_time'].s.length > 16 ? f['modified_time'].s.substring(0, 16) : f['modified_time'].s)
                .replaceAll('T', ' '),
          ))
      .toList();

  Future<J> _sharePage(String shareId, String pwd, String pageToken, XunleiTokens? t) async {
    final data = await _call(
        '$_pan/share?share_id=$shareId&pass_code=${Http.q(pwd)}&limit=100&page_token=${Http.q(pageToken)}&thumbnail_size=SIZE_SMALL',
        'GET:/drive/v1/share',
        t);
    switch (data['share_status'].s) {
      case 'PASS_CODE_EMPTY':
      case 'PASS_CODE_NEED':
        throw ResolveError('该迅雷分享需要提取码');
      case 'PASS_CODE_ERROR':
        throw ResolveError('迅雷提取码错误');
    }
    return data;
  }

  @override
  Future<ShareSession> open(ParsedShare share, String? pwd, String cookie) async {
    final code = pwd ?? '';
    _passCodes[share.shareId] = code;
    final data = await _sharePage(share.shareId, code, '', tokens(cookie));
    final title = data['title'].s;
    return ShareSession(SharePlatform.xunlei, share.shareId, data['pass_code_token'].s, title.isEmpty ? '迅雷分享' : title, '');
  }

  @override
  Future<List<ShareFile>> list(ShareSession session, String dirId, String cookie) async {
    final t = tokens(cookie);
    final all = <ShareFile>[];
    var pageToken = '';
    for (var i = 0; i < 100; i++) {
      final J data;
      if (dirId.isEmpty || dirId == '0') {
        data = await _sharePage(session.shareId, _passCodes[session.shareId] ?? '', pageToken, t);
      } else {
        data = await _call(
            '$_pan/share/detail?share_id=${session.shareId}&parent_id=$dirId&pass_code_token=${Http.q(session.token)}'
            '&limit=100&page_token=${Http.q(pageToken)}&thumbnail_size=SIZE_SMALL',
            'GET:/drive/v1/share/detail',
            t);
      }
      all.addAll(_files(data));
      pageToken = data['next_page_token'].s;
      if (pageToken.isEmpty) break;
    }
    return all;
  }

  @override
  Future<DownloadLink> downloadLink(ShareSession session, ShareFile file, String cookie) async {
    final t = tokens(cookie);
    if (t == null) throw ResolveError('迅雷网盘需要登录后才能下载，请先在「账号」页登录');
    final filter = Http.q('{"trashed":{"eq":false}}');
    final root = await _call('$_pan/files?parent_id=&page_token=&limit=100&with_audit=true&filters=$filter', 'GET:/drive/v1/files', t);
    final existing = _files(root).where((f) => f.isDir && f.name == 'YunX临时转存').map((f) => f.id).toList();
    var dirId = existing.isEmpty ? '' : existing.first;
    if (dirId.isEmpty) {
      final created = await _call('$_pan/files', 'POST:/drive/v1/files', t,
          method: 'POST', body: {'kind': 'drive#folder', 'name': 'YunX临时转存', 'parent_id': '', 'space': ''});
      dirId = created['id'].s;
    }
    if (dirId.isEmpty) throw ResolveError('迅雷创建临时目录失败');
    final restored = await _call('$_pan/share/restore', 'POST:/drive/v1/share/restore', t, method: 'POST', body: {
      'share_id': session.shareId,
      'pass_code_token': session.token,
      'parent_id': dirId,
      'ancestor_ids': <String>[],
      'file_ids': [file.id],
      'specify_parent_id': true,
    });
    var newId = J.tryParse(restored['params']['trace_file_ids'].s)?[file.id].s ?? '';
    if (newId.isEmpty) newId = restored['file_id'].s;
    if (newId.isEmpty) throw ResolveError('迅雷转存失败（网盘空间不足时也会失败）');
    var url = '';
    var size = file.size;
    // 转存是异步的，直链为空时稍等重试
    for (var i = 0; i < 6 && url.isEmpty; i++) {
      if (i > 0) await Future.delayed(const Duration(seconds: 1));
      final d = await _call('$_pan/files/$newId?_magic=2021&usage=PLAY&thumbnail_size=SIZE_LARGE&with=task',
          'GET:/drive/v1/files/$newId', t);
      url = d['links']['application/octet-stream']['url'].s.ifEmptyThen(d['web_content_link'].s);
      if (d['size'].i > 0) size = d['size'].i;
    }
    try {
      await _call('$_pan/files:batchDelete', 'POST:/drive/v1/files:batchDelete', t, method: 'POST', body: {
        'ids': [newId],
        'space': '',
      });
    } catch (_) {}
    if (url.isEmpty) throw ResolveError('迅雷未返回下载链接，请稍后重试');
    // 迅雷直链必须用官方 App UA，浏览器 UA 会被 CDN 降级
    return DownloadLink(file.name, url, size, const {'User-Agent': appUA});
  }
}

extension on String {
  String ifEmptyThen(String other) => isEmpty ? other : this;
}
