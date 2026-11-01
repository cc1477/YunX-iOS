// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/download.dart';
import '../core/stores.dart';
import '../ui/design.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsStore>();
    final d = context.watch<DownloadManager>();
    final history = context.watch<HistoryStore>();
    final theme = Theme.of(context);
    Widget group(String title, List<Widget> children, {String? footer}) => Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SectionHeader(title),
            GlassCard(padding: const EdgeInsets.symmetric(vertical: 4), child: Column(children: children)),
            if (footer != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Text(footer, style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
              ),
          ]),
        );
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('设置', style: TextStyle(fontWeight: FontWeight.w800)),
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: AppBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: LinearGradient(colors: [
                  s.accent.color.withValues(alpha: 0.18),
                  s.accent.secondary.withValues(alpha: 0.10),
                ]),
              ),
              child: Row(children: [
                ClipRRect(borderRadius: BorderRadius.circular(16), child: Image.asset('assets/app_logo.png', width: 60, height: 60)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('云析 YunX', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                    Text('网盘 / 视频解析下载 · Flutter 版', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                    const SizedBox(height: 6),
                    Wrap(spacing: 6, children: [
                      Tag('已完成 ${d.completed.length}', color: s.accent.color),
                      const Tag('开源免费', color: Colors.green),
                    ]),
                  ]),
                ),
              ]),
            ),
            group('外观', [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (final t in AccentTheme.values)
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          s.setAccent(t);
                        },
                        child: Column(children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              gradient: t.gradient,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: s.accent == t ? 2.5 : 0),
                              boxShadow: [if (s.accent == t) BoxShadow(color: t.color.withValues(alpha: 0.5), blurRadius: 8)],
                            ),
                            child: s.accent == t ? const Icon(Icons.check_rounded, color: Colors.white, size: 18) : null,
                          ),
                          const SizedBox(height: 6),
                          Text(t.label, style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
                        ]),
                      ),
                  ],
                ),
              ),
              ListTile(
                title: const Text('深色模式'),
                trailing: DropdownButton<ThemeMode>(
                  value: s.themeMode,
                  underline: const SizedBox.shrink(),
                  onChanged: (v) => s.setThemeMode(v ?? ThemeMode.system),
                  items: const [
                    DropdownMenuItem(value: ThemeMode.system, child: Text('跟随系统')),
                    DropdownMenuItem(value: ThemeMode.light, child: Text('浅色')),
                    DropdownMenuItem(value: ThemeMode.dark, child: Text('深色')),
                  ],
                ),
              ),
            ]),
            group('下载', [
              ListTile(
                title: const Text('同时下载'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline_rounded),
                    onPressed: s.maxConcurrent > 1 ? () => s.setMaxConcurrent(s.maxConcurrent - 1) : null,
                  ),
                  Text('${s.maxConcurrent} 个', style: const TextStyle(fontWeight: FontWeight.w600)),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline_rounded),
                    onPressed: s.maxConcurrent < 6 ? () => s.setMaxConcurrent(s.maxConcurrent + 1) : null,
                  ),
                ]),
              ),
              SwitchListTile(
                title: const Text('完成后自动存入相册'),
                value: s.autoSaveToPhotos,
                onChanged: s.setAutoSaveToPhotos,
              ),
              const ListTile(title: Text('保存位置'), trailing: Text('文件 › 我的 iPhone › 云析')),
            ], footer: '图片和视频开启自动存入相册后，下载完成会同时保存一份到系统相册。'),
            group('解析', [
              SwitchListTile(
                title: const Text('识别剪贴板中的链接'),
                value: s.clipboardDetect,
                onChanged: s.setClipboardDetect,
              ),
              ListTile(
                title: Text('清空解析历史', style: TextStyle(color: history.entries.isEmpty ? theme.disabledColor : Colors.red)),
                onTap: history.entries.isEmpty
                    ? null
                    : () {
                        history.clear();
                        showToast(context, '已清空解析历史');
                      },
              ),
            ]),
            group('关于', [
              const ListTile(title: Text('原项目（Android）'), trailing: Text('github.com/CYQawa/YunX')),
              const ListTile(title: Text('开源协议'), trailing: Text('GNU AGPL-3.0')),
            ]),
            Text(
              '云析永远免费开源。如果你是在任何地方「花钱买到」的，说明你被骗了，请立即退款。本应用仅供学习交流，所解析内容的版权归原作者及平台所有，请遵守各平台用户协议。',
              style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
