import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:http_parser/http_parser.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/cache.dart';
import 'package:venera/network/proxy.dart';
import 'package:venera/network/reusable_client.dart';

import '../foundation/app.dart';
import 'cloudflare.dart';
import 'cookie_jar.dart';

export 'package:dio/dio.dart';

/// 自定义Transformer，用于处理格式不正确的Content-Type头部
class SafeTransformer extends Transformer {
  @override
  Future<String> transformRequest(RequestOptions options) async {
    var data = options.data;
    if (data != null) {
      if (data is Map || data is List) {
        return jsonEncode(data);
      } else {
        return data.toString();
      }
    }
    return '';
  }

  @override
  Future transformResponse(
    RequestOptions options,
    ResponseBody responseBody,
  ) async {
    // 对于stream和bytes类型的请求，不进行转换，直接使用默认的Transformer
    if (options.responseType == ResponseType.stream ||
        options.responseType == ResponseType.bytes) {
      // 使用Dio的背景Transformer处理
      return BackgroundTransformer().transformResponse(options, responseBody);
    }

    // 获取响应数据，添加大小限制防止内存溢出
    var bytes = <int>[];
    const maxResponseSize = 50 * 1024 * 1024; // 50MB限制
    int totalBytes = 0;

    await for (var chunk in responseBody.stream) {
      totalBytes += chunk.length;

      // 检查是否超过大小限制
      if (totalBytes > maxResponseSize) {
        Log.warning(
          "Network",
          "Response size exceeded limit (${totalBytes} bytes > ${maxResponseSize} bytes), truncating response",
        );
        break;
      }

      bytes.addAll(chunk);
    }
    var responseData = Uint8List.fromList(bytes);

    // 如果没有数据，直接返回
    if (responseData.isEmpty) {
      return null;
    }

    // 对于plain类型的请求（JavaScript引擎），直接返回字符串
    if (options.responseType == ResponseType.plain) {
      try {
        return utf8.decode(responseData, allowMalformed: true);
      } catch (e) {
        Log.warning("Network", "Failed to decode response as UTF-8: $e");
        return responseData;
      }
    }

    // 检查Content-Type头部
    var contentType = responseBody.headers['content-type']?.first;

    // 如果Content-Type存在但格式不正确，尝试修复
    if (contentType != null) {
      // 移除末尾多余的分号和空格
      contentType = contentType.trim();
      if (contentType.endsWith(';')) {
        contentType = contentType.substring(0, contentType.length - 1).trim();
      }

      try {
        // 尝试解析修复后的Content-Type
        var mediaType = MediaType.parse(contentType);

        // 根据媒体类型处理响应数据
        if (mediaType.mimeType == 'application/json' ||
            mediaType.mimeType == 'text/json') {
          try {
            var jsonString = utf8.decode(responseData, allowMalformed: true);
            return jsonDecode(jsonString);
          } catch (e) {
            Log.warning("Network", "Failed to decode JSON response: $e");
            return utf8.decode(responseData, allowMalformed: true);
          }
        } else if (mediaType.type == 'text') {
          return utf8.decode(responseData, allowMalformed: true);
        }
      } catch (e) {
        Log.warning(
          "Network",
          "Failed to parse Content-Type '$contentType': $e",
        );
        // 如果Content-Type解析失败，尝试根据数据内容推断类型
        try {
          var textData = utf8.decode(responseData, allowMalformed: true);
          // 对于非plain类型的请求，尝试解析为JSON
          if (textData.trim().startsWith('{') ||
              textData.trim().startsWith('[')) {
            return jsonDecode(textData);
          }
          return textData;
        } catch (e2) {
          Log.warning("Network", "Failed to decode response as text: $e2");
          return responseData;
        }
      }
    }

    // 如果没有Content-Type头部，尝试根据数据内容推断
    try {
      var textData = utf8.decode(responseData, allowMalformed: true);
      // 对于非plain类型的请求，尝试解析为JSON
      if (textData.trim().startsWith('{') || textData.trim().startsWith('[')) {
        return jsonDecode(textData);
      }
      return textData;
    } catch (e) {
      // 如果无法解码为文本，返回原始字节数据
      return responseData;
    }
  }
}

class MyLogInterceptor implements Interceptor {
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.requestOptions.extra["redactLog"] == true) {
      // `$err` 里带整个 RequestOptions，会顺着 uri 把 token 打出来。
      Log.error(
        "Network",
        "${err.requestOptions.method} "
            "${_redactUri(err.requestOptions.uri)}\n"
            "${err.type}: ${err.message}",
      );
    } else {
      Log.error(
        "Network",
        "${err.requestOptions.method} ${err.requestOptions.path}\n$err\n${err.response?.data.toString()}",
      );
    }
    switch (err.type) {
      case DioExceptionType.badResponse:
        var statusCode = err.response?.statusCode;
        if (statusCode != null) {
          err = err.copyWith(
            message:
                "Invalid Status Code: $statusCode. "
                "${_getStatusCodeInfo(statusCode)}",
          );
        }
      case DioExceptionType.connectionTimeout:
        err = err.copyWith(message: "Connection Timeout");
      case DioExceptionType.receiveTimeout:
        err = err.copyWith(
          message:
              "Receive Timeout: "
              "This indicates that the server is too busy to respond",
        );
      case DioExceptionType.unknown:
        if (err.toString().contains("Connection terminated during handshake")) {
          err = err.copyWith(
            message:
                "Connection terminated during handshake: "
                "This may be caused by the firewall blocking the connection "
                "or your requests are too frequent.",
          );
        } else if (err.toString().contains("Connection reset by peer")) {
          err = err.copyWith(
            message:
                "Connection reset by peer: "
                "The error is unrelated to app, please check your network.",
          );
        }
      default:
        {}
    }
    handler.next(err);
  }

  static const errorMessages = <int, String>{
    400: "The Request is invalid.",
    401: "The Request is unauthorized.",
    403: "No permission to access the resource. Check your account or network.",
    404: "Not found.",
    429: "Too many requests. Please try again later.",
  };

  String _getStatusCodeInfo(int? statusCode) {
    if (statusCode != null && statusCode >= 500) {
      return "This is server-side error, please try again later. "
          "Do not report this issue.";
    } else {
      return errorMessages[statusCode] ?? "";
    }
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    var headers = response.headers.map.map(
      (key, value) => MapEntry(
        key.toLowerCase(),
        value.length == 1 ? value.first : value.toString(),
      ),
    );
    headers.remove("cookie");
    String content;
    if (response.data is List<int>) {
      try {
        content = utf8.decode(response.data, allowMalformed: false);
      } catch (e) {
        content = "<Bytes>\nlength:${response.data.length}";
      }
    } else {
      content = response.data.toString();
    }
    // 订阅的响应体整篇都是节点凭据（UUID、服务器地址、密码），只记长度。
    if (response.requestOptions.extra["redactLog"] == true) {
      Log.addLog(
        (response.statusCode != null && response.statusCode! < 400)
            ? LogLevel.info
            : LogLevel.error,
        "Network",
        "Response ${_redactUri(response.requestOptions.uri)} "
            "${response.statusCode}\n<${content.length} chars redacted>",
      );
      handler.next(response);
      return;
    }
    Log.addLog(
      (response.statusCode != null && response.statusCode! < 400)
          ? LogLevel.info
          : LogLevel.error,
      "Network",
      "Response ${response.realUri.toString()} ${response.statusCode}\n"
          "headers:\n$headers\n$content",
    );
    handler.next(response);
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    const String headerMask = "********";
    const String dataMask = "****** DATA_PROTECTED ******";
    // 有些 URL 本身就是凭据（订阅链接带 token），连 query 都不能进日志。
    // 调用点传 extra['redactLog'] = true 就只剩 `scheme://host`。
    final redact = options.extra["redactLog"] == true;
    Log.info(
      "Network",
      "${options.method} ${redact ? _redactUri(options.uri) : options.uri}\n"
          "headers:\n${redact
              ? headerMask
              : options.extra.containsKey("maskHeadersInLog")
              ? options.headers.map((key, value) => MapEntry(key, options.extra["maskHeadersInLog"].contains(key) ? headerMask : value))
              : options.headers}\n"
          "data:\n${redact || options.extra["maskDataInLog"] == true ? dataMask : options.data}",
    );
    options.connectTimeout = const Duration(seconds: 15);
    options.receiveTimeout = const Duration(seconds: 15);
    options.sendTimeout = const Duration(seconds: 15);
    handler.next(options);
  }

  /// 只留 `scheme://host`，path 和 query 全抹掉。
  ///
  /// 排查时知道"打在哪个站"通常够了，而订阅链接的 token 就在拿不到的那部分里。
  static String _redactUri(Uri uri) {
    if (uri.host.isEmpty) {
      return "<redacted>";
    }
    return "${uri.scheme}://${uri.host}/<redacted>";
  }
}

class AppDio with DioMixin {
  AppDio([BaseOptions? options]) {
    this.options = options ?? BaseOptions();
    httpClientAdapter = RHttpAdapter();
    // 使用自定义的SafeTransformer来处理格式不正确的Content-Type
    transformer = SafeTransformer();
    if (App.isInitialized) {
      interceptors.add(CookieManagerSql(SingleInstanceCookieJar.instance!));
      interceptors.add(NetworkCacheManager());
      interceptors.add(CloudflareInterceptor());
      interceptors.add(MyLogInterceptor());
    }
  }

  static final Map<String, bool> _requests = {};

  @override
  Future<Response<T>> request<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    Options? options,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) async {
    if (options?.headers?['prevent-parallel'] == 'true') {
      while (_requests.containsKey(path)) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
      _requests[path] = true;
      options!.headers!.remove('prevent-parallel');
    }
    try {
      return await super.request<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        cancelToken: cancelToken,
        options: options,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
      );
    } finally {
      if (_requests.containsKey(path)) {
        _requests.remove(path);
      }
    }
  }
}

class RHttpAdapter implements HttpClientAdapter {
  /// 复用的 rhttp client。
  ///
  /// rhttp 的 `Rhttp.request(settings: ...)` 每调一次都会在 Rust 侧走
  /// `RequestClient::new(settings)`，也就是新建一个 `reqwest::Client`。连接池
  /// 和 TLS 会话缓存都挂在 client 上，所以那样写等于**每张图都重新做一次
  /// TCP + TLS 握手**：一本 200 页的漫画就是 200 次握手，全部来自同一个出口
  /// IP、同一个 TLS 指纹，CDN 的 WAF 会把它当异常流量，在握手阶段直接断连
  /// （`tls handshake eof` / `RhttpConnectionException`）。复用同一个 client
  /// 之后，同一个域名的几十页走同一条长连接，握手次数从「每页一次」降到
  /// 「每个域名几次」。rhttp 自己的文档也写了：创建 client 很贵，应当复用。
  static final _clients = ReusableClient<rhttp.RhttpClient>();

  /// 当前配置 + 用来判断「配置有没有变」的指纹。
  static Future<(rhttp.ClientSettings, String)> _buildSettings() async {
    var proxy = await getProxy();
    var overrides = _getOverrides();
    var sni = appdata.settings['sni'] != false;
    var verify = appdata.settings['ignoreBadCertificate'] != true;
    var key = rhttpSettingsKey(
      proxy: proxy,
      sni: sni,
      verifyCertificates: verify,
      dnsOverrides: overrides,
    );
    var settings = rhttp.ClientSettings(
      // reqwest 的 Proxy 要一个带 scheme 的 URL。设置页历来只存 `host:port`
      // （Dart 那套 `PROXY host:port` 就是这么写的），直接丢给 rhttp 会当成
      // 非法 URL——代理于是从来没生效过。这里补默认的 http://。
      proxySettings: proxy == null
          ? const rhttp.ProxySettings.noProxy()
          : rhttp.ProxySettings.proxy(withProxyScheme(proxy)),
      redirectSettings: const rhttp.RedirectSettings.limited(5),
      timeoutSettings: const rhttp.TimeoutSettings(
        connectTimeout: Duration(seconds: 15),
        keepAliveTimeout: Duration(seconds: 60),
        keepAlivePing: Duration(seconds: 30),
      ),
      throwOnStatusCode: false,
      dnsSettings: rhttp.DnsSettings.static(overrides: overrides),
      tlsSettings: rhttp.TlsSettings(sni: sni, verifyCertificates: verify),
    );
    return (settings, key);
  }

  static Map<String, List<String>> _getOverrides() {
    if (!appdata.settings['enableDnsOverrides'] == true) {
      return {};
    }
    var config = appdata.settings["dnsOverrides"];
    var result = <String, List<String>>{};
    if (config is Map) {
      for (var entry in config.entries) {
        if (entry.key is String && entry.value is String) {
          result[entry.key] = [entry.value];
        }
      }
    }
    return result;
  }

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.headers['User-Agent'] == null &&
        options.headers['user-agent'] == null) {
      options.headers['User-Agent'] = "venera/v${App.version}";
    }

    var (settings, key) = await _buildSettings();
    var client = await _clients.acquire(
      key,
      () => rhttp.RhttpClient.create(settings: settings),
    );

    var res = await client.request(
      method: rhttp.HttpMethod(options.method),
      url: options.uri.toString(),
      expectBody: rhttp.HttpExpectBody.stream,
      body: requestStream == null ? null : rhttp.HttpBody.stream(requestStream),
      headers: rhttp.HttpHeaders.rawMap(
        Map.fromEntries(
          options.headers.entries.map(
            (e) => MapEntry(e.key, e.value.toString().trim()),
          ),
        ),
      ),
    );
    if (res is! rhttp.HttpStreamResponse) {
      throw Exception("Invalid response type: ${res.runtimeType}");
    }
    var headers = <String, List<String>>{};
    for (var entry in res.headers) {
      var key = entry.$1.toLowerCase();
      headers[key] ??= [];
      headers[key]!.add(entry.$2);
    }
    return ResponseBody(
      res.body,
      res.statusCode,
      statusMessage: _getStatusMessage(res.statusCode),
      isRedirect: false,
      headers: headers,
    );
  }

  static String _getStatusMessage(int statusCode) {
    return switch (statusCode) {
      200 => "OK",
      201 => "Created",
      202 => "Accepted",
      204 => "No Content",
      206 => "Partial Content",
      301 => "Moved Permanently",
      302 => "Found",
      400 => "Invalid Status Code 400: The Request is invalid.",
      401 => "Invalid Status Code 401: The Request is unauthorized.",
      403 =>
        "Invalid Status Code 403: No permission to access the resource. Check your account or network.",
      404 => "Invalid Status Code 404: Not found.",
      429 =>
        "Invalid Status Code 429: Too many requests. Please try again later.",
      _ => "Invalid Status Code $statusCode",
    };
  }
}
