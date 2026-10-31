// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import 'http.dart';
import 'models.dart';
import 'text.dart';

enum DownloadState { queued, running, paused, completed, failed }

extension DownloadStateLabel on DownloadState {
  String get label => switch (this) {
        DownloadState.queued => '等待中',
        DownloadState.running => '下载中',
        DownloadState.paused => '已暂停',
        DownloadState.completed => '已完成',
        DownloadState.failed => '失败',
      };
}

enum DownloadKind { file, hls, dash }

class DownloadItem {
  DownloadItem({
    String? id,
    required this.fileName,
    required this.url,
    required this.headers,
    this.kind = DownloadKind.file,
    this.audioUrl = '',
    this.audioHeaders = const {},
    required this.source,
    required this.sourceLogo,
    this.totalBytes = 0,
    this.receivedBytes = 0,
    this.state = DownloadState.queued,
    this.errorMessage = '',
    DateTime? createdAt,
    this.completedAt,
    this.localPath = '',
    this.stepDone = 0,
    this.stepTotal = 0,
  })  : id = id ?? '${DateTime.now().microsecondsSinceEpoch}${fileName.hashCode & 0xffff}',
        createdAt = createdAt ?? DateTime.now();

  final String id;
  String fileName;
  final String url;
  final Map<String, String> headers;
  DownloadKind kind;
  String audioUrl;
  Map<String, String> audioHeaders;
  final String source, sourceLogo;
  int totalBytes, receivedBytes;
  DownloadState state;
  String errorMessage;
  final DateTime createdAt;
  DateTime? completedAt;
  String localPath;

  /// HLS 已完成分片数 / DASH 已完成阶段
  int stepDone, stepTotal;

  double get progress {
    if (kind == DownloadKind.hls && stepTotal > 0) return stepDone / stepTotal;
    if (totalBytes <= 0) return 0;
    return (receivedBytes / totalBytes).clamp(0, 1).toDouble();
  }

  FileKind get fileKind => FileKind.of(fileName);

  Map<String, dynamic> toJson() => {
        'id': id,
        'fileName': fileName,
        'url': url,
        'headers': headers,
        'kind': kind.name,
        'audioUrl': audioUrl,
        'audioHeaders': audioHeaders,
        'source': source,
        'sourceLogo': sourceLogo,
        'totalBytes': totalBytes,
        'receivedBytes': receivedBytes,
        'state': state.name,
        'errorMessage': errorMessage,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'completedAt': completedAt?.millisecondsSinceEpoch,
        'localPath': localPath,
        'stepDone': stepDone,
        'stepTotal': stepTotal,
      };

  factory DownloadItem.fromJson(Map<String, dynamic> j) => DownloadItem(
        id: j['id'] as String,
        fileName: j['fileName'] as String,
        url: j['url'] as String,
        headers: Map<String, String>.from(j['headers'] as Map),
        kind: DownloadKind.values.byName(j['kind'] as String),
        audioUrl: j['audioUrl'] as String? ?? '',
        audioHeaders: Map<String, String>.from(j['audioHeaders'] as Map? ?? {}),
        source: j['source'] as String,
        sourceLogo: j['sourceLogo'] as String,
        totalBytes: j['totalBytes'] as int? ?? 0,
        receivedBytes: j['receivedBytes'] as int? ?? 0,
        state: DownloadState.values.byName(j['state'] as String),
        errorMessage: j['errorMessage'] as String? ?? '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(j['createdAt'] as int),
        completedAt: j['completedAt'] == null ? null : DateTime.fromMillisecondsSinceEpoch(j['completedAt'] as int),
        localPath: j['localPath'] as String? ?? '',
        stepDone: j['stepDone'] as int? ?? 0,
        stepTotal: j['stepTotal'] as int? ?? 0,
      );
}

class _Paused implements Exception {}

class _Job {
  bool cancelled = false;
  HttpClientResponse? response;
  void cancel() {
    cancelled = true;
    response?.detachSocket().then((s) => s.destroy()).catchError((_) {});
  }
}

/// 下载管理：排队调度、并发上限、暂停 / 断点续传（Range 续写 .part 文件）、HLS 分片、DASH 合轨。
/// 下载目录在 Documents/云析，iOS「文件」App 可见。
class DownloadManager extends ChangeNotifier {
  static const _media = MethodChannel('yunx/media');
  final HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 30);

  List<DownloadItem> items = [];
  final Map<String, double> speeds = {};
  final Map<String, _Job> _jobs = {};
  final Map<String, (DateTime, int)> _ticks = {};
  int Function() maxConcurrent = () => 3;
  bool Function() autoSaveToPhotos = () => false;
  late Directory downloadDir, workDir;
  late File _stateFile;
  Timer? _notifyTimer;

  Future<void> load() async {
    final docs = await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    final temp = await getTemporaryDirectory();
    downloadDir = Directory('${docs.path}/云析')..createSync(recursive: true);
    workDir = Directory('${temp.path}/YunXWork')..createSync(recursive: true);
    support.createSync(recursive: true);
    _stateFile = File('${support.path}/downloads.json');
    try {
      if (_stateFile.existsSync()) {
        items = (jsonDecode(_stateFile.readAsStringSync()) as List)
            .map((e) => DownloadItem.fromJson(e as Map<String, dynamic>))
            .toList();
        for (final i in items) {
          if (i.state == DownloadState.running || i.state == DownloadState.queued) i.state = DownloadState.paused;
        }
      }
    } catch (_) {}
    notifyListeners();
  }

  List<DownloadItem> get active => items.where((i) => i.state != DownloadState.completed).toList();
  List<DownloadItem> get completed => items.where((i) => i.state == DownloadState.completed).toList()
    ..sort((a, b) => (b.completedAt ?? b.createdAt).compareTo(a.completedAt ?? a.createdAt));
  int get runningCount => items.where((i) => i.state == DownloadState.running).length;
  double get totalSpeed => speeds.values.fold(0, (a, b) => a + b);

  // MARK: 入队

  void enqueueLink(DownloadLink link, String source, String logo) {
    _add(DownloadItem(
      fileName: link.fileName.sanitizedFileName.ifEmpty('download'),
      url: link.url,
      headers: link.headers,
      source: source,
      sourceLogo: logo,
      totalBytes: link.size > 0 ? link.size : 0,
    ));
  }

  void enqueueMedia(VideoMedia media, VideoParseResult result) {
    final name = media.fileName.ifEmpty('${result.platform.displayName}_${DateTime.now().millisecondsSinceEpoch}');
    final item = DownloadItem(
      fileName: name.sanitizedFileName,
      url: media.url,
      headers: media.headers,
      source: result.platform.displayName,
      sourceLogo: result.platform.logo,
      totalBytes: media.size > 0 ? media.size : 0,
    );
    if (media.isHls) {
      item.kind = DownloadKind.hls;
    } else if (media.audioUrl.isNotEmpty) {
      item
        ..kind = DownloadKind.dash
        ..audioUrl = media.audioUrl
        ..audioHeaders = media.audioHeaders
        ..stepTotal = 3;
    }
    _add(item);
    // 动图：把动态部分作为独立视频一并下载
    if (media.motionUrl.isNotEmpty) {
      final dot = name.lastIndexOf('.');
      _add(DownloadItem(
        fileName: '${dot > 0 ? name.substring(0, dot) : name}_live.mp4'.sanitizedFileName,
        url: media.motionUrl,
        headers: media.headers,
        source: result.platform.displayName,
        sourceLogo: result.platform.logo,
      ));
    }
  }

  void _add(DownloadItem item) {
    items.insert(0, item);
    _changed();
    _schedule();
  }

  // MARK: 控制

  DownloadItem? _find(String id) {
    for (final i in items) {
      if (i.id == id) return i;
    }
    return null;
  }

  void pause(String id) {
    final job = _jobs[id];
    if (job != null) {
      job.cancel();
    } else {
      _find(id)?.state = DownloadState.paused;
      _changed();
    }
  }

  void resume(String id) {
    final item = _find(id);
    if (item == null) return;
    item
      ..state = DownloadState.queued
      ..errorMessage = '';
    _changed();
    _schedule();
  }

  void toggle(DownloadItem item) {
    switch (item.state) {
      case DownloadState.running:
      case DownloadState.queued:
        pause(item.id);
      case DownloadState.paused:
      case DownloadState.failed:
        resume(item.id);
      case DownloadState.completed:
        break;
    }
  }

  void pauseAll() {
    for (final i in [...items]) {
      if (i.state == DownloadState.running || i.state == DownloadState.queued) pause(i.id);
    }
  }

  void resumeAll() {
    for (final i in [...items]) {
      if (i.state == DownloadState.paused || i.state == DownloadState.failed) resume(i.id);
    }
  }

  void delete(String id, {bool removeFile = true}) {
    _jobs.remove(id)?.cancel();
    final item = _find(id);
    if (item != null) {
      if (removeFile && item.localPath.isNotEmpty) {
        try {
          File(item.localPath).deleteSync();
        } catch (_) {}
      }
      for (final suffix in ['.part', '_v.part', '_a.part', '.ts']) {
        try {
          File('${workDir.path}/${item.id}$suffix').deleteSync();
        } catch (_) {}
      }
    }
    items.removeWhere((i) => i.id == id);
    speeds.remove(id);
    _changed();
    _schedule();
  }

  void clearCompleted({required bool removeFiles}) {
    for (final i in completed) {
      delete(i.id, removeFile: removeFiles);
    }
  }

  // MARK: 调度

  void _schedule() {
    final limit = maxConcurrent().clamp(1, 6);
    while (_jobs.length < limit) {
      DownloadItem? next;
      for (final i in items.reversed) {
        if (i.state == DownloadState.queued && !_jobs.containsKey(i.id)) {
          next = i;
          break;
        }
      }
      if (next == null) break;
      _start(next);
    }
  }

  void _start(DownloadItem item) {
    final job = _Job();
    _jobs[item.id] = job;
    item.state = DownloadState.running;
    _ticks[item.id] = (DateTime.now(), item.receivedBytes);
    _changed();
    () async {
      try {
        final String path;
        switch (item.kind) {
          case DownloadKind.file:
            path = await _fetch(item, item.url, item.headers, File('${workDir.path}/${item.id}.part'), job, 0);
          case DownloadKind.hls:
            path = await _runHls(item, job);
          case DownloadKind.dash:
            path = await _runDash(item, job);
        }
        await _finish(item, path);
      } on _Paused {
        item.state = DownloadState.paused;
      } catch (e) {
        if (job.cancelled) {
          item.state = DownloadState.paused;
        } else {
          item
            ..state = DownloadState.failed
            ..errorMessage = '$e';
        }
      }
      _jobs.remove(item.id);
      speeds.remove(item.id);
      _changed();
      _schedule();
    }();
  }

  /// 单文件 Range 续传：.part 已有 L 字节就从 L 开始；服务端不支持 Range（返回 200）则从头重写
  Future<String> _fetch(DownloadItem item, String url, Map<String, String> headers, File part, _Job job, int offsetBase) async {
    final existing = part.existsSync() ? part.lengthSync() : 0;
    final request = await _client.getUrl(Uri.parse(url));
    headers.forEach((k, v) => request.headers.set(k, v, preserveHeaderCase: true));
    if (existing > 0) request.headers.set('Range', 'bytes=$existing-');
    final response = await request.close();
    job.response = response;
    if (response.statusCode == 416 && existing > 0) {
      await response.drain<void>();
      return part.path;
    }
    if (response.statusCode >= 400) {
      await response.drain<void>();
      throw AppError('服务器返回 HTTP ${response.statusCode}，直链可能已过期，请重新解析');
    }
    final append = response.statusCode == 206 && existing > 0;
    var received = append ? existing : 0;
    final length = response.contentLength;
    final total = length > 0 ? length + received : 0;
    if (total > 0 && item.kind == DownloadKind.file) item.totalBytes = total;
    final sink = part.openWrite(mode: append ? FileMode.append : FileMode.write);
    try {
      await for (final chunk in response) {
        if (job.cancelled) throw _Paused();
        sink.add(chunk);
        received += chunk.length;
        _progress(item, offsetBase + received);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    if (job.cancelled) throw _Paused();
    return part.path;
  }

  Future<String> _runHls(DownloadItem item, _Job job) async {
    final segments = await _playlist(item.url, item.headers);
    item.stepTotal = segments.length;
    final out = File('${workDir.path}/${item.id}.ts');
    if (item.stepDone == 0 || !out.existsSync()) {
      out.writeAsBytesSync(const []);
      item.stepDone = 0;
    }
    var written = out.lengthSync();
    for (var i = item.stepDone; i < segments.length; i++) {
      if (job.cancelled) throw _Paused();
      RawResponse? r;
      for (var attempt = 0; attempt < 3 && r == null; attempt++) {
        try {
          final res = await Http.send(segments[i], headers: item.headers, timeout: const Duration(seconds: 30));
          if (res.ok) r = res;
        } catch (_) {}
      }
      if (r == null) throw AppError('分片 ${i + 1} 下载失败');
      out.writeAsBytesSync(r.bytes, mode: FileMode.append);
      written += r.bytes.length;
      item.stepDone = i + 1;
      _progress(item, written);
    }
    return out.path;
  }

  static Future<List<String>> _playlist(String url, Map<String, String> headers) async {
    final text = (await Http.send(url, headers: headers)).text;
    if (!text.contains('#EXTM3U')) throw AppError('不是有效的 m3u8 播放列表');
    final lines = text.split(RegExp(r'\r?\n')).map((e) => e.trim()).toList();
    if (text.contains('#EXT-X-STREAM-INF')) {
      var best = -1;
      String? uri;
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
        final bw = int.tryParse(RX.first(r'BANDWIDTH=(\d+)', lines[i]) ?? '') ?? 0;
        final next = lines.skip(i + 1).firstWhere((l) => l.isNotEmpty && !l.startsWith('#'), orElse: () => '');
        if (next.isNotEmpty && bw > best) {
          best = bw;
          uri = next;
        }
      }
      if (uri == null) throw AppError('m3u8 没有可用的变体流');
      return _playlist(Uri.parse(url).resolve(uri).toString(), headers);
    }
    final key = lines.firstWhere((l) => l.startsWith('#EXT-X-KEY'), orElse: () => '');
    if (key.isNotEmpty && !key.contains('METHOD=NONE')) throw AppError('该视频流已加密，暂不支持下载，可在线播放');
    final segs = lines.where((l) => l.isNotEmpty && !l.startsWith('#')).map((l) => Uri.parse(url).resolve(l).toString()).toList();
    if (segs.isEmpty) throw AppError('m3u8 没有分片');
    return segs;
  }

  /// DASH：① 视频轨 ② 音轨 ③ 原生合轨（iOS AVFoundation 直通导出 mp4）
  Future<String> _runDash(DownloadItem item, _Job job) async {
    final video = File('${workDir.path}/${item.id}_v.part');
    final audio = File('${workDir.path}/${item.id}_a.part');
    if (item.stepDone < 1) {
      await _fetch(item, item.url, item.headers, video, job, 0);
      item.stepDone = 1;
    }
    if (item.stepDone < 2) {
      final base = video.existsSync() ? video.lengthSync() : 0;
      await _fetch(item, item.audioUrl, item.audioHeaders, audio, job, base);
      item.stepDone = 2;
    }
    // AVFoundation 靠扩展名识别容器
    final v = video.renameSync('${workDir.path}/${item.id}_v.mp4');
    final a = audio.renameSync('${workDir.path}/${item.id}_a.m4a');
    final output = '${workDir.path}/${item.id}_out.mp4';
    try {
      await _media.invokeMethod('mux', {'video': v.path, 'audio': a.path, 'output': output});
    } on PlatformException catch (e) {
      v.renameSync(video.path);
      a.renameSync(audio.path);
      throw AppError('合轨失败：${e.message ?? e.code}');
    } on MissingPluginException {
      throw AppError('当前平台不支持音视频合轨');
    }
    try {
      v.deleteSync();
      a.deleteSync();
    } catch (_) {}
    item.stepDone = 3;
    return output;
  }

  void _progress(DownloadItem item, int received) {
    item.receivedBytes = received;
    final now = DateTime.now();
    final last = _ticks[item.id];
    if (last == null) {
      _ticks[item.id] = (now, received);
    } else {
      final ms = now.difference(last.$1).inMilliseconds;
      if (ms >= 800) {
        final instant = (received - last.$2).clamp(0, 1 << 40) * 1000 / ms;
        speeds[item.id] = (speeds[item.id] ?? instant) * 0.4 + instant * 0.6;
        _ticks[item.id] = (now, received);
      }
    }
    _notifyTimer ??= Timer(const Duration(milliseconds: 250), () {
      _notifyTimer = null;
      notifyListeners();
    });
  }

  Future<void> _finish(DownloadItem item, String tempPath) async {
    final dot = item.fileName.lastIndexOf('.');
    final base = dot > 0 ? item.fileName.substring(0, dot) : item.fileName;
    final ext = dot > 0 ? item.fileName.substring(dot) : '';
    var target = File('${downloadDir.path}/${item.fileName}');
    for (var n = 1; target.existsSync(); n++) {
      target = File('${downloadDir.path}/$base ($n)$ext');
    }
    final moved = File(tempPath).renameSync(target.path);
    final size = moved.lengthSync();
    item
      ..state = DownloadState.completed
      ..localPath = moved.path
      ..completedAt = DateTime.now()
      ..totalBytes = size
      ..receivedBytes = size;
    HapticFeedback.mediumImpact();
    final kind = item.fileKind;
    if (autoSaveToPhotos() && (kind == FileKind.image || kind == FileKind.video)) {
      try {
        await saveToPhotos(moved.path, kind);
      } catch (_) {}
    }
  }

  static Future<void> saveToPhotos(String path, FileKind kind) async {
    if (!await Gal.hasAccess()) await Gal.requestAccess();
    if (kind == FileKind.video) {
      await Gal.putVideo(path);
    } else {
      await Gal.putImage(path);
    }
  }

  void _changed() {
    notifyListeners();
    _persist();
  }

  void persist() => _persist();

  void _persist() {
    try {
      _stateFile.writeAsStringSync(jsonEncode(items.map((e) => e.toJson()).toList()));
    } catch (e) {
      debugPrint('persist downloads failed: $e');
    }
  }
}
