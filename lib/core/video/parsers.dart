// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import '../http.dart';
import '../json.dart';
import '../models.dart';
import '../text.dart';
import 'video_http.dart';

// MARK: 哔哩哔哩

/// 已登录优先取 DASH 高清（音视频分轨，下载后由原生 AVFoundation 合轨），否则退回 fnval=1 单文件
class BilibiliParser extends VideoParser {
  @override
  VideoPlatform get platform => VideoPlatform.bilibili;

  static const _view = 'https://api.bilibili.com/x/web-interface/view';
  static const _play = 'https://api.bilibili.com/x/player/playurl';

  Map<String, String> _h(String cookie) =>
      {'User-Agent': UA.chrome, 'Referer': 'https://www.bilibili.com/', if (cookie.isNotEmpty) 'Cookie': cookie};

  @override
  Future<String?> validateCookie(String cookie) async {
    if (cookie.isEmpty) return null;
    try {
      final j = await VHttp.json('https://api.bilibili.com/x/web-interface/nav', headers: _h(cookie));
      return j['data']['isLogin'].b ? j['data']['uname'].s : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<VideoParseResult> parse(DetectedVideoLink link, String cookie) async {
    final query = link.id.toLowerCase().startsWith('bv') ? 'bvid=${link.id}' : 'aid=${link.id.replaceAll('av', '')}';
    final view = await VHttp.json('$_view?$query', headers: _h(cookie), what: 'B站视频信息');
    if (view['code'].i != 0) throw VideoParseError(VideoErrorKind.notFound, 'B站返回 code=${view['code'].i}');
    final data = view['data'];
    final bvid = data['bvid'].s;
    var cid = data['pages'][0]['cid'].i;
    if (cid <= 0) cid = data['cid'].i;
    if (bvid.isEmpty || cid <= 0) throw VideoParseError(VideoErrorKind.unknown, 'B站视频信息缺少 bvid/cid');
    final base = fileBase(data['title'].s, 'bilibili_$bvid');

    if (cookie.isNotEmpty) {
      final dash = await _dash(bvid, cid, cookie);
      if (dash != null) {
        return _result(data, bvid, VideoMedia(
          url: dash.$1,
          kind: MediaKind.video,
          fileName: '$base.mp4',
          headers: _h(cookie),
          quality: '${_label(dash.$3)} · 分轨',
          audioUrl: dash.$2,
          audioHeaders: _h(cookie),
        ));
      }
    }
    final play = await VHttp.json(
        '$_play?bvid=$bvid&cid=$cid&qn=80&fnval=1&fnver=0&fourk=1&platform=html5&high_quality=1',
        headers: _h(cookie),
        what: 'B站取直链');
    final first = play['data']['durl'][0];
    if (!first.exists) throw VideoParseError(VideoErrorKind.unsupported, 'B站未返回可下载的直链：该视频可能是番剧或付费内容');
    final url = first['url'].s;
    if (url.isEmpty) throw VideoParseError(VideoErrorKind.blocked, 'B站直链为空');
    return _result(data, bvid, VideoMedia(
      url: url,
      kind: MediaKind.video,
      fileName: '$base.mp4',
      size: first['size'].i,
      headers: _h(cookie),
      quality: _label(play['data']['quality'].i),
    ));
  }

  VideoParseResult _result(J data, String bvid, VideoMedia media) => VideoParseResult(
        platform: platform,
        title: data['title'].s,
        author: data['owner']['name'].s,
        avatar: data['owner']['face'].s,
        cover: data['pic'].s,
        text: data['desc'].s,
        timestamp: data['pubdate'].i,
        url: 'https://www.bilibili.com/video/$bvid',
        medias: [media],
      );

  Future<(String, String, int)?> _dash(String bvid, int cid, String cookie) async {
    try {
      final j = await VHttp.json('$_play?bvid=$bvid&cid=$cid&qn=120&fnval=4048&fnver=0&fourk=1', headers: _h(cookie));
      final dash = j['data']['dash'];
      final videos = dash['video'].list, audios = dash['audio'].list;
      if (videos.isEmpty || audios.isEmpty) return null;
      videos.sort((a, b) => b['id'].i.compareTo(a['id'].i));
      audios.sort((a, b) => b['id'].i.compareTo(a['id'].i));
      final v = videos.first.any(['baseUrl', 'base_url']), a = audios.first.any(['baseUrl', 'base_url']);
      if (v.isEmpty || a.isEmpty) return null;
      return (v, a, videos.first['id'].i);
    } catch (_) {
      return null;
    }
  }

  static String _label(int qn) => switch (qn) {
        6 || 7 => '240P',
        16 => '360P',
        32 => '480P',
        64 => '720P',
        74 => '720P60',
        80 => '1080P',
        112 => '1080P+',
        116 => '1080P60',
        120 => '4K',
        125 => 'HDR',
        126 => '杜比视界',
        _ => qn > 0 ? '画质 $qn' : '',
      };
}

// MARK: 快手

class KuaishouParser extends VideoParser {
  @override
  VideoPlatform get platform => VideoPlatform.kuaishou;

  @override
  Future<VideoParseResult> parse(DetectedVideoLink link, String cookie) async {
    final headers = {'User-Agent': UA.iPhone, 'Referer': 'https://v.kuaishou.com/', if (cookie.isNotEmpty) 'Cookie': cookie};
    var pageUrl = link.url;
    try {
      pageUrl = await VHttp.expandRedirect(pageUrl, headers: headers) ?? pageUrl;
    } catch (_) {}
    pageUrl = pageUrl.replaceAll('/fw/long-video/', '/fw/photo/');
    final html = await VHttp.text(pageUrl, headers: headers, what: '快手作品页');
    final raw = VHttp.inlineJson(html, 'window.INIT_STATE');
    final state = raw == null ? null : J.tryParse(raw);
    if (state == null) throw VideoParseError(VideoErrorKind.unknown, '快手页面里没有作品数据（作品可能已删除或页面改版）');
    final photo = state.keys.map((k) => state[k]['photo']).firstWhere((p) => p.isMap,
        orElse: () => throw VideoParseError(VideoErrorKind.unknown, '快手页面里没有作品数据'));
    final title = photo['caption'].s;
    final base = fileBase(title, 'kuaishou_${link.id.ifEmpty('${DateTime.now().millisecondsSinceEpoch}')}');
    final medias = <VideoMedia>[];
    final video = photo['mainMvUrls'].list.map((e) => e['url'].s).firstWhere((e) => e.isNotEmpty, orElse: () => '');
    if (video.isNotEmpty) {
      medias.add(VideoMedia(url: video, kind: MediaKind.video, fileName: '$base.mp4', headers: headers));
    }
    final atlas = photo['ext_params']['atlas'];
    final cdn = atlas['cdnList'][0]['cdn'].s;
    if (cdn.isNotEmpty) {
      final routes = atlas['list'].list.map((e) => e.s).where((e) => e.isNotEmpty).toList();
      for (var i = 0; i < routes.length; i++) {
        medias.add(VideoMedia(url: 'https://$cdn/${routes[i]}', kind: MediaKind.image, fileName: '${base}_${i + 1}.jpg', headers: headers));
      }
    }
    return VideoParseResult(
      platform: platform,
      title: title,
      author: photo['userName'].s.replaceAll('ㅤ', '').trim(),
      avatar: photo['headUrl'].s,
      cover: photo['coverUrls'].list.map((e) => e['url'].s).firstWhere((e) => e.isNotEmpty, orElse: () => ''),
      timestamp: photo['timestamp'].i ~/ 1000,
      url: link.url,
      medias: medias,
    );
  }
}

// MARK: AcFun

class AcFunParser extends VideoParser {
  @override
  VideoPlatform get platform => VideoPlatform.acfun;

  @override
  Future<VideoParseResult> parse(DetectedVideoLink link, String cookie) async {
    final headers = {'User-Agent': UA.chrome, 'Referer': 'https://www.acfun.cn/', if (cookie.isNotEmpty) 'Cookie': cookie};
    final html = await VHttp.text('https://www.acfun.cn/v/ac${link.id}?quickViewId=videoInfo_new&ajaxpipe=1',
        headers: headers, what: 'AcFun 视频');
    final raw = VHttp.inlineJson(html, 'window.videoInfo');
    if (raw == null) throw VideoParseError(VideoErrorKind.notFound, 'AcFun 页面里没有 videoInfo（可能已删除）');
    // 内嵌 JSON 被转义了一层，按安卓版同样的方式手工还原
    final text = raw.replaceAll(r'\\"', r'\"').replaceAll(r'\"', '"').replaceAll(r'\\/', '/');
    final info = J.tryParse(text);
    if (info == null) throw VideoParseError(VideoErrorKind.unknown, 'AcFun 视频信息解析失败');
    var play = info['currentVideoInfo']['ksPlayJson'];
    if (!play.isMap) play = J.tryParse(play.s) ?? const J(null);
    final urls = play['adaptationSet'][0]['representation'].list.map((e) => e['url'].s).where((e) => e.isNotEmpty).toList();
    if (urls.isEmpty) throw VideoParseError(VideoErrorKind.unknown, 'AcFun 未取到视频流地址');
    final title = info['title'].s;
    return VideoParseResult(
      platform: platform,
      title: title,
      author: info['user']['name'].s,
      cover: info['coverUrl'].s,
      text: info['description'].s,
      url: link.url,
      medias: [
        VideoMedia(
          url: urls.length > 3 ? urls[3] : urls.first,
          kind: MediaKind.video,
          fileName: '${fileBase(title, 'AcFun_${link.id}')}.ts',
          isHls: true,
          headers: headers,
          quality: 'HLS',
        ),
      ],
    );
  }
}

// MARK: 微博

class WeiboParser extends VideoParser {
  @override
  VideoPlatform get platform => VideoPlatform.weibo;

  Map<String, String> _media(String cookie) =>
      {'User-Agent': UA.chrome, 'Referer': 'https://weibo.com/', if (cookie.isNotEmpty) 'Cookie': cookie};

  @override
  Future<VideoParseResult> parse(DetectedVideoLink link, String cookie) => switch (link.kind) {
        'status' => _status(link, link.id, cookie),
        'tv' => _status(link, mid2id(link.id), cookie),
        'fid' => _fid(link, cookie),
        _ => throw VideoParseError(VideoErrorKind.unsupported, '不支持的微博链接形态'),
      };

  Future<VideoParseResult> _status(DetectedVideoLink link, String id, String cookie) async {
    final r = await VHttp.request('https://m.weibo.cn/statuses/show?id=$id&_=${DateTime.now().millisecondsSinceEpoch}',
        headers: {
          'accept': 'application/json, text/plain, */*',
          'referer': 'https://m.weibo.cn/detail/$id',
          'origin': 'https://m.weibo.cn',
          'x-requested-with': 'XMLHttpRequest',
          'mweibo-pwa': '1',
          'User-Agent': UA.chrome,
          if (cookie.isNotEmpty) 'Cookie': cookie,
        },
        follow: false);
    if ([403, 418, 429].contains(r.status)) throw VideoParseError(VideoErrorKind.blocked, '微博被风控拦截');
    if ([404, 410].contains(r.status)) throw VideoParseError(VideoErrorKind.notFound, '微博内容不存在');
    if (r.status != 200) throw VideoParseError(VideoErrorKind.unknown, '微博数据获取失败（HTTP ${r.status}）');
    if (!(r.header('content-type') ?? '').contains('application/json')) {
      throw VideoParseError(VideoErrorKind.blocked, '微博接口返回的不是 JSON，多半被风控拦截');
    }
    final json = J.tryParse(r.text);
    if (json == null || !json['data'].isMap) throw VideoParseError(VideoErrorKind.notFound, '微博内容不存在或已删除');
    return _build(link, json['data'], cookie, true);
  }

  VideoParseResult _build(DetectedVideoLink link, J data, String cookie, bool allowRetweet) {
    final headers = _media(cookie);
    final page = data['page_info'];
    final title = page['title'].s;
    final base = fileBase(title, '微博_${link.id}');
    final medias = <VideoMedia>[];
    final urls = page['urls'];
    final video = [urls['mp4_720p_mp4'].s, urls['mp4_hd_mp4'].s, urls['mp4_ld_mp4'].s].firstWhere((e) => e.isNotEmpty, orElse: () => '');
    if (video.isNotEmpty) medias.add(VideoMedia(url: video, kind: MediaKind.video, fileName: '$base.mp4', headers: headers));
    var n = 0;
    for (final pic in data['pics'].list) {
      final url = pic['large']['url'].s;
      if (url.isEmpty) continue;
      n++;
      final motion = pic['videoSrc'].s;
      medias.add(VideoMedia(
          url: url,
          kind: MediaKind.image,
          fileName: '${base}_$n.jpg',
          headers: headers,
          quality: motion.isEmpty ? '原图' : '动图',
          motionUrl: motion));
    }
    if (medias.isEmpty && allowRetweet && data['retweeted_status'].isMap) {
      return _build(link, data['retweeted_status'], cookie, false);
    }
    final user = data['user'];
    final bid = data['bid'].s;
    final uid = user['id'].i;
    return VideoParseResult(
      platform: platform,
      title: title,
      author: user['screen_name'].s,
      avatar: user['profile_image_url'].s,
      cover: page['page_pic']['url'].s,
      text: cleanHtml(data['text'].s),
      timestamp: _weiboTime(data['created_at'].s),
      url: uid > 0 && bid.isNotEmpty ? 'https://weibo.com/$uid/$bid' : link.url,
      medias: medias,
    );
  }

  Future<VideoParseResult> _fid(DetectedVideoLink link, String cookie) async {
    final r = await VHttp.request('https://h5.video.weibo.com/api/component?page=/show/${link.id}',
        method: 'POST',
        headers: {
          'Referer': 'https://h5.video.weibo.com/show/${link.id}',
          'User-Agent': UA.chrome,
          'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
          if (cookie.isNotEmpty) 'Cookie': cookie,
        },
        body: Http.formEncode([MapEntry('data', '{"Component_Play_Playinfo":{"oid":"${link.id}"}}')]).codeUnits);
    VHttp.requireOk(r, '微博视频');
    final data = J.tryParse(r.text)?['data']['Component_Play_Playinfo'];
    if (data == null || !data.isMap) throw VideoParseError(VideoErrorKind.notFound, '微博视频数据为空（作品可能已删除）');
    final title = data['title'].s;
    final urls = data['urls'];
    final keys = [...urls.keys]..sort();
    final video = (keys.isNotEmpty ? urls[keys.first].s : data['stream_url'].s).secureUrl;
    return VideoParseResult(
      platform: platform,
      title: title,
      author: data['reward']['user']['name'].s,
      avatar: data['reward']['user']['profile_image_url'].s,
      cover: data['cover_image'].s,
      text: cleanHtml(data['text'].s),
      url: link.url,
      medias: [
        if (video.isNotEmpty)
          VideoMedia(url: video, kind: MediaKind.video, fileName: '${fileBase(title, '微博_${link.id}')}.mp4', headers: _media(cookie)),
      ],
    );
  }

  static String cleanHtml(String raw) => raw.replaceAll('<br />', '\n').replaceAll(RegExp(r'<[^>]*>'), '').trim();

  static int _weiboTime(String text) {
    // 形如 "Sat Oct 31 12:00:00 +0800 2026"
    final g = RX.groups(r'\w{3} (\w{3}) (\d{2}) (\d{2}):(\d{2}):(\d{2}) ([+-]\d{4}) (\d{4})', text);
    if (g == null) return 0;
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final month = months.indexOf(g[1]) + 1;
    if (month == 0) return 0;
    final utc = DateTime.utc(int.parse(g[7]), month, int.parse(g[2]), int.parse(g[3]), int.parse(g[4]), int.parse(g[5]));
    final sign = g[6].startsWith('-') ? -1 : 1;
    final offset = Duration(hours: int.parse(g[6].substring(1, 3)), minutes: int.parse(g[6].substring(3, 5))) * sign;
    return utc.subtract(offset).millisecondsSinceEpoch ~/ 1000;
  }

  static String _base62(int n) {
    const a = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
    if (n == 0) return '0';
    var s = '';
    while (n > 0) {
      s = a[n % 62] + s;
      n ~/= 62;
    }
    return s;
  }

  /// 微博 mid（纯数字）→ 62 进制 id：倒序每 7 位一段分别编码
  static String mid2id(String mid) {
    final r = mid.split('').reversed.join();
    if (r.isEmpty) return '';
    final size = (r.length + 6) ~/ 7;
    final chunks = <String>[];
    for (var i = 0; i < size; i++) {
      final end = (i + 1) * 7 < r.length ? (i + 1) * 7 : r.length;
      final piece = r.substring(i * 7, end).split('').reversed.join();
      var enc = _base62(int.tryParse(piece) ?? 0);
      if (i < size - 1 && enc.length < 4) enc = enc.padLeft(4, '0');
      chunks.add(enc);
    }
    return chunks.reversed.join();
  }
}
