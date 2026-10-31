// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later

/// 正则小工具
class RX {
  static final Map<String, RegExp> _cache = {};

  static RegExp re(String pattern, {bool ignoreCase = true, bool dotAll = false}) =>
      _cache.putIfAbsent('$ignoreCase$dotAll$pattern',
          () => RegExp(pattern, caseSensitive: !ignoreCase, dotAll: dotAll));

  /// 第一个匹配的全部分组（0 为整体；未参与匹配的分组为空串）
  static List<String>? groups(String pattern, String text, {bool ignoreCase = true, bool dotAll = false}) {
    final m = re(pattern, ignoreCase: ignoreCase, dotAll: dotAll).firstMatch(text);
    if (m == null) return null;
    return List.generate(m.groupCount + 1, (i) => m.group(i) ?? '');
  }

  static String? first(String pattern, String text, {int group = 1, bool ignoreCase = true, bool dotAll = false}) {
    final g = groups(pattern, text, ignoreCase: ignoreCase, dotAll: dotAll);
    if (g == null || group >= g.length) return null;
    final v = g[group];
    return v.isEmpty && group > 0 ? null : v;
  }

  static List<List<String>> all(String pattern, String text, {bool ignoreCase = true, bool dotAll = false}) =>
      re(pattern, ignoreCase: ignoreCase, dotAll: dotAll)
          .allMatches(text)
          .map((m) => List.generate(m.groupCount + 1, (i) => m.group(i) ?? ''))
          .toList();
}

extension StringX on String {
  String trimTrailing(String chars) {
    var r = this;
    while (r.isNotEmpty && chars.contains(r[r.length - 1])) {
      r = r.substring(0, r.length - 1);
    }
    return r;
  }

  /// 文件名清洗：去掉非法字符与首尾空白、点号
  String get sanitizedFileName {
    final cleaned = replaceAll(RegExp(r'[/\\:*?"<>|\n\r\t]'), '_').trim();
    return cleaned.replaceAll(RegExp(r'^\.+|\.+$'), '').trim();
  }

  String take(int n) => length <= n ? this : substring(0, n);

  /// 协议相对 / 明文 http 统一升级为 https
  String get secureUrl {
    if (startsWith('//')) return 'https:$this';
    if (startsWith('http://')) return 'https://${substring(7)}';
    return this;
  }

  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

String fileBase(String title, String fallback) {
  final cleaned = title.sanitizedFileName.take(80);
  return cleaned.isEmpty ? fallback : cleaned;
}

class Fmt {
  static String bytes(int value) {
    if (value <= 0) return '—';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = value.toDouble();
    var u = 0;
    while (v >= 1024 && u < units.length - 1) {
      v /= 1024;
      u++;
    }
    return '${v.toStringAsFixed(u == 0 ? 0 : (v >= 100 ? 0 : 1))} ${units[u]}';
  }

  static String speed(double bps) => bps > 0 ? '${bytes(bps.toInt())}/s' : '';

  static String date(int seconds) {
    if (seconds <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  static String relative(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return date(t.millisecondsSinceEpoch ~/ 1000).substring(0, 10);
  }

  /// 「1.2 M」这类展示大小 → 字节数
  static int parseDisplaySize(String text) {
    final g = RX.groups(r'([\d.]+)\s*([KMGT]?)', text.trim());
    if (g == null) return 0;
    final v = double.tryParse(g[1]) ?? 0;
    const factors = {'K': 1024.0, 'M': 1048576.0, 'G': 1073741824.0, 'T': 1099511627776.0};
    return (v * (factors[g[2].toUpperCase()] ?? 1)).toInt();
  }
}
