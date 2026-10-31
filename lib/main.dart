// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
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
      appBarTheme: base.appBarTheme.copyWith(centerTitle: false),
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
      builder: (context, child) => Stack(children: [child ?? const SizedBox.shrink(), const ToastOverlay()]),
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
        body: IndexedStack(index: _tab, children: const [ResolvePage(), AccountsPage(), DownloadsPage(), SettingsPage()]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) {
            HapticFeedback.selectionClick();
            setState(() => _tab = i);
          },
          destinations: [
            const NavigationDestination(icon: Icon(Icons.link_rounded), label: '解析'),
            const NavigationDestination(icon: Icon(Icons.account_circle_outlined), selectedIcon: Icon(Icons.account_circle_rounded), label: '账号'),
            NavigationDestination(
              icon: Badge(
                isLabelVisible: d.runningCount > 0,
                label: Text('${d.runningCount}'),
                child: const Icon(Icons.download_outlined),
              ),
              selectedIcon: const Icon(Icons.download_rounded),
              label: '下载',
            ),
            const NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings_rounded), label: '设置'),
          ],
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
          feature(Icons.add_link_rounded, '网盘 & 视频解析', '夸克、UC、百度、115、123、光鸭、蓝奏云，抖音、B站、快手、微博、AcFun'),
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
