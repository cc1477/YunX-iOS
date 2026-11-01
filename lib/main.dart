// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'core/download.dart';
import 'core/links.dart';
import 'core/stores.dart';
import 'pages/accounts_page.dart';
import 'pages/downloads_page.dart';
import 'pages/resolve_page.dart';
import 'pages/settings_page.dart';
import 'ui/design.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = SettingsStore();
  final accounts = AccountStore();
  final history = HistoryStore();
  final downloads = DownloadManager();
  await Future.wait([settings.load(), accounts.load(), history.load(), downloads.load()]);
  downloads
    ..maxConcurrent = (() => settings.maxConcurrent)
    ..autoSaveToPhotos = (() => settings.autoSaveToPhotos);
  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: settings),
      ChangeNotifierProvider.value(value: accounts),
      ChangeNotifierProvider.value(value: history),
      ChangeNotifierProvider.value(value: downloads),
      ChangeNotifierProvider(create: (_) => ToastCenter()),
      ChangeNotifierProvider(create: (_) => PendingInput()),
    ],
    child: const YunXApp(),
  ));
}

class YunXApp extends StatelessWidget {
  const YunXApp({super.key});

  static SystemUiOverlayStyle _overlay(Brightness b) => (b == Brightness.dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark)
      .copyWith(statusBarColor: Colors.transparent, systemNavigationBarColor: Colors.transparent);

  ThemeData _theme(Color seed, Brightness b) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: b),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
      }),
    );
    return base.copyWith(
      // 透明标题栏，状态栏文字颜色跟随深浅色（浅色模式用黑字）
      appBarTheme: base.appBarTheme.copyWith(
        centerTitle: false,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        systemOverlayStyle: _overlay(b),
      ),
      listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsStore>();
    return MaterialApp(
      title: '云析',
      debugShowCheckedModeBanner: false,
      themeMode: s.themeMode,
      theme: _theme(s.accent.color, Brightness.light),
      darkTheme: _theme(s.accent.color, Brightness.dark),
      home: const RootPage(),
      // 提示条放在 Navigator 之上，二级页面里也能看到
      // 没有标题栏的页面（解析页）也按深浅色设置状态栏文字颜色
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: _overlay(Theme.of(context).brightness),
        child: Stack(children: [child ?? const SizedBox.shrink(), const ToastOverlay()]),
      ),
    );
  }
}

class RootPage extends StatefulWidget {
  const RootPage({super.key});

  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage> with WidgetsBindingObserver {
  int _tab = 0;
  bool _clipboardHint = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.read<SettingsStore>().hasSeenNotice) _showWelcome();
      _detectClipboard();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _detectClipboard();
    if (state == AppLifecycleState.paused) context.read<DownloadManager>().persist();
  }

  /// 只问「剪贴板里有没有文本」，不读取内容 —— 不会触发 iOS 的粘贴提示；用户点按后才真正读取
  Future<void> _detectClipboard() async {
    final s = context.read<SettingsStore>();
    if (!s.clipboardDetect || !s.hasSeenNotice) return;
    final has = await Clipboard.hasStrings();
    if (has && mounted) setState(() => _clipboardHint = true);
    Future.delayed(const Duration(seconds: 8), () {
      if (mounted) setState(() => _clipboardHint = false);
    });
  }

  Future<void> _pasteFromClipboard() async {
    setState(() => _clipboardHint = false);
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    if (!mounted) return;
    if (DetectedLink.detect(text) == null) return showToast(context, '剪贴板里没有支持的链接', error: true);
    setState(() => _tab = 0);
    context.read<PendingInput>().open(text);
  }

  void _showWelcome() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      builder: (ctx) => const _WelcomeSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = context.watch<DownloadManager>();
    final accent = context.watch<SettingsStore>().accent;
    return Stack(children: [
      Scaffold(
        // 内容延伸到标签栏下面，透过毛玻璃可见
        extendBody: true,
        body: IndexedStack(index: _tab, children: const [ResolvePage(), AccountsPage(), DownloadsPage(), SettingsPage()]),
        bottomNavigationBar: _TabBar(
          index: _tab,
          badge: d.runningCount,
          onSelect: (i) {
            if (i != _tab) HapticFeedback.selectionClick();
            setState(() => _tab = i);
          },
        ),
      ),
      if (_clipboardHint)
        Positioned(
          left: 16,
          right: 16,
          bottom: MediaQuery.paddingOf(context).bottom + 90,
          child: Material(
            elevation: 10,
            shadowColor: Colors.black26,
            borderRadius: BorderRadius.circular(20),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(gradient: accent.gradient, borderRadius: BorderRadius.circular(12)),
                  child: const Icon(Icons.content_paste_go_rounded, color: Colors.white),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text('剪贴板里有内容', style: TextStyle(fontWeight: FontWeight.w700)),
                    Text('一键粘贴并开始解析', style: TextStyle(fontSize: 12)),
                  ]),
                ),
                Chip2(label: '解析', onTap: _pasteFromClipboard),
                IconButton(icon: const Icon(Icons.close_rounded, size: 18), onPressed: () => setState(() => _clipboardHint = false)),
              ]),
            ),
          ),
        ),
    ]);
  }
}

/// iOS 风格标签栏：毛玻璃底 + 顶部发丝线，选中项用主题色填充图标，无 Material 胶囊指示器
class _TabBar extends StatelessWidget {
  const _TabBar({required this.index, required this.badge, required this.onSelect});
  final int index, badge;
  final ValueChanged<int> onSelect;

  static const _items = [
    (CupertinoIcons.link, CupertinoIcons.link, '解析'),
    (CupertinoIcons.person_crop_circle, CupertinoIcons.person_crop_circle_fill, '账号'),
    (CupertinoIcons.arrow_down_circle, CupertinoIcons.arrow_down_circle_fill, '下载'),
    (CupertinoIcons.gear, CupertinoIcons.gear_solid, '设置'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final accent = context.watch<SettingsStore>().accent.color;
    final inactive = theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75);
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: (dark ? const Color(0xFF1C1C1E) : const Color(0xFFF9F9FB)).withValues(alpha: 0.78),
            border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5), width: 0.5)),
          ),
          child: SafeArea(
            top: false,
            child: SizedBox(
              height: 52,
              child: Row(children: [
                for (var i = 0; i < _items.length; i++)
                  Expanded(
                    child: Semantics(
                      selected: i == index,
                      button: true,
                      label: _items[i].$3,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onSelect(i),
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Badge(
                            isLabelVisible: i == 2 && badge > 0,
                            label: Text('$badge'),
                            child: Icon(i == index ? _items[i].$2 : _items[i].$1,
                                size: 25, color: i == index ? accent : inactive),
                          ),
                          const SizedBox(height: 3),
                          Text(_items[i].$3,
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: i == index ? FontWeight.w600 : FontWeight.w500,
                                color: i == index ? accent : inactive,
                              )),
                        ]),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _WelcomeSheet extends StatelessWidget {
  const _WelcomeSheet();

  @override
  Widget build(BuildContext context) {
    final accent = context.watch<SettingsStore>().accent;
    final theme = Theme.of(context);
    Widget feature(IconData icon, String title, String detail) => Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, color: accent.color, size: 26),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                Text(detail, style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
              ]),
            ),
          ]),
        );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 32, 28, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ClipRRect(borderRadius: BorderRadius.circular(24), child: Image.asset('assets/app_logo.png', width: 96, height: 96)),
          const SizedBox(height: 20),
          Text('欢迎使用云析', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text('粘贴分享链接，直接高速下载', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 28),
          feature(Icons.add_link_rounded, '网盘 & 视频解析', '9 个网盘 + 抖音、B站、快手、微博、AcFun、小红书、Pixiv'),
          feature(Icons.bolt_rounded, '断点续传', '暂停后继续，B站高清音视频自动合轨'),
          feature(Icons.folder_rounded, '文件 App 可见', '下载内容在「文件 › 我的 iPhone › 云析」'),
          feature(Icons.favorite_rounded, '永久免费开源', '任何收费版本都是诈骗，请立即退款'),
          const SizedBox(height: 8),
          Text('本应用仅供学习交流，请遵守各平台用户协议。源代码遵循 GNU AGPL-3.0 协议。',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 16),
          GradientButton(
            onPressed: () {
              context.read<SettingsStore>().setHasSeenNotice(true);
              Navigator.pop(context);
            },
            child: const Text('开始使用'),
          ),
        ]),
      ),
    );
  }
}
