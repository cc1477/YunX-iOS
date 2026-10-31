// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import 'dart:async';
import 'dart:collection';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:provider/provider.dart';

import '../core/drives/c139_xunlei.dart';
import '../core/drives/pan123.dart';
import '../core/http.dart';
import '../core/models.dart';
import '../core/stores.dart';
import '../ui/design.dart';

class AccountsPage extends StatelessWidget {
  const AccountsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final accounts = context.watch<AccountStore>();
    final drives = [...SharePlatform.values]..sort((a, b) => (a.isAvailable ? 0 : 1).compareTo(b.isAvailable ? 0 : 1));
    final videos = [...VideoPlatform.values]..sort((a, b) => (a.isAvailable ? 0 : 1).compareTo(b.isAvailable ? 0 : 1));
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('账号', style: TextStyle(fontWeight: FontWeight.w800)),
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: AppBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
          children: [
            const SectionHeader('网盘'),
            GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(children: [
                for (final p in drives)
                  _AccountRow(
                      accountKey: AccountKey.drive(p),
                      benefit: p.loginBenefit,
                      available: p.isAvailable,
                      account: accounts.account(AccountKey.drive(p))),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 20),
              child: Text('登录信息仅保存在本机钥匙串中，不会上传到任何服务器。',
                  style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
            ),
            const SectionHeader('视频平台'),
            GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(children: [
                for (final p in videos)
                  _AccountRow(
                      accountKey: AccountKey.video(p),
                      benefit: p.loginBenefit,
                      available: p.isAvailable,
                      account: accounts.account(AccountKey.video(p))),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({required this.accountKey, required this.benefit, required this.available, required this.account});
  final AccountKey accountKey;
  final String benefit;
  final bool available;
  final Account? account;

  void _login(BuildContext context) {
    final page = switch (accountKey.loginKind) {
      LoginKind.web => WebLoginPage(accountKey: accountKey),
      LoginKind.password => PasswordLoginPage(accountKey: accountKey),
      LoginKind.manual => ManualCookiePage(accountKey: accountKey),
      LoginKind.none => null,
    };
    if (page != null) Navigator.of(context).push(CupertinoPageRoute(fullscreenDialog: true, builder: (_) => page));
  }

  Future<void> _logout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('退出${accountKey.displayName}'),
        content: const Text('将删除本机保存的登录信息'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('退出', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await context.read<AccountStore>().remove(accountKey);
      if (context.mounted) showToast(context, '已退出${accountKey.displayName}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canLogin = available && accountKey.loginKind != LoginKind.none;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(children: [
        PlatformLogo(accountKey.logo, size: 44, dimmed: !available),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(accountKey.displayName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              if (!available) const Tag('即将支持', color: Colors.orange),
              if (account != null) Tag(account!.nickname.isEmpty ? '已登录' : account!.nickname, color: Colors.green),
            ]),
            const SizedBox(height: 3),
            Text(benefit, maxLines: 2, style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
          ]),
        ),
        const SizedBox(width: 8),
        if (canLogin)
          account != null
              ? Chip2(label: '退出', color: Colors.red, onTap: () => _logout(context))
              : Chip2(label: '登录', onTap: () => _login(context))
        else if (available)
          const Icon(Icons.check_circle_rounded, color: Colors.green),
      ]),
    );
  }
}

/// 网页登录：打开平台登录页，轮询 Cookie，拿到必需字段后校验并保存
class WebLoginPage extends StatefulWidget {
  const WebLoginPage({super.key, required this.accountKey});
  final AccountKey accountKey;

  @override
  State<WebLoginPage> createState() => _WebLoginPageState();
}

class _WebLoginPageState extends State<WebLoginPage> {
  final _cookies = CookieManager.instance();
  Timer? _poller;
  double _progress = 0;
  bool _checking = false;
  bool _done = false;
  String _status = '登录成功后会自动识别';
  InAppWebViewController? _controller;

  AccountKey get k => widget.accountKey;

  @override
  void initState() {
    super.initState();
    _poller = Timer.periodic(const Duration(milliseconds: 1500), (_) => _capture(false));
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }

  Future<void> _capture(bool force) async {
    if (_done || _checking || !mounted) return;
    if (k.usesStorageLogin) {
      // 凭证在页面 localStorage 里（迅雷网页版）：读出来的整段 JSON 就是要保存的登录态
      final value = '${await _controller?.evaluateJavascript(source: XunleiResolver.readScript) ?? ''}';
      if (value.isEmpty || value == 'null') {
        if (force && mounted) setState(() => _status = '还没有拿到登录信息，请先完成登录');
        return;
      }
      return _finish(value, force);
    }
    final domain = k.cookieDomain;
    final List<Cookie> list;
    if (domain.isEmpty) {
      // 登录态分散在多个域（139）：取全部 Cookie
      list = await _cookies.getAllCookies();
    } else {
      final host = Uri.parse(k.loginUrl!).host;
      list = [
        ...await _cookies.getCookies(url: WebUri('https://$host')),
        if (host != domain) ...await _cookies.getCookies(url: WebUri('https://$domain')),
        if (host != 'www.$domain') ...await _cookies.getCookies(url: WebUri('https://www.$domain')),
      ];
    }
    final map = <String, String>{};
    for (final c in list) {
      map[c.name] = '${c.value}';
    }
    final ready = k.requiredCookies.every(map.containsKey);
    if (!ready && !force) return;
    if (map.isEmpty) {
      setState(() => _status = '还没有拿到登录信息，请先完成登录');
      return;
    }
    await _finish(map.entries.map((e) => '${e.key}=${e.value}').join('; '), force);
  }

  Future<void> _finish(String header, bool force) async {
    if (!mounted) return;
    setState(() {
      _checking = true;
      _status = '正在校验登录状态…';
    });
    final nickname = await AccountStore.validate(k, header);
    if (!mounted) return;
    if (nickname != null) {
      _done = true;
      _poller?.cancel();
      await context.read<AccountStore>().save(k, nickname, header);
      if (!mounted) return;
      showToast(context, '${k.displayName} 登录成功${nickname.isEmpty ? '' : '：$nickname'}');
      Navigator.pop(context);
    } else {
      setState(() {
        _checking = false;
        _status = force ? '校验未通过，请确认已完成登录' : '登录成功后会自动识别';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('登录${k.displayName}', style: const TextStyle(fontSize: 17)),
        actions: [
          IconButton(
            tooltip: '手动填写 Cookie',
            icon: const Icon(Icons.keyboard_alt_outlined),
            onPressed: () => Navigator.of(context).pushReplacement(
                CupertinoPageRoute(fullscreenDialog: true, builder: (_) => ManualCookiePage(accountKey: k))),
          ),
        ],
        bottom: _progress < 1
            ? PreferredSize(preferredSize: const Size.fromHeight(2), child: LinearProgressIndicator(value: _progress, minHeight: 2))
            : null,
      ),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(k.loginUrl!)),
        initialSettings: InAppWebViewSettings(userAgent: k.loginUserAgent, sharedCookiesEnabled: false),
        initialUserScripts: k.loginViewportWidth == null
            ? null
            : UnmodifiableListView([
                // 强制桌面宽度渲染，整页缩放可见、可双指放大
                UserScript(
                  source: "(function(){var m=document.querySelector('meta[name=\"viewport\"]');"
                      "if(!m){m=document.createElement('meta');m.name='viewport';(document.head||document.documentElement).appendChild(m);}"
                      "m.setAttribute('content','width=${k.loginViewportWidth}, user-scalable=yes');})()",
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_END,
                ),
              ]),
        onWebViewCreated: (c) {
          _controller = c;
          _cookies.deleteAllCookies();
        },
        onProgressChanged: (_, p) => setState(() => _progress = p / 100),
        onLoadStop: (_, __) => _capture(false),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(children: [
            Icon(_checking ? Icons.hourglass_top_rounded : Icons.shield_outlined, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(_status, style: const TextStyle(fontSize: 13))),
            Chip2(label: '我已登录', onTap: () => _capture(true)),
          ]),
        ),
      ),
    );
  }
}

/// 手动填写 Cookie（Pixiv 只能这样；其它平台作为网页登录失败时的备用方案）
class ManualCookiePage extends StatefulWidget {
  const ManualCookiePage({super.key, required this.accountKey});
  final AccountKey accountKey;

  @override
  State<ManualCookiePage> createState() => _ManualCookiePageState();
}

class _ManualCookiePageState extends State<ManualCookiePage> {
  final _c = TextEditingController();
  bool _checking = false;

  Future<void> _save() async {
    final k = widget.accountKey;
    final value = _c.text.trim().replaceAll('\n', '');
    setState(() => _checking = true);
    final nickname = await AccountStore.validate(k, value);
    if (!mounted) return;
    setState(() => _checking = false);
    if (nickname == null) return showToast(context, 'Cookie 校验未通过，请确认已登录且复制完整', error: true);
    await context.read<AccountStore>().save(k, nickname, value);
    if (!mounted) return;
    showToast(context, '${k.displayName} 登录成功');
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final k = widget.accountKey;
    return Scaffold(
      appBar: AppBar(
        title: Text('填写 ${k.displayName} Cookie', style: const TextStyle(fontSize: 17)),
        actions: [
          _checking
              ? const Padding(padding: EdgeInsets.all(16), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
              : TextButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
          controller: _c,
          minLines: 8,
          maxLines: 14,
          autocorrect: false,
          style: const TextStyle(fontFamily: 'Menlo', fontSize: 13),
          decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'name=value; name2=value2'),
        ),
        const SizedBox(height: 12),
        Text(
          '在电脑浏览器登录 ${k.displayName} 后，打开开发者工具 › 网络，复制任意请求头里的完整 Cookie 粘贴到这里。'
          '${k.requiredCookies.isEmpty ? '' : '需要包含 ${k.requiredCookies.join('、')}。'}',
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ]),
    );
  }
}

/// 账号密码登录（123 云盘等）
class PasswordLoginPage extends StatefulWidget {
  const PasswordLoginPage({super.key, required this.accountKey});
  final AccountKey accountKey;

  @override
  State<PasswordLoginPage> createState() => _PasswordLoginPageState();
}

class _PasswordLoginPageState extends State<PasswordLoginPage> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _working = false;
  String? _error;

  Future<void> _login() async {
    final k = widget.accountKey;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final String token;
      switch (k.drive) {
        case SharePlatform.pan123:
          token = await Pan123Resolver.passwordLogin(_user.text, _pass.text);
        default:
          throw AppError('该平台不支持账号密码登录');
      }
      final nickname = await AccountStore.validate(k, token) ?? '';
      if (!mounted) return;
      await context.read<AccountStore>().save(k, nickname, token);
      if (!mounted) return;
      showToast(context, '${k.displayName} 登录成功');
      Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = widget.accountKey;
    return Scaffold(
      appBar: AppBar(title: Text('登录${k.displayName}', style: const TextStyle(fontSize: 17))),
      body: AppBackground(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          const SizedBox(height: 12),
          Center(child: PlatformLogo(k.logo, size: 72)),
          const SizedBox(height: 28),
          GlassCard(
            child: Column(children: [
              TextField(
                controller: _user,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                autofillHints: const [AutofillHints.username],
                decoration: const InputDecoration(labelText: '手机号 / 邮箱', border: InputBorder.none),
              ),
              const Divider(),
              TextField(
                controller: _pass,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                decoration: const InputDecoration(labelText: '密码', border: InputBorder.none),
                onSubmitted: (_) => _login(),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          Text(
            _error ?? '账号密码只用于向 ${k.displayName} 官方服务器换取登录凭证，不会保存密码。',
            style: TextStyle(fontSize: 13, color: _error != null ? Colors.red : Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 24),
          GradientButton(
            onPressed: _working ? null : _login,
            child: _working
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('登录'),
          ),
        ]),
      ),
    );
  }
}
