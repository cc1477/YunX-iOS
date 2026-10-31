// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import '../http.dart';
import '../json.dart';
import '../models.dart';
import '../text.dart';
import 'resolver.dart';

class _FolderParams {
  _FolderParams(this.lx, this.fid, this.t, this.k);
  final String lx, fid, t, k;
}

class _SharePage {
  _SharePage({
    required this.shareUrl,
    required this.origin,
    required this.title,
    required this.isFolder,
    required this.needsPwd,
    required this.fileId,
    required this.folder,
    required this.html,
    required this.single,
  });
  final String shareUrl, origin, title, html;
  final bool isFolder, needsPwd;
  final String? fileId;
  final _FolderParams? folder;
  final ShareFile? single;
}

/// 蓝奏云分享解析（匿名）：分享页 → 文件夹分页（filemoreajax）/ 单文件 → ajaxm/ajaxfile → HEAD 探测直链
/// （含 acw_sc__v2 人机校验与「验证并下载」）。
class LanzouResolver implements ShareResolver {
  static const ua = UA.chrome;
  final Map<String, _SharePage> _pages = {};
  final Map<String, Map<String, String>> _jar = {};

  static String _host(String url) => Uri.tryParse(url)?.host ?? '';

  static bool _isLanzouHost(String host) =>
      RX.first(r'^(?:[a-z0-9-]+\.)*(?:lanzou[a-z0-9-]*|lan[zs]o[ux]|lanzn)\.(?:com|net|org|cn)$', host, group: 0) != null;

  void _setCookie(String host, String name, String value) => (_jar[host] ??= {})[name] = value;

  String _cookie(String host, {String? extra}) =>
      [...(_jar[host] ?? {}).entries.map((e) => '${e.key}=${e.value}'), if (extra != null) extra].join('; ');

  @override
  Future<ShareSession> open(ParsedShare share, String? pwd, String cookie) async {
    final page = await _resolveShare(share.url);
    if (page.needsPwd && (pwd ?? '').isEmpty) throw ResolveError('此蓝奏分享需要提取码，请填写后重新解析');
    _pages[page.shareUrl] = page;
    return ShareSession(SharePlatform.lanzou, page.shareUrl, pwd ?? '', page.title, '');
  }

  @override
  Future<List<ShareFile>> list(ShareSession session, String dirId, String cookie) async {
    final page = _pages[session.shareId];
    if (page == null) throw ResolveError('蓝奏分享会话已失效，请重新解析');
    if (page.isFolder) return _listFolder(page, session.token);
    return page.single == null ? [] : [page.single!];
  }

  @override
  Future<DownloadLink> downloadLink(ShareSession session, ShareFile file, String cookie) async {
    final page = _pages[session.shareId];
    if (page == null) throw ResolveError('蓝奏分享会话已失效，请重新解析');
    return _shareDownloadLink(page, file, session.token.isEmpty ? null : session.token);
  }

  Future<_SharePage> _resolveShare(String shareUrl) async {
    var normalized = shareUrl.trim();
    if (normalized.toLowerCase().startsWith('http://')) normalized = 'https://${normalized.substring(7)}';
    normalized = normalized.split('#').first.trimTrailing('/');
    final html = await _fetchFollowing(normalized);
    final uri = Uri.parse(normalized);
    final origin = '${uri.scheme}://${uri.host}';
    final title = _extractTitle(html);
    final needsPwd = html.contains('请输入密码') ||
        html.contains('id="pwbox"') ||
        html.contains('input_password') ||
        html.contains('密码不正确') ||
        html.contains('function down_p(');
    final isFolder = html.contains('filemoreajax') || html.contains('class="filemore"') || html.contains('file_more');
    final fileId = RX.first(r'(?:ajaxm|ajaxfile)\.php\?file=(\d+)', html) ??
        RX.first(r'''name=["']file["']\s+value=["'](\d+)["']''', html) ??
        RX.first(r'file=(\d+)', html);
    _FolderParams? folder;
    if (isFolder) {
      final lx = _jsVar(html, 'lx'), t = _jsVar(html, 't'), k = _jsVar(html, 'k');
      if (lx != null && t != null && k != null) {
        folder = _FolderParams(lx, _jsVar(html, 'fid') ?? uri.pathSegments.lastWhere((e) => e.isNotEmpty, orElse: () => ''), t, k);
      }
    }
    ShareFile? single;
    if (!isFolder) {
      final m = RX.groups(r'(?:文件大小|大小)\s*[:：]\s*([\d.]+)\s*([KMGT]?)(?:i?B)?', html);
      single = ShareFile(
        id: uri.pathSegments.lastWhere((e) => e.isNotEmpty, orElse: () => ''),
        name: title,
        size: m == null ? 0 : Fmt.parseDisplaySize('${m[1]} ${m[2]}'),
        isDir: false,
      );
    }
    return _SharePage(
      shareUrl: normalized,
      origin: origin,
      title: title.ifEmpty('蓝奏分享'),
      isFolder: isFolder,
      needsPwd: needsPwd,
      fileId: fileId,
      folder: folder,
      html: html,
      single: single,
    );
  }

  Future<List<ShareFile>> _listFolder(_SharePage page, String pwd) async {
    final params = page.folder;
    if (params == null) throw ResolveError('蓝奏分享分页异常，请重试');
    final all = <ShareFile>[];
    final seen = <String>{};
    var pg = 1, retries = 0;
    while (pg <= 500) {
      if (pg > 1 || retries > 0) await Future.delayed(Duration(milliseconds: retries > 0 ? 600 * (retries + 1) : 250));
      J body;
      try {
        body = await _formPost('${page.origin}/filemoreajax.php', [
          MapEntry('lx', params.lx),
          MapEntry('fid', params.fid),
          MapEntry('t', params.t),
          MapEntry('k', params.k),
          MapEntry('pwd', pwd),
          MapEntry('pg', '$pg'),
        ], page.shareUrl, page.origin);
      } catch (_) {
        if (++retries > 2) throw ResolveError('蓝奏请求过于频繁，请稍后再试');
        continue;
      }
      switch (body['zt'].i) {
        case 4:
          if (++retries > 2) throw ResolveError('蓝奏请求过于频繁，请稍后再试');
          continue;
        case 2:
          return all;
        case 3:
          throw ResolveError('蓝奏提取码错误，请检查后重新解析');
        case 1:
          break;
        default:
          throw ResolveError('蓝奏解析失败，请确认分享链接和提取码后重试');
      }
      retries = 0;
      final items = body['text'].list;
      if (items.isEmpty) break;
      var added = 0;
      for (final item in items) {
        final ref = item['id'].s;
        final id = ref.split('?').first;
        if (id.isEmpty || !seen.add(id)) continue;
        all.add(ShareFile(
          id: id,
          name: item['name_all'].s.ifEmpty(item['name'].s).trim(),
          size: Fmt.parseDisplaySize(item['size'].s),
          isDir: false,
          token: ref.contains('?') ? '${page.origin}/$ref' : '',
          modified: item['time'].s,
        ));
        added++;
      }
      if (added == 0) throw ResolveError('蓝奏分页重复，请重新打开目录');
      pg++;
    }
    return all;
  }

  Future<DownloadLink> _shareDownloadLink(_SharePage page, ShareFile file, String? pwd) async {
    final origin = page.origin;
    var referer = file.token.isNotEmpty ? file.token : page.shareUrl;
    String html;
    if (file.token.isNotEmpty) {
      html = await _fetchFollowing(file.token);
    } else if (page.isFolder) {
      referer = '$origin/${file.id}';
      html = await _fetchFollowing(referer);
    } else {
      html = page.html;
    }
    final src = RX.first(r'''<iframe[^>]+src=["']([^"']+)["']''', html);
    if (src != null) {
      final iframe = _absolutize(origin, src);
      if (_host(iframe).toLowerCase() != _host(referer).toLowerCase()) throw ResolveError('蓝奏下载页面地址异常，请检查分享链接');
      html = await _fetchPage(iframe, referer);
      referer = iframe;
    }
    final fileId = (page.isFolder ? null : page.fileId) ??
        RX.first(r'(?:ajaxm|ajaxfile)\.php\?file=(\d+)', html) ??
        RX.first(r'file=(\d+)', html);
    if (fileId == null) throw ResolveError('蓝奏解析失败，请确认分享链接和提取码后重试');
    final pwdRequired = page.needsPwd || html.contains('function down_p(');
    if (pwdRequired && (pwd ?? '').isEmpty) throw ResolveError('此蓝奏分享需要提取码，请填写后重新解析');
    final withPwd = pwdRequired && (pwd ?? '').isNotEmpty;
    final ajaxUrl = _resolveAjaxUrl(html, origin, fileId, withPwd);
    final objects = _dataObjects(html).where((o) => o['action'] == 'downprocess' && (o['sign'] ?? '').isNotEmpty);
    final down = objects.isEmpty ? null : objects.last;
    final sign = down?['sign'] ?? _jsVar(html, 'wp_sign') ?? _jsVar(html, 'sign') ?? _inputValue(html, 'sign');
    if (sign == null) throw ResolveError('蓝奏分享页缺少下载参数，请重新解析');
    final fields = <MapEntry<String, String>>[const MapEntry('action', 'downprocess'), MapEntry('sign', sign)];
    if (withPwd) {
      fields.addAll([MapEntry('p', pwd!), const MapEntry('kd', '1')]);
    } else {
      final ajaxData = _jsVar(html, 'ajaxdata') ?? down?['signs'] ?? '';
      var key = down?['websignkey'] ?? '';
      if (key.isEmpty) key = ajaxData.isEmpty ? (_jsVar(html, 'websignkey') ?? _inputValue(html, 'websignkey') ?? '') : ajaxData;
      if (key.isEmpty) throw ResolveError('蓝奏分享页缺少下载参数，请重新解析');
      if (ajaxData.isNotEmpty) fields.add(MapEntry('signs', ajaxData));
      fields.addAll([
        MapEntry('websignkey', key),
        MapEntry('websign', down?['websign'] ?? _jsVar(html, 'websign') ?? ''),
        const MapEntry('kd', '1'),
        const MapEntry('ves', '1'),
      ]);
    }
    final json = await _formPost(ajaxUrl, fields, referer, origin);
    _validateAjax(json);
    final dom = json['dom'].s, rel = json['url'].s;
    final domUri = Uri.tryParse(dom);
    if (dom.isEmpty || rel.isEmpty || rel.startsWith('/') || rel.contains('://') || domUri == null || domUri.host.isEmpty) {
      throw ResolveError('蓝奏解析失败，请确认分享链接和提取码后重试');
    }
    final jump = '${domUri.scheme.ifEmpty('https')}://${domUri.host}/file/$rel';
    final (finalUrl, size) = await _probe(jump, origin);
    return DownloadLink(file.name.ifEmpty(json['inf'].s), finalUrl, size > 0 ? size : file.size, {
      'User-Agent': ua,
      'Referer': '$origin/',
      'Cookie': _cookie(_host(finalUrl), extra: 'down_ip=1'),
    });
  }

  Map<String, String> _dlHeaders(String url, String origin) =>
      {'User-Agent': ua, 'Referer': '$origin/', 'Cookie': _cookie(_host(url), extra: 'down_ip=1')};

  Future<(String, int)> _probe(String jump, String origin) async {
    var url = jump;
    _setCookie(_host(jump), 'down_ip', '1');
    final confirmed = <String>{}, challenged = <String>{}, visited = <String>{};
    for (var i = 0; i < 8; i++) {
      final host = _host(url);
      if (host.isEmpty) throw ResolveError('蓝奏下载地址暂时不可用，请稍后重试');
      if (!visited.add(url)) throw ResolveError('蓝奏下载地址循环跳转，请重新解析');
      final r = await Http.send(url, method: 'HEAD', headers: _dlHeaders(url, origin), followRedirects: false);
      if (r.status >= 300 && r.status < 400) {
        final loc = r.header('location');
        if (loc == null) throw ResolveError('蓝奏下载地址暂时不可用，请稍后重试');
        url = _absolutize(url, loc);
        continue;
      }
      if (r.status == 200 || r.status == 206) {
        if ((r.header('content-type') ?? '').contains('text/html')) {
          final body = (await Http.send(url, headers: _dlHeaders(url, origin))).text;
          final challenge = _challengeCookie(body);
          if (challenge != null) {
            if (!challenged.add(host)) throw ResolveError('蓝奏需要进一步验证，请在分享页完成验证后重试');
            _setCookie(host, 'acw_sc__v2', challenge);
            visited.remove(url);
            continue;
          }
          if (body.contains('验证并下载') && confirmed.add(host)) {
            final verified = await _submitVerify(url, body, origin);
            if (verified != null) {
              url = verified;
              continue;
            }
          }
          throw ResolveError('蓝奏返回的是验证页面，请稍后重试');
        }
        var size = _sizeOf(r);
        if (size <= 0) size = await _rangeProbe(url, origin);
        return (url, size);
      }
      if ([403, 404, 410].contains(r.status)) throw ResolveError('蓝奏下载地址已失效，请稍后重新解析');
      if (r.status == 429) throw ResolveError('蓝奏下载请求过于频繁，请稍后再试');
      final size = await _rangeProbe(url, origin);
      if (size > 0) return (url, size);
      throw ResolveError('蓝奏下载地址暂时不可用，请稍后重试');
    }
    throw ResolveError('蓝奏下载地址暂时不可用，请稍后重试');
  }

  Future<String?> _submitVerify(String nodeUrl, String html, String origin) async {
    final node = Uri.tryParse(nodeUrl);
    if (node == null || node.host.isEmpty) return null;
    final candidates = RX
        .all(r'data\s*:\s*\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}', html, dotAll: true)
        .map((g) => g[1])
        .where((s) => s.contains("'file'") || s.contains('"file"'));
    final data = candidates.isEmpty ? null : candidates.first;
    final file = (data == null ? null : RX.first(r'''['"]?file['"]?\s*:\s*['"]([^'"]+)['"]''', data)) ??
        RX.first(r'''name=["']file["'][^>]*value=["']([^"']+)["']''', html);
    final sign = (data == null ? null : RX.first(r'''['"]?sign['"]?\s*:\s*['"]([^'"]+)['"]''', data)) ??
        _jsVar(html, 'sign') ??
        _inputValue(html, 'sign');
    if (file == null || sign == null) return null;
    await Future.delayed(const Duration(seconds: 2));
    final J json;
    try {
      json = await _formPost(node.resolve('ajax.php').toString(),
          [MapEntry('file', file), const MapEntry('el', '2'), MapEntry('sign', sign)], nodeUrl, '${node.scheme}://${node.host}');
    } catch (_) {
      throw ResolveError('蓝奏下载验证服务暂时不可用，请稍后重试');
    }
    final url = json['url'].s;
    if (json['zt'].i != 1 || url.isEmpty) throw ResolveError(url.ifEmpty('蓝奏需要进一步验证，请稍后重试'));
    if (url == '?SignError') throw ResolveError('蓝奏下载验证已过期，请重新解析');
    return url;
  }

  Future<int> _rangeProbe(String url, String origin) async {
    final r = await Http.send(url, headers: {..._dlHeaders(url, origin), 'Range': 'bytes=0-0'}, followRedirects: false);
    final range = r.header('content-range');
    return range == null ? 0 : int.tryParse(range.split('/').last) ?? 0;
  }

  static int _sizeOf(RawResponse r) {
    final range = r.header('content-range');
    if (range != null) return int.tryParse(range.split('/').last) ?? 0;
    return r.status == 200 ? int.tryParse(r.header('content-length') ?? '') ?? 0 : 0;
  }

  Future<String> _fetchFollowing(String start) async {
    var current = start;
    final challenged = <String>{};
    for (var i = 0; i < 8; i++) {
      final host = _host(current);
      final cookie = _cookie(host);
      final r = await Http.send(current,
          headers: {'User-Agent': ua, 'Referer': current, if (cookie.isNotEmpty) 'Cookie': cookie}, followRedirects: false);
      if (r.status >= 300 && r.status < 400) {
        final loc = r.header('location');
        if (loc == null) throw ResolveError('蓝奏页面跳转次数过多，请重新解析');
        final next = _absolutize(current, loc);
        if (!_isLanzouHost(_host(next))) throw ResolveError('蓝奏分享链接无效');
        current = next;
        continue;
      }
      final body = r.text;
      final challenge = _challengeCookie(body);
      if (challenge != null) {
        if (!challenged.add(host)) throw ResolveError('蓝奏需要进一步验证，请稍后重试');
        _setCookie(host, 'acw_sc__v2', challenge);
        continue;
      }
      if (body.contains('文件已取消') || body.contains('不存在')) throw ResolveError('蓝奏文件已取消分享或不存在');
      if (body.contains('请求过于频繁') || body.contains('稍后再试')) throw ResolveError('蓝奏请求过于频繁，请稍后再试');
      return body;
    }
    throw ResolveError('蓝奏页面跳转次数过多，请重新解析');
  }

  Future<String> _fetchPage(String url, String referer) async {
    final cookie = _cookie(_host(url));
    final r = await Http.send(url, headers: {'User-Agent': ua, 'Referer': referer, if (cookie.isNotEmpty) 'Cookie': cookie});
    if (!r.ok) throw ResolveError('蓝奏文件已取消分享或不存在');
    return r.text;
  }

  Future<J> _formPost(String url, List<MapEntry<String, String>> fields, String referer, String origin) async {
    final cookie = _cookie(_host(url));
    final r = await Http.postForm(url, fields,
        headers: {
          'User-Agent': ua,
          'Referer': referer,
          'Origin': origin,
          'X-Requested-With': 'XMLHttpRequest',
          if (cookie.isNotEmpty) 'Cookie': cookie,
        },
        followRedirects: false);
    if (r.status == 429) throw ResolveError('蓝奏请求过于频繁，请稍后再试');
    final json = J.tryParse(r.text);
    if (json == null || !json.isMap) {
      if (r.text.trimLeft().startsWith('<')) throw ResolveError('蓝奏返回了验证页面，请稍后重试');
      throw ResolveError('蓝奏解析服务响应异常（HTTP ${r.status}），请稍后重试');
    }
    return json;
  }

  static void _validateAjax(J json) {
    if (json['zt'].i == 1) return;
    final inf = json['inf'].s;
    if (inf.contains('密码') || inf.contains('提取码')) throw ResolveError('蓝奏提取码错误，请检查后重新解析');
    if (['不存在', '取消', '过期', '删除'].any(inf.contains)) throw ResolveError('蓝奏文件已取消分享或不存在');
    if (['频繁', '次数', '稍后'].any(inf.contains)) throw ResolveError('蓝奏请求过于频繁，请稍后再试');
    throw ResolveError('蓝奏解析失败，请确认分享链接和提取码后重试');
  }

  static String _extractTitle(String html) {
    final t = RX.first(r'<title>([^<]*)</title>', html);
    if (t != null) {
      final clean = t.replaceAll(' - 蓝奏云', '').replaceAll('蓝奏云', '').trim();
      if (clean.isNotEmpty && !clean.contains('密码')) return clean;
    }
    final n = RX.first(r'''class=["']n["']>([^<]+)<''', html);
    if (n != null) return n.trim();
    return RX.first(r'''var\s+filename\s*=\s*['"]([^'"]+)['"]''', html) ?? '';
  }

  static String? _jsVar(String html, String name) {
    final g = RX.groups('(?:(?:var|let|const)\\s+)?${RegExp.escape(name)}\\s*=\\s*[\'"]([^\'"]*)[\'"]', html,
        ignoreCase: false);
    return g?[1];
  }

  static String? _inputValue(String html, String name) {
    final n = RegExp.escape(name);
    return RX.first('<input[^>]*name=["\']$n["\'][^>]*value=["\']([^"\']*)["\']', html) ??
        RX.first('<input[^>]*value=["\']([^"\']*)["\'][^>]*name=["\']$n["\']', html);
  }

  static String _resolveAjaxUrl(String html, String origin, String fileId, bool withPwd) {
    final fromScript = RX.first(
        r'''['"]?url['"]?\s*:\s*['"]((?:\./)?[^'"]*ajax(?:m|file)\.php\?file=\d+[^'"]*)['"]''', html,
        ignoreCase: false);
    if (fromScript != null) return _absolutize(origin, fromScript);
    final d1 = _jsVar(html, 'domain1');
    if (d1 != null && d1.contains('/ajax')) return d1;
    final d2 = _jsVar(html, 'domain2');
    if (d2 != null && d2.contains('/ajax')) return d2;
    final abs = RX.first(r'''https?://[^'"\s]+/(?:ajaxm|ajaxfile)\.php\?file=\d+''', html, group: 0, ignoreCase: false);
    if (abs != null) return abs;
    return withPwd ? '$origin/ajaxfile.php?file=$fileId' : '$origin/ajaxm.php?file=$fileId';
  }

  /// 解析页面里 `data : { … }` 形式的 JS 对象（值可以是字符串、数字或同页 var 变量名）
  static List<Map<String, String>> _dataObjects(String html) {
    return RX.all(r'\bdata\s*:\s*\{([^{}]*)\}', html, dotAll: true).map((m) {
      final result = <String, String>{};
      for (final p in RX.all(
          r'''(?:['"]([A-Za-z_][\w]*)['"]|([A-Za-z_][\w]*))\s*:\s*('(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|[A-Za-z_][\w]*|\d+)''',
          m[1],
          ignoreCase: false)) {
        final key = p[1].isEmpty ? p[2] : p[1];
        final raw = p[3];
        if (raw.startsWith("'") || raw.startsWith('"')) {
          result[key] = raw.substring(1, raw.length - 1);
        } else if (RegExp(r'^\d+$').hasMatch(raw)) {
          result[key] = raw;
        } else {
          final v = _jsVar(html, raw);
          if (v != null) result[key] = v;
        }
      }
      return result;
    }).toList();
  }

  static String _absolutize(String base, String target) {
    if (target.startsWith('http://') || target.startsWith('https://')) return target;
    final uri = Uri.tryParse(base);
    if (uri == null || uri.host.isEmpty) return target;
    if (target.startsWith('//')) return '${uri.scheme}:$target';
    return Uri.parse('${uri.scheme}://${uri.host}${uri.path.isEmpty ? '/' : uri.path}').resolve(target).toString();
  }

  static String? _challengeCookie(String source) {
    final arg1 = RX.first(r"\barg1\s*=\s*'([0-9A-Fa-f]{40})'", source, ignoreCase: false);
    return arg1 == null ? null : acwScV2(arg1);
  }

  /// acw_sc__v2：按固定位置重排 40 位十六进制后与掩码逐字节异或
  static String acwScV2(String arg1) {
    const pos = [
      15, 35, 29, 24, 33, 16, 1, 38, 10, 9, 19, 31, 40, 27, 22, 23, 25, 13, 6, 11, //
      39, 18, 20, 8, 14, 21, 32, 26, 2, 30, 7, 4, 17, 5, 3, 28, 34, 37, 12, 36,
    ];
    const mask = '3000176000856006061501533003690027800375';
    final q = List.filled(pos.length, '0');
    for (var x = 0; x < arg1.length; x++) {
      for (var z = 0; z < pos.length; z++) {
        if (pos[z] == x + 1) q[z] = arg1[x];
      }
    }
    final u = q.join();
    final out = StringBuffer();
    for (var i = 0; i + 2 <= u.length && i + 2 <= mask.length; i += 2) {
      final a = int.parse(u.substring(i, i + 2), radix: 16);
      final b = int.parse(mask.substring(i, i + 2), radix: 16);
      out.write((a ^ b).toRadixString(16).padLeft(2, '0'));
    }
    return out.toString();
  }
}
