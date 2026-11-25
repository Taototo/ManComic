import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/routing/webview.dart';

import 'token_import.dart';

Future<Map<String, dynamic>?> showOpenListLogin(
  BuildContext context, {
  required String driver,
  String clientId = '',
  String clientSecret = '',
}) async {
  final requestUri = openListLoginUri(
    driver,
    clientId: clientId,
    clientSecret: clientSecret,
  );
  final requestUrl = requestUri.toString();
  Map<String, dynamic>? authorization;
  String? failure;
  var finished = false;
  var reading = false;
  var redirected = false;

  bool receiveCallback(String url, VoidCallback close) {
    if (finished) return true;
    try {
      final value = parseOpenListLoginCallback(
        url,
        driver: driver,
        clientId: clientId,
        clientSecret: clientSecret,
      );
      if (value == null) return false;
      authorization = value;
    } on FormatException catch (error) {
      failure = error.message;
    }
    finished = true;
    close();
    return true;
  }

  Future<void> readPage(
    Future<dynamic> Function(String script) evaluate,
    VoidCallback close,
  ) async {
    if (finished || reading) return;
    reading = true;
    try {
      var page = await evaluate('''
(() => {
  if (location.origin !== 'https://api.oplist.org') return null;
  return {
    url: window.__veneraOpenListCallback || location.href,
    body: location.pathname === ${jsonEncode(requestUri.path)}
      ? document.body.textContent : null
  };
})()
''');
      if (finished) return;
      if (page is String) page = jsonDecode(page);
      if (page is! Map) return;
      final url = page['url'] as String? ?? '';
      if (receiveCallback(url, close) || redirected || url != requestUrl) {
        return;
      }
      // Load /requests in the WebView itself so its Set-Cookie headers and the
      // subsequent provider login share the same browser session.
      final response = jsonDecode(page['body'] as String);
      final target = response is Map ? response['text'] : null;
      final loginUri = target is String ? Uri.tryParse(target) : null;
      if (loginUri == null ||
          loginUri.scheme != 'https' ||
          loginUri.host.isEmpty) {
        throw FormatException(
          target is String ? target : '无法启动授权',
        );
      }
      redirected = true;
      await evaluate('location.replace(${jsonEncode(loginUri.toString())})');
    } catch (error) {
      if (!finished) {
        failure = error is FormatException
            ? error.message
            : '无法启动授权';
        finished = true;
        close();
      }
    } finally {
      reading = false;
    }
  }

  if (App.isLinux) {
    if (!await DesktopWebview.isAvailable()) {
      throw const FormatException('当前平台无法打开登录窗口');
    }
    if (!context.mounted) return null;
    final closed = Completer<void>();
    final webview = DesktopWebview(
      initialUrl: requestUrl,
      onNavigation: (url, webview) => receiveCallback(url, webview.close),
      onTitleChange: (_, webview) =>
          readPage(webview.evaluateJavascript, webview.close),
      onClose: () => closed.complete(),
    );
    // ManComi 的 DesktopWebview.open() 是同步启动、内部异步创建窗口，
    // 关闭由 onClose 通知，这里直接等 closed 即可。
    webview.open();
    await closed.future;
  } else {
    await context.to<void>(() {
      void close() => context.pop();
      return AppWebview(
        initialUrl: requestUrl,
        // ManComi 的 AppWebview 用 onNavigation 接 URL；回调里返回 true 表示
        // 拦截导航，正好对应「已拿到授权，关掉登录页」。
        onNavigation: (url, _) => receiveCallback(url, close),
        onLoadStop: (controller) => readPage(
          (script) => controller.evaluateJavascript(source: script),
          close,
        ),
      );
    });
  }
  finished = true;
  if (failure != null) throw FormatException(failure!);
  return authorization;
}
