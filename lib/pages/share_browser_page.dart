// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/download.dart';
import '../core/drives/resolver.dart';
import '../core/models.dart';
import '../core/stores.dart';
import '../core/text.dart';
import '../ui/design.dart';
import '../ui/media.dart';

/// 分享内容浏览：面包屑目录、搜索、多选批量下载、在线播放 / 复制直链
class ShareBrowserPage extends StatefulWidget {
  const ShareBrowserPage({super.key, required this.session});
  final ShareSession session;

  @override
  State<ShareBrowserPage> createState() => _ShareBrowserPageState();
}

class _ShareBrowserPageState extends State<ShareBrowserPage> {
  late final List<(String, String)> _crumbs = [(widget.session.rootId, widget.session.title)];
  List<ShareFile> _files = [];
  bool _loading = true;
  String? _error;
  String _query = '';
  bool _selecting = false;
  final Set<String> _selected = {};
  String? _working;

  ShareSession get s => widget.session;
  ShareResolver get _resolver => ShareResolvers.of(s.platform);
  String get _cookie => context.read<AccountStore>().cookie(AccountKey.drive(s.platform));

  List<ShareFile> get _visible {
    final sorted = [..._files.where((f) => f.isDir), ..._files.where((f) => !f.isDir)];
    if (_query.isEmpty) return sorted;
    final q = _query.toLowerCase();
    return sorted.where((f) => f.name.toLowerCase().contains(q)).toList();
  }

  List<ShareFile> get _downloadable => _visible.where((f) => !f.isDir).toList();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _selected.clear();
    });
    try {
      final files = await _resolver.list(s, _crumbs.last.$1, _cookie);
      if (mounted) setState(() => _files = files);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _download(List<ShareFile> targets) async {
    if (targets.isEmpty || _working != null) return;
    final downloads = context.read<DownloadManager>();
    var added = 0;
    String? lastError;
    for (var i = 0; i < targets.length; i++) {
      setState(() => _working = targets.length > 1 ? '正在获取直链 ${i + 1}/${targets.length}' : '正在获取直链…');
      try {
        final link = await _resolver.downloadLink(s, targets[i], _cookie);
        downloads.enqueueLink(link, s.platform.displayName, s.platform.logo);
        added++;
      } catch (e) {
        lastError = '$e';
      }
      // 蓝奏等平台有频控，批量取链之间稍作间隔
      if (targets.length > 1) await Future.delayed(const Duration(milliseconds: 350));
    }
    if (!mounted) return;
    setState(() {
      _working = null;
      _selecting = false;
      _selected.clear();
    });
    if (added > 0) {
      showToast(context, added == targets.length ? '已加入下载（$added）' : '已加入 $added 个，${targets.length - added} 个失败');
    } else if (lastError != null) {
      showToast(context, lastError, error: true);
    }
  }

  Future<DownloadLink?> _link(ShareFile f) async {
    setState(() => _working = '正在获取直链…');
    try {
      return await _resolver.downloadLink(s, f, _cookie);
    } catch (e) {
      if (mounted) showToast(context, '$e', error: true);
      return null;
    } finally {
      if (mounted) setState(() => _working = null);
    }
  }

  void _actions(ShareFile f) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: Text(f.name, maxLines: 2, style: const TextStyle(fontWeight: FontWeight.w600)), subtitle: Text(Fmt.bytes(f.size))),
          ListTile(
            leading: const Icon(Icons.download_rounded),
            title: const Text('下载'),
            onTap: () {
              Navigator.pop(ctx);
              _download([f]);
            },
          ),
          if (f.kind == FileKind.video || f.kind == FileKind.audio)
            ListTile(
              leading: const Icon(Icons.play_circle_outline_rounded),
              title: const Text('在线播放'),
              onTap: () async {
                Navigator.pop(ctx);
                final link = await _link(f);
                if (link != null && mounted) {
                  Navigator.of(context).push(CupertinoPageRoute(
                      builder: (_) => PlayerPage(url: link.url, headers: link.headers, title: link.fileName)));
                }
              },
            ),
          ListTile(
            leading: const Icon(Icons.link_rounded),
            title: const Text('复制直链'),
            onTap: () async {
              Navigator.pop(ctx);
              final link = await _link(f);
              if (link != null && mounted) {
                await Clipboard.setData(ClipboardData(text: link.url));
                if (mounted) showToast(context, '直链已复制（需带请求头才能下载）');
              }
            },
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = context.watch<SettingsStore>().accent;
    final theme = Theme.of(context);
    final visible = _visible;
    final folders = _files.where((f) => f.isDir).length;
    final total = _files.fold<int>(0, (a, f) => a + (f.isDir ? 0 : f.size));
    return Scaffold(
      extendBodyBehindAppBar: false,
      appBar: AppBar(
        title: Text(_crumbs.last.$2, maxLines: 1, overflow: TextOverflow.ellipsis),
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
        actions: [
          if (_downloadable.isNotEmpty)
            TextButton(
              onPressed: () => setState(() {
                _selecting = !_selecting;
                _selected.clear();
              }),
              child: Text(_selecting ? '完成' : '选择'),
            ),
        ],
      ),
      body: AppBackground(
        child: Stack(children: [
          RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
              children: [
                GlassCard(
                  child: Row(children: [
                    PlatformLogo(s.platform.logo, size: 52),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(s.title, maxLines: 2, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 6),
                        Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                          Tag(s.platform.displayName, color: s.platform.tint),
                          if (!_loading)
                            Text(
                              '${_files.length - folders} 个文件${folders > 0 ? ' · $folders 个文件夹' : ''}${total > 0 ? ' · ${Fmt.bytes(total)}' : ''}',
                              style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                            ),
                        ]),
                      ]),
                    ),
                  ]),
                ),
                const SizedBox(height: 12),
                TextField(
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search_rounded),
                    hintText: '搜索文件',
                    isDense: true,
                    filled: true,
                    fillColor: theme.colorScheme.onSurface.withValues(alpha: 0.05),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                ),
                if (_crumbs.length > 1) ...[
                  const SizedBox(height: 10),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      for (var i = 0; i < _crumbs.length; i++) ...[
                        if (i > 0) Icon(Icons.chevron_right_rounded, size: 16, color: theme.colorScheme.outline),
                        TextButton(
                          style: TextButton.styleFrom(
                            minimumSize: Size.zero,
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                            foregroundColor: i == _crumbs.length - 1 ? theme.colorScheme.onSurface : accent.color,
                          ),
                          onPressed: i == _crumbs.length - 1
                              ? null
                              : () {
                                  setState(() => _crumbs.removeRange(i + 1, _crumbs.length));
                                  _load();
                                },
                          child: Text(i == 0 ? '全部' : _crumbs[i].$2),
                        ),
                      ],
                    ]),
                  ),
                ],
                const SizedBox(height: 12),
                if (_loading)
                  const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
                else if (_error != null)
                  _empty(Icons.wifi_off_rounded, '加载失败', _error!, retry: true)
                else if (visible.isEmpty)
                  _empty(Icons.folder_open_rounded, _query.isEmpty ? '空文件夹' : '没有匹配的文件', '')
                else
                  GlassCard(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(children: [for (final f in visible) _row(f, accent.color)]),
                  ),
              ],
            ),
          ),
          if (_working != null)
            Center(
              child: Material(
                borderRadius: BorderRadius.circular(18),
                color: theme.colorScheme.surfaceContainerHighest,
                elevation: 8,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(_working!),
                  ]),
                ),
              ),
            ),
        ]),
      ),
      bottomNavigationBar: _loading || _downloadable.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(children: [
                  if (_selecting) ...[
                    Chip2(
                      label: _selected.length == _downloadable.length ? '取消全选' : '全选',
                      onTap: () => setState(() {
                        if (_selected.length == _downloadable.length) {
                          _selected.clear();
                        } else {
                          _selected.addAll(_downloadable.map((f) => f.id));
                        }
                      }),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: GradientButton(
                      onPressed: _selecting && _selected.isEmpty
                          ? null
                          : () => _download(_selecting ? _downloadable.where((f) => _selected.contains(f.id)).toList() : _downloadable),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.download_rounded, size: 20),
                        const SizedBox(width: 6),
                        Text(_selecting ? '下载所选（${_selected.length}）' : '全部下载（${_downloadable.length}）'),
                      ]),
                    ),
                  ),
                ]),
              ),
            ),
    );
  }

  Widget _empty(IconData icon, String title, String detail, {bool retry = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Column(children: [
          Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          if (detail.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(detail, textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
          if (retry) ...[const SizedBox(height: 16), FilledButton(onPressed: _load, child: const Text('重试'))],
        ]),
      );

  Widget _row(ShareFile f, Color accent) {
    final selected = _selected.contains(f.id);
    final theme = Theme.of(context);
    return InkWell(
      onTap: () {
        if (_selecting) {
          if (f.isDir) return;
          setState(() => selected ? _selected.remove(f.id) : _selected.add(f.id));
        } else if (f.isDir) {
          setState(() => _crumbs.add((f.id, f.name)));
          _load();
        } else {
          _actions(f);
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(children: [
          if (_selecting && !f.isDir) ...[
            Icon(selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                color: selected ? accent : theme.colorScheme.outline),
            const SizedBox(width: 10),
          ],
          FileIcon(f.kind),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(f.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
              const SizedBox(height: 3),
              Text([if (!f.isDir && f.size > 0) Fmt.bytes(f.size), if (f.modified.isNotEmpty) f.modified].join('  '),
                  style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
            ]),
          ),
          if (f.isDir)
            Icon(Icons.chevron_right_rounded, color: theme.colorScheme.outline)
          else if (!_selecting)
            IconButton(
              icon: Icon(Icons.download_for_offline_rounded, color: accent, size: 28),
              onPressed: () => _download([f]),
            ),
        ]),
      ),
    );
  }
}
