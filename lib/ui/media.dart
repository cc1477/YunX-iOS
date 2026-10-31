// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import 'dart:typed_data';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/http.dart';
import '../core/models.dart';

/// 远程图片：逐请求带上平台要求的 Referer / UA（Image.network 也支持 headers，这里加一层内存缓存）
class RemoteImage extends StatefulWidget {
  const RemoteImage(this.url, {super.key, this.headers = const {}, this.fit = BoxFit.cover});
  final String url;
  final Map<String, String> headers;
  final BoxFit fit;

  static final Map<String, Uint8List> _cache = {};
  static int _cacheBytes = 0;

  @override
  State<RemoteImage> createState() => _RemoteImageState();
}

class _RemoteImageState extends State<RemoteImage> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(RemoteImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _load();
  }

  Future<void> _load() async {
    final url = widget.url;
    if (url.isEmpty) {
      setState(() => _failed = true);
      return;
    }
    final cached = RemoteImage._cache[url];
    if (cached != null) {
      setState(() => _bytes = cached);
      return;
    }
    try {
      final r = await Http.send(url, headers: {'User-Agent': UA.iPhone, ...widget.headers}, timeout: const Duration(seconds: 30));
      if (!r.ok || r.bytes.isEmpty) throw AppError('HTTP ${r.status}');
      if (RemoteImage._cacheBytes > 100 * 1024 * 1024) {
        RemoteImage._cache.clear();
        RemoteImage._cacheBytes = 0;
      }
      RemoteImage._cache[url] = r.bytes;
      RemoteImage._cacheBytes += r.bytes.length;
      if (mounted && widget.url == url) setState(() => _bytes = r.bytes);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Center(
        child: _failed
            ? Icon(Icons.image_not_supported_outlined, color: Theme.of(context).colorScheme.outline)
            : const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      ),
    );
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: _bytes == null
          ? placeholder
          : Image.memory(_bytes!, key: ValueKey(widget.url), fit: widget.fit, gaplessPlayback: true,
              errorBuilder: (_, __, ___) => placeholder),
    );
  }
}

/// 在线播放（逐请求带上平台要求的请求头；B 站分轨预览只播视频轨）
class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.url, required this.headers, this.title = ''});
  final String url;
  final Map<String, String> headers;
  final String title;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late final VideoPlayerController _c;
  String? _error;

  @override
  void initState() {
    super.initState();
    _c = VideoPlayerController.networkUrl(Uri.parse(widget.url), httpHeaders: widget.headers)
      ..addListener(() => setState(() {}));
    _c.initialize().then((_) => _c.play()).catchError((e) {
      if (mounted) setState(() => _error = '无法播放：$e');
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  String _fmt(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final v = _c.value;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
      ),
      body: Center(
        child: _error != null
            ? Text(_error!, style: const TextStyle(color: Colors.white70))
            : !v.isInitialized
                ? const CircularProgressIndicator(color: Colors.white)
                : Column(mainAxisSize: MainAxisSize.min, children: [
                    AspectRatio(
                      aspectRatio: v.aspectRatio,
                      child: GestureDetector(
                        onTap: () => v.isPlaying ? _c.pause() : _c.play(),
                        child: Stack(alignment: Alignment.center, children: [
                          VideoPlayer(_c),
                          if (!v.isPlaying)
                            const Icon(Icons.play_circle_fill_rounded, size: 72, color: Colors.white70),
                        ]),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Row(children: [
                        Text(_fmt(v.position), style: const TextStyle(color: Colors.white70, fontFeatures: [FontFeature.tabularFigures()])),
                        Expanded(
                          child: VideoProgressIndicator(_c,
                              allowScrubbing: true,
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              colors: VideoProgressColors(playedColor: Theme.of(context).colorScheme.primary)),
                        ),
                        Text(_fmt(v.duration), style: const TextStyle(color: Colors.white70)),
                      ]),
                    ),
                  ]),
      ),
    );
  }
}

/// 图片大图（左右翻页、双指缩放）
class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({super.key, required this.medias, required this.initial, required this.onDownload});
  final List<VideoMedia> medias;
  final int initial;
  final void Function(VideoMedia) onDownload;

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late int _index = widget.initial;
  late final PageController _pc = PageController(initialPage: widget.initial);

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text('${_index + 1} / ${widget.medias.length}', style: const TextStyle(fontSize: 16)),
          actions: [
            IconButton(
              icon: const Icon(Icons.download_rounded),
              onPressed: () => widget.onDownload(widget.medias[_index]),
            ),
          ],
        ),
        body: PageView.builder(
          controller: _pc,
          itemCount: widget.medias.length,
          onPageChanged: (i) => setState(() => _index = i),
          itemBuilder: (_, i) => InteractiveViewer(
            maxScale: 5,
            child: Center(child: RemoteImage(widget.medias[i].url, headers: widget.medias[i].headers, fit: BoxFit.contain)),
          ),
        ),
      );
}
