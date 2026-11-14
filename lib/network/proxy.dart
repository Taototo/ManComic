import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/ext.dart';

String? _cachedProxy;

DateTime? _cachedProxyTime;

/// 进程内的代理覆盖（内置代理隧道用）。
///
/// 刻意**只放内存、不落盘**：隧道跑在本进程里，进程一死端口就没了。要是把
/// `127.0.0.1:<端口>` 写进设置，下次冷启动就指着一个没人监听的端口，整个 app
/// 会表现为「完全连不上网」，还得专门写迁移把它清掉。放内存里则是进程死、
/// 覆盖自动消失，正好对上「关掉软件代理就没了」这条需求。
String? _runtimeProxy;

void setRuntimeProxy(String? proxy) {
  _runtimeProxy = proxy;
  // 立刻失效缓存，不然最多一秒内的请求还走旧值。
  _cachedProxyTime = null;
}

/// 给代理串补上 scheme。
///
/// 设置里存的一直是裸 `host:port`（Dart 的 `findProxy` 就吃这个格式），但
/// reqwest/rhttp 要 `http://host:port` 这种完整 URL，`socks5://` 也要显式写。
String withProxyScheme(String proxy) {
  return proxy.contains('://') ? proxy : 'http://$proxy';
}

/// 去掉 scheme，得到 Dart `HttpClient.findProxy` 认识的 `host:port`。
String withoutProxyScheme(String proxy) {
  final index = proxy.indexOf('://');
  return index < 0 ? proxy : proxy.substring(index + 3);
}

Future<String?> getProxy() async {
  if (_cachedProxyTime != null &&
      DateTime.now().difference(_cachedProxyTime!).inSeconds < 1) {
    return _cachedProxy;
  }
  String? proxy = await _getProxy();
  _cachedProxy = proxy;
  _cachedProxyTime = DateTime.now();
  return proxy;
}

Future<String?> _getProxy() async {
  if (_runtimeProxy != null) {
    return _runtimeProxy;
  }
  if ((appdata.settings['proxy'] as String).removeAllBlank == "direct") {
    return null;
  }
  if (appdata.settings['proxy'] != "system") return appdata.settings['proxy'];

  String res;
  if (!App.isLinux) {
    const channel = MethodChannel("venera/method_channel");
    try {
      res = await channel.invokeMethod("getProxy");
    } catch (e) {
      return null;
    }
  } else {
    res = "No Proxy";
  }
  if (res == "No Proxy") return null;

  if (res.contains(";")) {
    var proxies = res.split(";");
    for (String proxy in proxies) {
      proxy = proxy.removeAllBlank;
      if (proxy.startsWith('https=')) {
        return proxy.substring(6);
      }
    }
  }

  final RegExp regex = RegExp(
    r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}:\d+$',
    caseSensitive: false,
    multiLine: false,
  );
  if (!regex.hasMatch(res)) {
    return null;
  }

  return res;
}
