// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import 'dart:convert';

/// 轻量 JSON 访问器，语义对齐安卓版 org.json 的 `optXxx`：缺字段 / null 一律给默认值，不抛错。
class J {
  const J(this.raw);

  final dynamic raw;

  static J? tryParse(String text) {
    try {
      return J(jsonDecode(text));
    } catch (_) {
      return null;
    }
  }

  J operator [](Object key) {
    final r = raw;
    if (key is int) return (r is List && key >= 0 && key < r.length) ? J(r[key]) : const J(null);
    return r is Map ? J(r[key]) : const J(null);
  }

  bool get exists => raw != null;
  bool get isMap => raw is Map;

  String get s {
    final r = raw;
    if (r == null) return '';
    if (r is String) return r == 'null' ? '' : r;
    if (r is double && r == r.roundToDouble()) return r.toInt().toString();
    if (r is num || r is bool) return r.toString();
    return '';
  }

  int get i {
    final r = raw;
    if (r is int) return r;
    if (r is double) return r.toInt();
    if (r is bool) return r ? 1 : 0;
    if (r is String) return int.tryParse(r) ?? double.tryParse(r)?.toInt() ?? 0;
    return 0;
  }

  bool get b {
    final r = raw;
    if (r is bool) return r;
    if (r is num) return r != 0;
    if (r is String) return r == 'true' || r == '1';
    return false;
  }

  List<J> get list => raw is List ? (raw as List).map((e) => J(e)).toList() : const [];
  List<String> get keys => raw is Map ? (raw as Map).keys.map((e) => '$e').toList() : const [];

  /// 依次尝试多个键名，返回第一个非空字符串
  String any(List<String> names) {
    for (final n in names) {
      final v = this[n].s;
      if (v.isNotEmpty) return v;
    }
    return '';
  }

  /// 依次尝试多个键名，返回第一个存在的节点
  J first(List<String> names) {
    for (final n in names) {
      if (this[n].exists) return this[n];
    }
    return const J(null);
  }
}
