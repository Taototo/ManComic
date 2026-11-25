import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show InAppWebViewController;
import 'package:venera/foundation/app.dart';
import 'package:venera/routing/webview.dart';

const _loginUrl = 'https://pan.quark.cn/';
const _apiUrl = 'https://drive.quark.cn/1/clouddrive';
const _desktopUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/133.0.0.0 Safari/537.36';

/// Verify the session with a plain HTTP request from the app side. Doing this
/// outside the WebView avoids the cross-origin fetch being blocked by CORS
/// inside the login page (which leaves the JS probe hanging on some ROMs).
Future<bool> _verifyQuarkSession(Map<String, String> cookies) async {
  final cookie = cookies.entries
      .map((entry) => '${entry.key}=${entry.value}')
      .join('; ');
  if (cookie.isEmpty) return false;
  final client = HttpClient();
  try {
    final uri = Uri.parse(
      '$_apiUrl/file/sort?pr=ucpro&fr=pc&pdir_fid=0&_page=1&_size=1',
    );
    final request = await client.getUrl(uri).timeout(const Duration(seconds: 15));
    request.headers.set('Cookie', cookie);
    request.headers.set('User-Agent', _desktopUserAgent);
    request.headers.set('Accept', 'application/json');
    final response = await request.close().timeout(const Duration(seconds: 15));
    final body = await utf8.decodeStream(response).timeout(
      const Duration(seconds: 15),
    );
    final data = jsonDecode(body);
    return data is Map && data['status'] == 200 && data['code'] == 0;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>?> showQuarkLogin(BuildContext context) async {
  Map<String, dynamic>? authorization;
  Timer? timer;
  var finished = false;
  var checking = false;
  String? failure;

  Future<void> checkLogin(
    Future<Map<String, String>> Function([String? url]) getCookies,
    VoidCallback close,
  ) async {
    if (finished || checking) return;
    checking = true;
    try {
      final cookies = await getCookies();
      if (finished || (cookies['__pus'] ?? '').isEmpty) return;
      // Read cookies from the .quark.cn parent domain, not just the API host:
      // __pus/__puus are often scoped to pan.quark.cn and invisible when
      // queried against drive.quark.cn.
      var current = cookies;
      try {
        final broad = await getCookies('https://quark.cn/');
        if (broad.isNotEmpty) current = {...broad, ...cookies};
      } catch (_) {}
      final verified = await _verifyQuarkSession(current);
      if (finished || !verified) return;
      authorization = {
        'cookie': current.entries
            .map((entry) => '${entry.key}=${entry.value}')
            .join('; '),
      };
      finished = true;
      close();
    } catch (_) {
      if (!finished) {
        failure = 'Unable to read login cookies';
        finished = true;
        close();
      }
    } finally {
      checking = false;
    }
  }

  try {
    if (App.isLinux) {
      if (!await DesktopWebview.isAvailable()) {
        throw const FormatException('Webview is not available');
      }
      if (!context.mounted) return null;
      final closed = Completer<void>();
      final webview = DesktopWebview(
        initialUrl: _loginUrl,
        onTitleChange: (_, webview) => checkLogin(
          ([url]) => webview.getCookies(url ?? _apiUrl),
          webview.close,
        ),
        onClose: () => closed.complete(),
      );
      // ManComi 的 DesktopWebview.open() 返回 void，窗口创建在内部异步进行。
      webview.open();
      await closed.future;
    } else {
      await context.to<void>(() {
        void check(InAppWebViewController controller) => checkLogin(
          ([url]) async => {
            for (final cookie
                in await controller.getCookies(url ?? _apiUrl) ?? [])
              cookie.name: cookie.value,
          },
          () => context.pop(),
        );
        return AppWebview(
          initialUrl: _loginUrl,
          userAgent: _desktopUserAgent,
          onStarted: (controller) {
            timer = Timer.periodic(
              const Duration(seconds: 2),
              (_) => check(controller),
            );
          },
          onLoadStop: check,
        );
      });
    }
  } finally {
    finished = true;
    timer?.cancel();
  }
  if (failure != null) throw FormatException(failure!);
  return authorization;
}
