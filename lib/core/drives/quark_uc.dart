// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import '../http.dart';
import '../json.dart';
import '../models.dart';
import '../text.dart';
import 'resolver.dart';

J _checked(RawResponse response, String name, Map<int, String> codes) {
  final json = J.tryParse(response.text);
  if (json == null) throw ResolveError('$name 响应解析失败（HTTP ${response.status}）');
  final ok = json['status'].i == 200 || (json['code'].exists && json['code'].i == 0);
  if (!ok) {
    final known = codes[json['code'].i];
    if (known != null) throw ResolveError(known);
    final message = json['message'].s;
    throw ResolveError(message.isEmpty ? '$name 请求失败' : '$name：$message');
  }
  return json;
}

ShareFile _fileFrom(J item) => ShareFile(
      id: item['fid'].s,
      name: item['file_name'].s,
      size: item['size'].i,
      isDir: item['dir'].b,
      parentId: item['pdir_fid'].s,
      token: item['share_fid_token'].s,
      modified: Fmt.date(item['updated_at'].i ~/ 1000),
    );

/// 夸克网盘：token → sharepage/detail 分页 → file/download 免转存取链。
/// 未登录走游客态，服务端随响应下发 `__pugs`，下载时必须带上（缺了 CDN 412），约 50MB 上限。
class QuarkResolver implements ShareResolver {
  static const apiUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch';
  static const _base = 'https://drive-pc.quark.cn/1/clouddrive';
  static const _codes = {
    23018: '该文件超出游客可获取的大小上限（约 50MB），请先在「账号」页登录夸克网盘',
    31001: '该分享需要登录夸克网盘后才能下载',
  };
  String _guestPugs = '';

  Map<String, String> _headers(String cookie) => {
        'User-Agent': apiUA,
        'Origin': 'https://pan.quark.cn',
        'Referer': 'https://pan.quark.cn/',
        if (cookie.isNotEmpty) 'Cookie': cookie,
      };

  static Future<String?> fetchNickname(String cookie) async {
    try {
      final r = await Http.send('https://pan.quark.cn/account/info', headers: {'Cookie': cookie, 'User-Agent': apiUA});
      final json = J.tryParse(r.text);
      return json != null && json['success'].b ? json['data']['nickname'].s : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<ShareSession> open(ParsedShare share, String? pwd, String cookie) async {
    final r = await Http.postJson('$_base/share/sharepage/token?pr=ucpro&fr=pc',
        {'pwd_id': share.shareId, 'passcode': pwd ?? '', 'support_visit_limit_private_share': true},
        headers: _headers(cookie));
    final data = _checked(r, '夸克', _codes)['data'];
    final stoken = data['stoken'].s;
    if (stoken.isEmpty) throw ResolveError('夸克未返回分享凭证，请检查提取码');
    return ShareSession(SharePlatform.quark, share.shareId, stoken, data['title'].s.ifEmpty('夸克分享'), '0');
  }

  @override
  Future<List<ShareFile>> list(ShareSession session, String dirId, String cookie) async {
    final all = <ShareFile>[];
    const size = 100;
    for (var page = 1; page <= 50; page++) {
      final url = '$_base/share/sharepage/detail?pr=ucpro&fr=pc&pwd_id=${session.shareId}'
          '&stoken=${Http.q(session.token)}&pdir_fid=$dirId&ver=2&force=0&_page=$page&_size=$size'
          '&_fetch_banner=0&_fetch_share=0&fetch_relate_conversation=0&_fetch_total=1&_sort=file_type:asc,file_name:asc';
      final json = _checked(await Http.send(url, headers: _headers(cookie)), '夸克', _codes);
      final items = json['data']['list'].list;
      all.addAll(items.map(_fileFrom));
      final total = json['metadata']['_total'].i;
      if (items.length < size || (total > 0 && all.length >= total)) break;
    }
    return all;
  }

  @override
  Future<DownloadLink> downloadLink(ShareSession session, ShareFile file, String cookie) async {
    final guest = cookie.isEmpty;
    final requestCookie = guest ? _guestPugs : cookie;
    final r = await Http.postJson(
      '$_base/file/download?pr=ucpro&fr=pc&sys=win32&ve=3.23.2',
      {
        'fids': [file.id],
        'fids_token': [file.token],
        'pwd_id': session.shareId,
        'stoken': session.token,
        'speedup_session': '',
        'token': '',
      },
      headers: {'User-Agent': apiUA, if (requestCookie.isNotEmpty) 'Cookie': requestCookie},
    );
    // 游客态令牌与本次直链同响应绑定，必须用这次下发的那一份
    final pugs = r.cookies['__pugs'];
    if (pugs != null && pugs.isNotEmpty) _guestPugs = '__pugs=$pugs';
    final item = _checked(r, '夸克', _codes)['data'][0];
    final url = item['download_url'].s;
    if (url.isEmpty) throw ResolveError('夸克未返回下载链接');
    final downloadCookie = guest ? _guestPugs : cookie;
    return DownloadLink(
      item['file_name'].s.ifEmpty(file.name),
      url,
      item['size'].i > 0 ? item['size'].i : file.size,
      {'User-Agent': apiUA, 'Referer': 'https://pan.quark.cn/', if (downloadCookie.isNotEmpty) 'Cookie': downloadCookie},
    );
  }
}

/// UC 网盘：与夸克同一套接口结构，域名 / 参数 / UA 不同。
/// 列目录必须用 transfer_share/detail（带 stoken）；登录态视频优先走 video_preview 取原画直链。
class UCResolver implements ShareResolver {
  static const webUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  static const guestUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch';
  static const guestSecChUa = '"Not=A?Brand";v="99", "Chromium";v="100", "Google Chrome";v="100"';
  static const _base = 'https://pc-api.uc.cn/1/clouddrive';
  static const _origin = 'https://drive.uc.cn';
  static const _videoExts = {'mp4', 'mkv', 'mov', 'avi', 'webm', 'flv', 'ts', 'm3u8', 'wmv', 'rmvb'};
  static const _codes = {
    31001: '该分享需要登录 UC 网盘后才能下载',
    23018: '该文件超出游客可获取的大小上限，请先在「账号」页登录 UC 网盘',
    14001: '分享已失效或提取码有误，请重新解析',
    41020: '文件令牌已过期，请重新解析分享',
  };
  String _guestPugs = '';

  static Future<String?> fetchNickname(String cookie) async {
    try {
      final r = await Http.send('$_origin/account/info', headers: {'Cookie': cookie, 'User-Agent': webUA});
      final json = J.tryParse(r.text);
      return json != null && json['success'].b ? json['data']['nickname'].s : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<ShareSession> open(ParsedShare share, String? pwd, String cookie) async {
    final r = await Http.postJson('$_base/share/sharepage/token?pr=UCBrowser&fr=pc',
        {'pwd_id': share.shareId, 'passcode': pwd ?? '', 'share_for_transfer': true},
        headers: {'User-Agent': webUA, if (cookie.isNotEmpty) 'Cookie': cookie});
    final data = _checked(r, 'UC', _codes)['data'];
    final stoken = data['stoken'].s;
    if (stoken.isEmpty) throw ResolveError('UC 未返回分享凭证，请检查提取码');
    return ShareSession(SharePlatform.uc, share.shareId, stoken, data['title'].s.ifEmpty('UC 分享'), '0');
  }

  @override
  Future<List<ShareFile>> list(ShareSession session, String dirId, String cookie) async {
    final headers = {
      'User-Agent': webUA,
      'Origin': 'https://fast.uc.cn',
      'Referer': 'https://fast.uc.cn/',
      if (cookie.isNotEmpty) 'Cookie': cookie,
    };
    final all = <ShareFile>[];
    const size = 50;
    for (var page = 1; page <= 100; page++) {
      final url = '$_base/transfer_share/detail?entry=ft&fr=pc&pr=UCBrowser&pwd_id=${session.shareId}&pdir_fid=$dirId'
          '&fetch_file_list=1&passcode=&_page=$page&_size=$size&_fetch_total=1&_fetch_task=1&_fetch_share=1&_sort='
          '&stoken=${Http.q(session.token)}';
      final data = _checked(await Http.send(url, headers: headers), 'UC', _codes)['data'];
      final items = data['list'].exists ? data['list'].list : data['detail_info']['list'].list;
      all.addAll(items.map(_fileFrom));
      if (items.length < size) break;
    }
    return all;
  }

  Map<String, String> _downloadHeaders(String cookie, bool guest) => {
        'Referer': '$_origin/',
        'Origin': _origin,
        'User-Agent': guest ? guestUA : webUA,
        if (guest) 'Sec-Ch-Ua': guestSecChUa,
        if (cookie.isNotEmpty) 'Cookie': cookie,
      };

  @override
  Future<DownloadLink> downloadLink(ShareSession session, ShareFile file, String cookie) async {
    final guest = cookie.isEmpty;
    final dot = file.name.lastIndexOf('.');
    final ext = dot < 0 ? '' : file.name.substring(dot + 1).toLowerCase();
    if (!guest && _videoExts.contains(ext)) {
      final preview = await _videoPreview(session, file, cookie);
      if (preview != null) return preview;
    }
    final headers = guest
        ? {'User-Agent': guestUA, 'Sec-Ch-Ua': guestSecChUa, if (_guestPugs.isNotEmpty) 'Cookie': _guestPugs}
        : {'User-Agent': webUA, 'Cookie': cookie};
    final r = await Http.postJson(
      '$_base/file/download?entry=ft&fr=pc&pr=UCBrowser',
      {
        'fids': [file.id],
        'pwd_id': session.shareId,
        'stoken': session.token,
        'fids_token': [file.token],
      },
      headers: headers,
    );
    final pugs = r.cookies['__pugs'];
    if (pugs != null && pugs.isNotEmpty) _guestPugs = '__pugs=$pugs';
    final item = _checked(r, 'UC', _codes)['data'][0];
    final url = item['download_url'].s;
    if (url.isEmpty) throw ResolveError('UC 未返回下载链接');
    return DownloadLink(file.name.ifEmpty(item['file_name'].s), url, item['size'].i > 0 ? item['size'].i : file.size,
        _downloadHeaders(guest ? _guestPugs : cookie, guest));
  }

  Future<DownloadLink?> _videoPreview(ShareSession session, ShareFile file, String cookie) async {
    try {
      final url = '$_base/share/sharepage/video_preview?pr=UCBrowser&fr=h5&pwd_id=${Http.q(session.shareId)}'
          '&stoken=${Http.q(session.token)}&fid=${Http.q(file.id)}&fid_token=${Http.q(file.token)}';
      final r = await Http.send(url,
          headers: {'Cookie': cookie, 'User-Agent': webUA, 'Origin': _origin, 'Referer': '$_origin/'});
      final json = J.tryParse(r.text);
      if (json == null || !(json['status'].i == 200 || json['code'].i == 0)) return null;
      final info = json['data']['play_info'];
      if (info['url'].s.isEmpty) return null;
      return DownloadLink(
          file.name, info['url'].s, info['size'].i > 0 ? info['size'].i : file.size, _downloadHeaders(cookie, false));
    } catch (_) {
      return null;
    }
  }
}
