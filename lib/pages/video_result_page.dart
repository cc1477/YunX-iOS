// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/download.dart';
import '../core/models.dart';
import '../core/stores.dart';
import '../core/text.dart';
import '../ui/design.dart';
import '../ui/media.dart';

/// 视频 / 图集解析结果：封面大图、作者、正文，视频卡片在线播放，图集三列网格放大查看
class VideoResultPage extends StatefulWidget {
  const VideoResultPage({super.key, required this.result});
  final VideoParseResult result;

  @override
  State<VideoResultPage> createState() => _VideoResultPageState();
}

class _VideoResultPageState extends State<VideoResultPage> {
  bool _expanded = false;

  VideoParseResult get r => widget.result;
  String get _hero => r.cover.ifEmpty(r.images.isEmpty ? '' : r.images.first.url);
  Map<String, String> get _heroHeaders => r.medias.isEmpty ? const {} : r.medias.first.headers;

  void _download(VideoMedia m) {
    context.read<DownloadManager>().enqueueMedia(m, r);
    showToast(context, '已加入下载');
  }

  void _downloadAll() {
    final d = context.read<DownloadManager>();
    for (final m in r.medias) {
      d.enqueueMedia(m, r);
    }
    showToast(context, '已加入下载（${r.medias.length}）');
  }

  @override
  Widget build(BuildContext context) {
    final accent = context.watch<SettingsStore>().accent;
    final theme = Theme.of(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz_rounded),
            onSelected: (v) {
              Clipboard.setData(ClipboardData(text: v == 'url' ? r.url : r.text));
              showToast(context, '已复制');
            },
            itemBuilder: (_) => [
              if (r.url.isNotEmpty) const PopupMenuItem(value: 'url', child: Text('复制原链接')),
              if (r.text.isNotEmpty) const PopupMenuItem(value: 'text', child: Text('复制文案')),
            ],
          ),
        ],
      ),
      body: AppBackground(
        safeTop: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 120),
          children: [
            SizedBox(
              height: 340,
              child: Stack(fit: StackFit.expand, children: [
                RemoteImage(_hero, headers: _heroHeaders),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.center,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black87],
                    ),
                  ),
                ),
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 16,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      PlatformLogo(r.platform.logo, size: 26),
                      const SizedBox(width: 8),
                      Text(r.platform.displayName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
                      const SizedBox(width: 6),
                      if (r.videos.isNotEmpty) Tag('视频 ${r.videos.length}', color: Colors.white),
                      if (r.images.isNotEmpty) ...[const SizedBox(width: 4), Tag('图片 ${r.images.length}', color: Colors.white)],
                    ]),
                    const SizedBox(height: 10),
                    Text(r.title.ifEmpty('无标题'),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                  ]),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  ClipOval(
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: r.avatar.isEmpty
                          ? Icon(Icons.account_circle_rounded, size: 40, color: theme.colorScheme.outline)
                          : RemoteImage(r.avatar, headers: _heroHeaders),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(r.author.ifEmpty('未知作者'), style: const TextStyle(fontWeight: FontWeight.w700)),
                    if (r.timestamp > 0)
                      Text(Fmt.date(r.timestamp), style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
                  ]),
                ]),
                if (r.text.isNotEmpty && r.text != r.title) ...[
                  const SizedBox(height: 16),
                  GlassCard(
                    padding: const EdgeInsets.all(14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SelectableText(r.text, maxLines: _expanded ? null : 4),
                      TextButton(
                        style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero),
                        onPressed: () => setState(() => _expanded = !_expanded),
                        child: Text(_expanded ? '收起' : '展开'),
                      ),
                    ]),
                  ),
                ],
                if (r.notice.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(r.notice, style: const TextStyle(color: Colors.orange, fontSize: 13)),
                ],
                if (r.videos.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  const SectionHeader('视频'),
                  for (final m in r.videos) ...[_videoCard(m, accent.color), const SizedBox(height: 10)],
                ],
                if (r.images.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  SectionHeader('图片（${r.images.length}）'),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: EdgeInsets.zero,
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3, mainAxisSpacing: 6, crossAxisSpacing: 6),
                    itemCount: r.images.length,
                    itemBuilder: (_, i) {
                      final m = r.images[i];
                      return GestureDetector(
                        onTap: () => Navigator.of(context).push(CupertinoPageRoute(
                            builder: (_) => ImageViewerPage(medias: r.images, initial: i, onDownload: _download))),
                        onLongPress: () => _download(m),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Stack(fit: StackFit.expand, children: [
                            RemoteImage(m.url, headers: m.headers),
                            if (m.motionUrl.isNotEmpty)
                              const Positioned(
                                top: 6,
                                right: 6,
                                child: CircleAvatar(
                                  radius: 11,
                                  backgroundColor: Colors.black38,
                                  child: Icon(Icons.motion_photos_on_rounded, size: 14, color: Colors.white),
                                ),
                              ),
                          ]),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 6),
                  Text('点按查看大图，长按下载单张', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
                ],
              ]),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: GradientButton(
            onPressed: _downloadAll,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.download_rounded, size: 20),
              const SizedBox(width: 6),
              Text(r.medias.length > 1 ? '全部下载（${r.medias.length}）' : '下载'),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _videoCard(VideoMedia m, Color accent) => GlassCard(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          GestureDetector(
            onTap: () => Navigator.of(context).push(CupertinoPageRoute(
                builder: (_) => PlayerPage(url: m.url, headers: m.headers, title: r.title))),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 112,
                height: 72,
                child: Stack(fit: StackFit.expand, children: [
                  RemoteImage(_hero, headers: _heroHeaders),
                  const Center(child: Icon(Icons.play_circle_fill_rounded, size: 34, color: Colors.white)),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(m.fileName, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, children: [
                if (m.quality.isNotEmpty) Tag(m.quality, color: accent),
                if (m.size > 0) Text(Fmt.bytes(m.size), style: const TextStyle(fontSize: 12)),
              ]),
            ]),
          ),
          IconButton(
            icon: Icon(Icons.download_for_offline_rounded, color: accent, size: 32),
            onPressed: () => _download(m),
          ),
        ]),
      );
}
