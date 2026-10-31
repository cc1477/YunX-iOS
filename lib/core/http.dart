// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 一次请求的原始响应（需要读 Location / Set-Cookie / Content-Range 时用）。
class RawResponse {
  RawResponse(this.status, this.bytes, this.headers, this.cookies, this.finalUrl, [this.setCookieLines = const []]);

  final int status;
  final Uint8List bytes;

  /// 响应头，键统一小写
  final Map<String, String> headers;

  /// 拆分后的 Set-Cookie（name → value）
  final Map<String, String> cookies;
  final Uri finalUrl;

  /// 原始 Set-Cookie 行（115 要按 path 挑 CDN Cookie）
  final List<String> setCookieLines;

  String get text => utf8.decode(bytes, allowMalformed: true);
  bool get ok => status >= 200 && status < 300;
  String? header(String name) => headers[name.toLowerCase()];
}

class AppError implements Exception {
  AppError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 常用 UA
class UA {
  static const chrome =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  static const iPhone =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
}

/// 全局 HTTP 客户端。
///
/// ★ 不使用任何 Cookie 罐：各平台的 Cookie 由调用方显式拼进请求头（与安卓版 OkHttp 一致），
///   否则 A 平台下发的 Cookie 会悄悄带到 B 平台请求里。
class Http {
  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..userAgent = null;

  static Future<RawResponse> send(
    String url, {
    String method = 'GET',
    Map<String, String> headers = const {},
    List<int>? body,
    bool followRedirects = true,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final uri = Uri.parse(url);
    try {
      final request = await _client.openUrl(method, uri).timeout(timeout);
      request.followRedirects = followRedirects;
      request.maxRedirects = 10;
      headers.forEach((k, v) => request.headers.set(k, v, preserveHeaderCase: true));
      if (body != null) {
        request.contentLength = body.length;
        request.add(body);
      }
      final response = await request.close().timeout(timeout);
      final builder = await response
          .fold<BytesBuilder>(BytesBuilder(copy: false), (b, chunk) => b..add(chunk))
          .timeout(timeout * 3);
      final lowered = <String, String>{};
      response.headers.forEach((name, values) => lowered[name.toLowerCase()] = values.join(', '));
      final cookies = <String, String>{};
      final lines = response.headers[HttpHeaders.setCookieHeader] ?? const <String>[];
      for (final line in lines) {
        final pair = line.split(';').first;
        final index = pair.indexOf('=');
        if (index > 0) cookies[pair.substring(0, index).trim()] = pair.substring(index + 1).trim();
      }
      var finalUrl = uri;
      for (final redirect in response.redirects) {
        finalUrl = finalUrl.resolveUri(redirect.location);
      }
      return RawResponse(response.statusCode, builder.takeBytes(), lowered, cookies, finalUrl, lines);
    } on AppError {
      rethrow;
    } catch (e) {
      throw AppError('网络请求失败：${e.runtimeType}');
    }
  }

  static Future<RawResponse> postJson(String url, Object object, {Map<String, String> headers = const {}}) {
    return send(url,
        method: 'POST',
        headers: {...headers, 'Content-Type': 'application/json'},
        body: utf8.encode(jsonEncode(object)));
  }

  static Future<RawResponse> postForm(String url, List<MapEntry<String, String>> fields,
      {Map<String, String> headers = const {}, bool followRedirects = true}) {
    return send(url,
        method: 'POST',
        headers: {...headers, 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'},
        body: utf8.encode(formEncode(fields)),
        followRedirects: followRedirects);
  }

  static String formEncode(List<MapEntry<String, String>> fields) =>
      fields.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');

  static String q(String value) => Uri.encodeComponent(value);
}
