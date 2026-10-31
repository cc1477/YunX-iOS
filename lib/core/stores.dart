// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'drives/resolver.dart';
import 'links.dart';
import 'models.dart';
import 'video/video_http.dart';

// MARK: 账号（存钥匙串）

class Account {
  Account(this.nickname, this.cookie, this.savedAt);
  final String nickname;
  final String cookie;
  final DateTime savedAt;

  Map<String, dynamic> toJson() => {'nickname': nickname, 'cookie': cookie, 'savedAt': savedAt.millisecondsSinceEpoch};
  factory Account.fromJson(Map<String, dynamic> j) =>
      Account('${j['nickname'] ?? ''}', '${j['cookie'] ?? ''}', DateTime.fromMillisecondsSinceEpoch(j['savedAt'] as int? ?? 0));
}

class AccountStore extends ChangeNotifier {
  static const _storage = FlutterSecureStorage();
  static const _key = 'yunx.accounts';
  Map<String, Account> _accounts = {};

  Future<void> load() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw != null) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        _accounts = map.map((k, v) => MapEntry(k, Account.fromJson(v as Map<String, dynamic>)));
        notifyListeners();
      }
    } catch (_) {}
  }

  Account? account(AccountKey key) => _accounts[key.storageKey];
  String cookie(AccountKey key) => _accounts[key.storageKey]?.cookie ?? '';

  Future<void> save(AccountKey key, String nickname, String cookie) async {
    _accounts[key.storageKey] = Account(nickname, cookie, DateTime.now());
    notifyListeners();
    await _persist();
  }

  Future<void> remove(AccountKey key) async {
    _accounts.remove(key.storageKey);
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() =>
      _storage.write(key: _key, value: jsonEncode(_accounts.map((k, v) => MapEntry(k, v.toJson()))));

  /// 校验 Cookie / Token 是否有效，返回昵称；无效返回 null
  static Future<String?> validate(AccountKey key, String cookie) async {
    if (key.drive != null) return ShareResolvers.validate(key.drive!, cookie);
    final parser = VideoParseService.parsers[key.video];
    if (parser != null) return parser.validateCookie(cookie);
    return cookie.trim().isEmpty ? null : '';
  }
}

// MARK: 设置

enum AccentTheme {
  cloud('云蓝', 0xFF4C8BF5, 0xFF7B61FF),
  violet('星紫', 0xFF7C5CFF, 0xFFE056FD),
  mint('薄荷', 0xFF14B8A6, 0xFF3B82F6),
  coral('珊瑚', 0xFFFF6B6B, 0xFFF59E0B),
  amber('琥珀', 0xFFF59E0B, 0xFFEF4444),
  graphite('石墨', 0xFF64748B, 0xFF1E293B);

  const AccentTheme(this.label, this._a, this._b);
  final String label;
  final int _a, _b;
  Color get color => Color(_a);
  Color get secondary => Color(_b);
  LinearGradient get gradient =>
      LinearGradient(colors: [color, secondary], begin: Alignment.topLeft, end: Alignment.bottomRight);
}

class SettingsStore extends ChangeNotifier {
  late SharedPreferences _prefs;
  AccentTheme accent = AccentTheme.cloud;
  ThemeMode themeMode = ThemeMode.system;
  int maxConcurrent = 3;
  bool clipboardDetect = true;
  bool autoSaveToPhotos = false;
  bool hasSeenNotice = false;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    accent = AccentTheme.values.firstWhere((e) => e.name == _prefs.getString('accent'), orElse: () => AccentTheme.cloud);
    themeMode = ThemeMode.values.firstWhere((e) => e.name == _prefs.getString('themeMode'), orElse: () => ThemeMode.system);
    maxConcurrent = _prefs.getInt('maxConcurrent') ?? 3;
    clipboardDetect = _prefs.getBool('clipboardDetect') ?? true;
    autoSaveToPhotos = _prefs.getBool('autoSaveToPhotos') ?? false;
    hasSeenNotice = _prefs.getBool('hasSeenNotice') ?? false;
    notifyListeners();
  }

  void setAccent(AccentTheme v) => _set(() => accent = v, () => _prefs.setString('accent', v.name));
  void setThemeMode(ThemeMode v) => _set(() => themeMode = v, () => _prefs.setString('themeMode', v.name));
  void setMaxConcurrent(int v) => _set(() => maxConcurrent = v, () => _prefs.setInt('maxConcurrent', v));
  void setClipboardDetect(bool v) => _set(() => clipboardDetect = v, () => _prefs.setBool('clipboardDetect', v));
  void setAutoSaveToPhotos(bool v) => _set(() => autoSaveToPhotos = v, () => _prefs.setBool('autoSaveToPhotos', v));
  void setHasSeenNotice(bool v) => _set(() => hasSeenNotice = v, () => _prefs.setBool('hasSeenNotice', v));

  void _set(void Function() apply, Future<bool> Function() persist) {
    apply();
    notifyListeners();
    persist();
  }
}

// MARK: 解析历史

class HistoryEntry {
  HistoryEntry(this.text, this.title, this.platformName, this.logo, this.date);
  final String text, title, platformName, logo;
  final DateTime date;

  Map<String, dynamic> toJson() =>
      {'text': text, 'title': title, 'platformName': platformName, 'logo': logo, 'date': date.millisecondsSinceEpoch};
  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry('${j['text']}', '${j['title']}',
      '${j['platformName']}', '${j['logo']}', DateTime.fromMillisecondsSinceEpoch(j['date'] as int? ?? 0));
}

class HistoryStore extends ChangeNotifier {
  late SharedPreferences _prefs;
  List<HistoryEntry> entries = [];

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    try {
      final raw = _prefs.getString('history');
      if (raw != null) {
        entries = (jsonDecode(raw) as List).map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>)).toList();
      }
    } catch (_) {}
    notifyListeners();
  }

  void add(String text, String title, DetectedLink link) {
    entries.removeWhere((e) => e.text == text);
    entries.insert(0, HistoryEntry(text, title, link.displayName, link.logo, DateTime.now()));
    if (entries.length > 30) entries = entries.sublist(0, 30);
    _persist();
  }

  void remove(HistoryEntry e) {
    entries.remove(e);
    _persist();
  }

  void clear() {
    entries.clear();
    _persist();
  }

  void _persist() {
    notifyListeners();
    _prefs.setString('history', jsonEncode(entries.map((e) => e.toJson()).toList()));
  }
}

// MARK: 提示条

class ToastCenter extends ChangeNotifier {
  String? message;
  bool isError = false;
  int _seq = 0;

  void show(String text, {bool error = false}) {
    message = text;
    isError = error;
    final id = ++_seq;
    notifyListeners();
    Future.delayed(const Duration(milliseconds: 2600), () {
      if (id == _seq) {
        message = null;
        notifyListeners();
      }
    });
  }
}
