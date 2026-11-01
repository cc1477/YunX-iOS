// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// iOS 系统配色（与 UIKit 语义色一致），替换 Material 3 由种子色生成的偏紫灰色
class IOSColors {
  static const groupedBackground = Color(0xFFF2F2F7);
  static const separatorLight = Color(0x4A3C3C43);
  static const separatorDark = Color(0x99545458);
  static const secondaryLabelLight = Color(0x993C3C43);
  static const secondaryLabelDark = Color(0x99EBEBF5);
  static const elevatedDark = Color(0xFF1C1C1E);
  static const elevatedDark2 = Color(0xFF2C2C2E);

  static Color separator(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? separatorDark : separatorLight;

  /// 浮层材质（类似 UIBlurEffect.systemMaterial）的底色
  static Color material(BuildContext context) => Theme.of(context).brightness == Brightness.dark
      ? elevatedDark.withValues(alpha: 0.82)
      : Colors.white.withValues(alpha: 0.82);
}

/// 毛玻璃浮层：提示条、加载框、浮动卡片共用
class Frosted extends StatelessWidget {
  const Frosted({super.key, required this.child, this.radius = 20, this.padding = const EdgeInsets.all(12)});
  final Widget child;
  final double radius;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 24, offset: Offset(0, 8))],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Container(
              padding: padding,
              decoration: BoxDecoration(
                color: IOSColors.material(context),
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: IOSColors.separator(context), width: 0.5),
              ),
              child: child,
            ),
          ),
        ),
      );
}

class SheetAction {
  const SheetAction(this.label, this.onTap, {this.destructive = false});
  final String label;
  final VoidCallback onTap;
  final bool destructive;
}

/// iOS 动作表（UIAlertController.actionSheet），替代 Material 底部菜单 / 弹出菜单
Future<void> showActionSheet(BuildContext context,
    {String? title, String? message, required List<SheetAction> actions}) {
  return showCupertinoModalPopup<void>(
    context: context,
    builder: (ctx) => CupertinoActionSheet(
      title: title == null ? null : Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      message: message == null ? null : Text(message),
      actions: [
        for (final a in actions)
          CupertinoActionSheetAction(
            isDestructiveAction: a.destructive,
            onPressed: () {
              Navigator.pop(ctx);
              a.onTap();
            },
            child: Text(a.label),
          ),
      ],
      cancelButton: CupertinoActionSheetAction(
        isDefaultAction: true,
        onPressed: () => Navigator.pop(ctx),
        child: const Text('取消'),
      ),
    ),
  );
}

/// iOS 确认弹窗（UIAlertController.alert），返回是否确认
Future<bool> showConfirm(BuildContext context,
    {required String title, String? message, String confirm = '确定', bool destructive = false}) async {
  final ok = await showCupertinoDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => CupertinoAlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        CupertinoDialogAction(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        CupertinoDialogAction(
          isDefaultAction: !destructive,
          isDestructiveAction: destructive,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return ok == true;
}

/// iOS 表单输入框样式：白底 + 发丝描边（深色为二级背景色），聚焦时描边变主题色
InputDecoration iosField(BuildContext context, {String? hint, IconData? prefix, double radius = 12, bool dense = false}) {
  final theme = Theme.of(context);
  final dark = theme.brightness == Brightness.dark;
  OutlineInputBorder border(Color c, double w) =>
      OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide(color: c, width: w));
  return InputDecoration(
    hintText: hint,
    isDense: dense,
    prefixIcon: prefix == null ? null : Icon(prefix, size: 20, color: theme.colorScheme.onSurfaceVariant),
    filled: true,
    fillColor: dark ? IOSColors.elevatedDark2 : Colors.white,
    enabledBorder: border(IOSColors.separator(context), 0.5),
    border: border(IOSColors.separator(context), 0.5),
    focusedBorder: border(theme.colorScheme.primary, 1.2),
  );
}
