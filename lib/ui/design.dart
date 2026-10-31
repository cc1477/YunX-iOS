// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models.dart';
import '../core/stores.dart';

/// 全局背景：分组背景色 + 两团随主题色变化的柔光
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final accent = context.watch<SettingsStore>().accent;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final w = MediaQuery.sizeOf(context).width;
    return Stack(children: [
      Positioned.fill(child: ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerLowest)),
      Positioned(
        left: -w * 0.4,
        top: -w * 0.6,
        child: _Glow(color: accent.color.withValues(alpha: dark ? 0.35 : 0.22), size: w * 1.1),
      ),
      Positioned(
        right: -w * 0.4,
        top: -w * 0.25,
        child: _Glow(color: accent.secondary.withValues(alpha: dark ? 0.28 : 0.16), size: w * 0.9),
      ),
      Positioned.fill(child: child),
    ]);
  }
}

class _Glow extends StatelessWidget {
  const _Glow({required this.color, required this.size});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => ImageFiltered(
        imageFilter: ImageFilter.blur(sigmaX: 80, sigmaY: 80),
        child: Container(width: size, height: size, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      );
}

/// 毛玻璃卡片
class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.radius = 22});
  final Widget child;
  final EdgeInsets padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          width: double.infinity,
          padding: padding,
          decoration: BoxDecoration(
            color: (dark ? Colors.white : Colors.white).withValues(alpha: dark ? 0.07 : 0.72),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: Colors.white.withValues(alpha: dark ? 0.10 : 0.5), width: 0.6),
          ),
          child: child,
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing, this.onTap});
  final String title;
  final String? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
        child: Row(children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          const Spacer(),
          if (trailing != null) TextButton(onPressed: onTap, child: Text(trailing!)),
        ]),
      );
}

/// 渐变主按钮
class GradientButton extends StatefulWidget {
  const GradientButton({super.key, required this.child, required this.onPressed});
  final Widget child;
  final VoidCallback? onPressed;

  @override
  State<GradientButton> createState() => _GradientButtonState();
}

class _GradientButtonState extends State<GradientButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final accent = context.watch<SettingsStore>().accent;
    final enabled = widget.onPressed != null;
    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _down = true) : null,
      onTapUp: enabled ? (_) => setState(() => _down = false) : null,
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onPressed,
      child: AnimatedScale(
        scale: _down ? 0.97 : 1,
        duration: const Duration(milliseconds: 120),
        child: AnimatedOpacity(
          opacity: enabled ? 1 : 0.45,
          duration: const Duration(milliseconds: 150),
          child: Container(
            height: 52,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: accent.gradient,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                if (enabled) BoxShadow(color: accent.color.withValues(alpha: 0.35), blurRadius: 16, offset: const Offset(0, 6)),
              ],
            ),
            child: DefaultTextStyle.merge(
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16),
              child: IconTheme.merge(data: const IconThemeData(color: Colors.white), child: widget.child),
            ),
          ),
        ),
      ),
    );
  }
}

class Chip2 extends StatelessWidget {
  const Chip2({super.key, required this.label, this.icon, this.color, this.onTap});
  final String label;
  final IconData? icon;
  final Color? color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = color ?? context.watch<SettingsStore>().accent.color;
    return Material(
      color: c.withValues(alpha: 0.12),
      shape: const StadiumBorder(),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 16, color: c), const SizedBox(width: 5)],
            Text(label, style: TextStyle(color: c, fontWeight: FontWeight.w600, fontSize: 13)),
          ]),
        ),
      ),
    );
  }
}

class PlatformLogo extends StatelessWidget {
  const PlatformLogo(this.asset, {super.key, this.size = 36, this.dimmed = false});
  final String asset;
  final double size;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    Widget img = Image.asset(asset, width: size * 0.76, height: size * 0.76, fit: BoxFit.contain);
    if (dimmed) {
      img = Opacity(
        opacity: 0.5,
        child: ColorFiltered(
          colorFilter: const ColorFilter.matrix([
            0.33, 0.33, 0.33, 0, 0, 0.33, 0.33, 0.33, 0, 0, 0.33, 0.33, 0.33, 0, 0, 0, 0, 0, 1, 0, //
          ]),
          child: img,
        ),
      );
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: img,
    );
  }
}

class FileIcon extends StatelessWidget {
  const FileIcon(this.kind, {super.key, this.size = 40});
  final FileKind kind;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: kind.color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(size * 0.3)),
        child: Icon(kind.icon, color: kind.color, size: size * 0.52),
      );
}

class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(20)),
      child: Text(text, style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }
}

/// 渐变进度条（progress 为 null 时显示不定进度）
class GradientProgress extends StatelessWidget {
  const GradientProgress({super.key, this.value});
  final double? value;

  @override
  Widget build(BuildContext context) {
    final accent = context.watch<SettingsStore>().accent;
    final track = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08);
    if (value == null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(minHeight: 6, color: accent.color, backgroundColor: track),
      );
    }
    return Container(
      height: 6,
      decoration: BoxDecoration(color: track, borderRadius: BorderRadius.circular(4)),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: value!.clamp(0.02, 1.0),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          decoration: BoxDecoration(gradient: accent.gradient, borderRadius: BorderRadius.circular(4)),
        ),
      ),
    );
  }
}

/// 顶部提示条
class ToastOverlay extends StatelessWidget {
  const ToastOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final toast = context.watch<ToastCenter>();
    final msg = toast.message;
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          transitionBuilder: (c, a) => SlideTransition(
            position: Tween(begin: const Offset(0, -1), end: Offset.zero).animate(a),
            child: FadeTransition(opacity: a, child: c),
          ),
          child: msg == null
              ? const SizedBox.shrink()
              : Padding(
                  key: ValueKey(msg),
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                  child: Material(
                    elevation: 8,
                    shadowColor: Colors.black26,
                    borderRadius: BorderRadius.circular(30),
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(toast.isError ? Icons.error_rounded : Icons.check_circle_rounded,
                            color: toast.isError ? Colors.orange : Colors.green, size: 20),
                        const SizedBox(width: 10),
                        Flexible(child: Text(msg, maxLines: 3, style: const TextStyle(fontWeight: FontWeight.w500))),
                      ]),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

void showToast(BuildContext context, String message, {bool error = false}) =>
    context.read<ToastCenter>().show(message, error: error);
