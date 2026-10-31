// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/download.dart';
import '../core/models.dart';
import '../core/stores.dart';
import '../core/text.dart';
import '../ui/design.dart';

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  bool _completedTab = false;

  @override
  Widget build(BuildContext context) {
    final d = context.watch<DownloadManager>();
    final accent = context.watch<SettingsStore>().accent;
    final theme = Theme.of(context);
    final list = _completedTab ? d.completed : d.active;
    final running = d.items.where((i) => i.state == DownloadState.running).toList();
    final overall = running.isEmpty
        ? (d.active.isEmpty ? 1.0 : 0.0)
        : running.map((i) => i.progress).reduce((a, b) => a + b) / running.length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载', style: TextStyle(fontWeight: FontWeight.w800)),
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz_rounded),
            onSelected: (v) {
              switch (v) {
                case 'resume':
                  d.resumeAll();
                case 'pause':
                  d.pauseAll();
                case 'clear':
                  _confirmClear(d);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'resume', child: Text('全部开始')),
              PopupMenuItem(value: 'pause', child: Text('全部暂停')),
              PopupMenuItem(value: 'clear', child: Text('清空已完成')),
            ],
          ),
        ],
      ),
      body: AppBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
          children: [
            GlassCard(
              child: Row(children: [
                SizedBox(
                  width: 56,
                  height: 56,
                  child: Stack(alignment: Alignment.center, children: [
                    SizedBox.expand(
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(end: overall),
                        duration: const Duration(milliseconds: 400),
                        builder: (_, v, __) => CircularProgressIndicator(
                          value: v,
                          strokeWidth: 6,
                          strokeCap: StrokeCap.round,
                          color: accent.color,
                          backgroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.08),
                        ),
                      ),
                    ),
                    Icon(d.runningCount > 0 ? Icons.arrow_downward_rounded : Icons.check_rounded, color: accent.color),
                  ]),
                ),
                const SizedBox(width: 16),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(d.runningCount > 0 ? '${d.runningCount} 个任务下载中' : '下载空闲',
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                    d.runningCount > 0 ? Fmt.speed(d.totalSpeed).ifEmpty('连接中…') : '已完成 ${d.completed.length} 个文件',
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ]),
              ]),
            ),
            const SizedBox(height: 14),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: false, label: Text('进行中')),
                ButtonSegment(value: true, label: Text('已完成')),
              ],
              selected: {_completedTab},
              onSelectionChanged: (v) => setState(() => _completedTab = v.first),
            ),
            const SizedBox(height: 14),
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 60),
                child: Column(children: [
                  Icon(_completedTab ? Icons.inbox_rounded : Icons.downloading_rounded, size: 52, color: theme.colorScheme.outline),
                  const SizedBox(height: 12),
                  Text(_completedTab ? '还没有下载完成的文件' : '没有进行中的任务', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(
                    _completedTab ? '下载的文件也可以在「文件」App › 我的 iPhone › 云析 中找到' : '在「解析」页粘贴链接，选择文件即可开始下载',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ]),
              )
            else
              GlassCard(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(children: [
                  for (final item in list)
                    Dismissible(
                      key: ValueKey(item.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        color: Colors.red,
                        child: const Icon(Icons.delete_rounded, color: Colors.white),
                      ),
                      onDismissed: (_) => d.delete(item.id),
                      child: _DownloadRow(item: item, speed: d.speeds[item.id] ?? 0, onMenu: () => _menu(d, item)),
                    ),
                ]),
              ),
          ],
        ),
      ),
    );
  }

  void _confirmClear(DownloadManager d) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: const Text('仅清除记录'),
            onTap: () {
              d.clearCompleted(removeFiles: false);
              Navigator.pop(ctx);
            },
          ),
          ListTile(
            title: const Text('清除记录并删除文件', style: TextStyle(color: Colors.red)),
            onTap: () {
              d.clearCompleted(removeFiles: true);
              Navigator.pop(ctx);
            },
          ),
        ]),
      ),
    );
  }

  void _menu(DownloadManager d, DownloadItem item) {
    final done = item.state == DownloadState.completed;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(item.fileName, maxLines: 2, style: const TextStyle(fontWeight: FontWeight.w600))),
          if (done) ...[
            ListTile(
              leading: const Icon(Icons.visibility_rounded),
              title: const Text('打开'),
              onTap: () {
                Navigator.pop(ctx);
                OpenFilex.open(item.localPath);
              },
            ),
            ListTile(
              leading: const Icon(Icons.ios_share_rounded),
              title: const Text('分享 / 存储到文件'),
              onTap: () {
                Navigator.pop(ctx);
                Share.shareXFiles([XFile(item.localPath)]);
              },
            ),
            if (item.fileKind == FileKind.image || item.fileKind == FileKind.video)
              ListTile(
                leading: const Icon(Icons.photo_library_rounded),
                title: const Text('存入相册'),
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    await DownloadManager.saveToPhotos(item.localPath, item.fileKind);
                    if (mounted) showToast(context, '已存入相册');
                  } catch (e) {
                    if (mounted) showToast(context, '存入相册失败：$e', error: true);
                  }
                },
              ),
          ] else ...[
            ListTile(
              leading: Icon(item.state == DownloadState.running || item.state == DownloadState.queued
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded),
              title: Text(item.state == DownloadState.running || item.state == DownloadState.queued
                  ? '暂停'
                  : item.state == DownloadState.failed
                      ? '重试'
                      : '继续'),
              onTap: () {
                Navigator.pop(ctx);
                d.toggle(item);
              },
            ),
            ListTile(
              leading: const Icon(Icons.link_rounded),
              title: const Text('复制直链'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: item.url));
                Navigator.pop(ctx);
              },
            ),
          ],
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded, color: Colors.red),
            title: const Text('删除', style: TextStyle(color: Colors.red)),
            onTap: () {
              Navigator.pop(ctx);
              d.delete(item.id);
            },
          ),
        ]),
      ),
    );
  }
}

class _DownloadRow extends StatelessWidget {
  const _DownloadRow({required this.item, required this.speed, required this.onMenu});
  final DownloadItem item;
  final double speed;
  final VoidCallback onMenu;

  String get _status {
    switch (item.state) {
      case DownloadState.completed:
        return '${Fmt.bytes(item.totalBytes)} · ${item.source}';
      case DownloadState.failed:
        return item.errorMessage.ifEmpty('下载失败');
      default:
        if (item.kind == DownloadKind.hls && item.stepTotal > 0) {
          return '${item.state.label} · 分片 ${item.stepDone}/${item.stepTotal}';
        }
        if (item.kind == DownloadKind.dash) {
          final stage = item.stepDone == 0 ? '视频轨' : item.stepDone == 1 ? '音频轨' : '合轨中';
          return '${item.state.label} · $stage · ${Fmt.bytes(item.receivedBytes)}';
        }
        if (item.totalBytes > 0) {
          return '${item.state.label} · ${Fmt.bytes(item.receivedBytes)} / ${Fmt.bytes(item.totalBytes)}';
        }
        return item.state.label;
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = context.read<DownloadManager>();
    final accent = context.watch<SettingsStore>().accent;
    final theme = Theme.of(context);
    final icon = switch (item.state) {
      DownloadState.running => Icons.pause_circle_filled_rounded,
      DownloadState.queued => Icons.schedule_rounded,
      DownloadState.paused => Icons.play_circle_fill_rounded,
      DownloadState.failed => Icons.replay_circle_filled_rounded,
      DownloadState.completed => Icons.visibility_rounded,
    };
    return InkWell(
      onTap: item.state == DownloadState.completed ? () => OpenFilex.open(item.localPath) : onMenu,
      onLongPress: onMenu,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(children: [
          Stack(clipBehavior: Clip.none, children: [
            FileIcon(item.fileKind, size: 44),
            Positioned(right: -4, bottom: -4, child: PlatformLogo(item.sourceLogo, size: 18)),
          ]),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.fileName, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
              if (item.state != DownloadState.completed) ...[
                const SizedBox(height: 6),
                GradientProgress(value: item.state == DownloadState.running && item.progress == 0 ? null : item.progress),
              ],
              const SizedBox(height: 5),
              Row(children: [
                Expanded(
                  child: Text(_status,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          color: item.state == DownloadState.failed ? Colors.orange : theme.colorScheme.onSurfaceVariant)),
                ),
                if (item.state == DownloadState.running && speed > 0)
                  Text(Fmt.speed(speed), style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
              ]),
            ]),
          ),
          IconButton(
            icon: Icon(icon, size: 30, color: item.state == DownloadState.failed ? Colors.orange : accent.color),
            onPressed: () => item.state == DownloadState.completed ? OpenFilex.open(item.localPath) : d.toggle(item),
          ),
        ]),
      ),
    );
  }
}
