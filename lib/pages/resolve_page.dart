// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/drives/resolver.dart';
import '../core/links.dart';
import '../core/models.dart';
import '../core/stores.dart';
import '../core/text.dart';
import '../core/video/video_http.dart';
import '../ui/design.dart';
import 'share_browser_page.dart';
import 'video_result_page.dart';

/// 深链 / 剪贴板送来的待解析文本
class PendingInput extends ChangeNotifier {
  String? text;
  bool autoStart = false;

  void open(String value, {bool start = true}) {
    text = value;
    autoStart = start;
    notifyListeners();
  }
}

class ResolvePage extends StatefulWidget {
  const ResolvePage({super.key});

  @override
  State<ResolvePage> createState() => _ResolvePageState();
}

class _ResolvePageState extends State<ResolvePage> {
  final _input = TextEditingController();
  final _pwd = TextEditingController();
  final _focus = FocusNode();
  bool _loading = false;
  int _token = 0;
  PendingInput? _pending;

  DetectedLink? get _detected => DetectedLink.detect(_input.text);
  bool get _needsPwd => _detected?.share != null && _detected!.share!.pwd == null;

  @override
  void initState() {
    super.initState();
    _input.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pending = context.read<PendingInput>()..addListener(_consumePending);
      _consumePending();
    });
  }

  void _consumePending() {
    final pending = context.read<PendingInput>();
    final text = pending.text;
    if (text == null) return;
    pending.text = null;
    _input.text = text;
    if (pending.autoStart) {
      Navigator.of(context).popUntil((r) => r.isFirst);
      _start();
    }
  }

  @override
  void dispose() {
    _pending?.removeListener(_consumePending);
    _input.dispose();
    _pwd.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    _focus.unfocus();
    final text = _input.text.trim();
    if (text.isEmpty) return;
    if (_loading) {
      setState(() {
        _loading = false;
        _token++;
      });
      return;
    }
    final link = DetectedLink.detect(text);
    if (link == null) return showToast(context, '没有识别到支持的分享链接', error: true);
    if (!link.isAvailable) return showToast(context, 'Flutter 版暂未支持${link.displayName}，敬请期待');
    final accounts = context.read<AccountStore>();
    final history = context.read<HistoryStore>();
    final token = ++_token;
    setState(() => _loading = true);
    try {
      if (link.video != null) {
        final v = link.video!;
        final result = await VideoParseService.parse(v, accounts.cookie(AccountKey.video(v.platform)));
        if (token != _token || !mounted) return;
        if (result.medias.isEmpty) throw VideoParseError(VideoErrorKind.unknown, '没有解析到可下载的媒体');
        history.add(text, result.title.ifEmpty(result.author), link);
        HapticFeedback.mediumImpact();
        Navigator.of(context).push(CupertinoPageRoute(builder: (_) => VideoResultPage(result: result)));
      } else {
        final s = link.share!;
        final code = s.pwd ?? (_pwd.text.trim().isEmpty ? null : _pwd.text.trim());
        final session = await ShareResolvers.of(s.platform).open(s, code, accounts.cookie(AccountKey.drive(s.platform)));
        if (token != _token || !mounted) return;
        history.add(text, session.title, link);
        HapticFeedback.mediumImpact();
        Navigator.of(context).push(CupertinoPageRoute(builder: (_) => ShareBrowserPage(session: session)));
      }
    } catch (e) {
      if (token == _token && mounted) showToast(context, '$e', error: true);
    } finally {
      if (token == _token && mounted) setState(() => _loading = false);
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isEmpty) return;
    _input.text = text;
    _start();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final history = context.watch<HistoryStore>();
    final theme = Theme.of(context);
    return Scaffold(
      body: AppBackground(
        child: SafeArea(
          bottom: false,
          child: ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
            children: [
              Row(children: [
                Container(
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), boxShadow: [
                    BoxShadow(color: settings.accent.color.withValues(alpha: 0.35), blurRadius: 12, offset: const Offset(0, 4)),
                  ]),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Image.asset('assets/app_logo.png', width: 52, height: 52),
                  ),
                ),
                const SizedBox(width: 14),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  ShaderMask(
                    shaderCallback: (r) => settings.accent.gradient.createShader(r),
                    child: const Text('云析', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: Colors.white)),
                  ),
                  Text('粘贴分享链接，直接高速下载', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                ]),
              ]),
              const SizedBox(height: 22),
              _inputCard(settings),
              const SizedBox(height: 22),
              const SectionHeader('支持的平台'),
              GlassCard(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _platformRow('网盘', SharePlatform.values.map((p) => (p.logo, p.displayName, p.isAvailable)).toList()),
                  const Divider(height: 24),
                  _platformRow('视频', VideoPlatform.values.map((p) => (p.logo, p.displayName, p.isAvailable)).toList()),
                ]),
              ),
              if (history.entries.isNotEmpty) ...[
                const SizedBox(height: 22),
                SectionHeader('最近解析', trailing: '清空', onTap: history.clear),
                GlassCard(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(children: [
                    for (final e in history.entries.take(8))
                      ListTile(
                        leading: PlatformLogo(e.logo, size: 36),
                        title: Text(e.title.ifEmpty(e.platformName), maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                        subtitle: Text('${e.platformName} · ${Fmt.relative(e.date)}', style: const TextStyle(fontSize: 12)),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () {
                          _input.text = e.text;
                          _pwd.clear();
                          _start();
                        },
                        onLongPress: () => _historyMenu(e),
                      ),
                  ]),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _historyMenu(HistoryEntry e) {
    showActionSheet(context, title: e.text, actions: [
      SheetAction('复制链接', () => Clipboard.setData(ClipboardData(text: e.text))),
      SheetAction('删除', () => context.read<HistoryStore>().remove(e), destructive: true),
    ]);
  }

  Widget _inputCard(SettingsStore settings) {
    final theme = Theme.of(context);
    final detected = _detected;
    return GlassCard(
      padding: const EdgeInsets.all(18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          controller: _input,
          focusNode: _focus,
          minLines: 3,
          maxLines: 6,
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => _start(),
          decoration: iosField(context, hint: '粘贴网盘分享链接、视频链接或整段分享文案', radius: 14),
        ),
        const SizedBox(height: 12),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: detected != null
              ? Row(key: ValueKey(detected.displayName), children: [
                  PlatformLogo(detected.logo, size: 28),
                  const SizedBox(width: 10),
                  Text('识别为 ${detected.displayName}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (!detected.isAvailable) ...[const SizedBox(width: 6), const Tag('即将支持', color: Colors.orange)],
                  const Spacer(),
                  Icon(detected.isAvailable ? Icons.verified_rounded : Icons.schedule_rounded,
                      color: detected.isAvailable ? Colors.green : Colors.orange),
                ])
              : _input.text.isEmpty
                  ? const SizedBox.shrink()
                  : Row(key: const ValueKey('none'), children: [
                      Icon(Icons.help_outline_rounded, size: 18, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 6),
                      Text('暂未识别到支持的链接', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                    ]),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          child: _needsPwd
              ? Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: TextField(
                    controller: _pwd,
                    autocorrect: false,
                    decoration: iosField(context, hint: '提取码（没有可不填）', prefix: CupertinoIcons.lock),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Chip2(label: '粘贴', icon: Icons.content_paste_rounded, onTap: _paste),
          if (_input.text.isNotEmpty) ...[
            const SizedBox(width: 8),
            Chip2(
              label: '清空',
              icon: Icons.close_rounded,
              color: Colors.red,
              onTap: () {
                _input.clear();
                _pwd.clear();
              },
            ),
          ],
        ]),
        const SizedBox(height: 14),
        GradientButton(
          onPressed: _input.text.trim().isEmpty ? null : _start,
          child: Row(mainAxisSize: MainAxisSize.min, children: _loading
              ? const [
                  SizedBox(width: 18, height: 18, child: CupertinoActivityIndicator(color: Colors.white)),
                  SizedBox(width: 10),
                  Text('解析中… 点按取消'),
                ]
              : const [Icon(Icons.auto_awesome_rounded, size: 20), SizedBox(width: 8), Text('开始解析')]),
        ),
      ]),
    );
  }

  Widget _platformRow(String title, List<(String, String, bool)> items) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: theme.colorScheme.onSurfaceVariant)),
      const SizedBox(height: 8),
      SizedBox(
        height: 70,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (_, i) {
            final (logo, name, ok) = items[i];
            return SizedBox(
              width: 62,
              child: Column(children: [
                PlatformLogo(logo, size: 44, dimmed: !ok),
                const SizedBox(height: 6),
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: ok ? null : theme.colorScheme.onSurfaceVariant)),
              ]),
            );
          },
        ),
      ),
    ]);
  }
}
