import 'dart:convert';

import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/xray_core.dart';

/// 一个可用的出口节点。
class VpnNode {
  VpnNode({required this.name, required this.outbound});

  /// 节点名（订阅里 `#备注` 或 vmess 的 `ps`），也是 Xray 的 outbound tag。
  final String name;

  /// 转好的 Xray outbound。
  final Map<String, dynamic> outbound;

  Map<String, dynamic> toJson() => {'name': name, 'outbound': outbound};

  static VpnNode fromJson(Map<String, dynamic> json) => VpnNode(
    name: (json['name'] ?? '').toString(),
    outbound: Map<String, dynamic>.from(json['outbound'] as Map),
  );
}

/// 一份订阅：链接 + 上次拉取时间 + 节点。
class VpnSubscription {
  VpnSubscription({
    required this.url,
    required this.updatedAt,
    required this.nodes,
  });

  final String url;

  final int updatedAt;

  final List<VpnNode> nodes;

  Map<String, dynamic> toJson() => {
    'url': url,
    'updatedAt': updatedAt,
    'nodes': [for (final n in nodes) n.toJson()],
  };

  static VpnSubscription fromJson(Map<String, dynamic> json) => VpnSubscription(
    url: (json['url'] ?? '').toString(),
    updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
    nodes: [
      for (final e in (json['nodes'] as List? ?? const []))
        if (e is Map) VpnNode.fromJson(Map<String, dynamic>.from(e)),
    ],
  );
}

/// 订阅的拉取、解析与落盘。
///
/// 存在 `implicitData` 而不是 `settings`：订阅链接本身是一串凭据，WebDAV 同步
/// 的是 `settings`，不该把它顺手传到别人的网盘上。换设备重新粘一次就行。
class SubscriptionService {
  SubscriptionService._();

  static const String _key = 'xraySubscription';

  static VpnSubscription? load() {
    final raw = appdata.implicitData[_key];
    if (raw is! String || raw.isEmpty) {
      return null;
    }
    try {
      return VpnSubscription.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (e) {
      return null;
    }
  }

  static Future<void> save(VpnSubscription subscription) async {
    appdata.implicitData[_key] = jsonEncode(subscription.toJson());
    await appdata.writeImplicitData();
  }

  /// 用户手动划掉的节点名。
  ///
  /// 存名字而不是从订阅里删：订阅一刷新节点列表就整份换新，真删了下次又回来，
  /// 用户会以为删除没生效。放 implicitData 是因为这是本机的口味，不该跟着
  /// 设置同步到另一台设备（那边可能是另一份订阅）。
  static const String _hiddenKey = 'xrayHiddenNodes';

  static Set<String> hiddenNodes() {
    final raw = appdata.implicitData[_hiddenKey];
    if (raw is List) {
      return {
        for (final e in raw)
          if (e is String) e,
      };
    }
    return {};
  }

  static Future<void> hideNode(String name) async {
    final hidden = hiddenNodes()..add(name);
    appdata.implicitData[_hiddenKey] = hidden.toList();
    await appdata.writeImplicitData();
  }

  static Future<void> restoreHiddenNodes() async {
    appdata.implicitData.remove(_hiddenKey);
    await appdata.writeImplicitData();
  }

  /// 拉取并解析。失败抛异常，由调用方显示原因。
  static Future<VpnSubscription> refresh(String url) async {
    final text = await _fetch(url);
    final plain = plainSubscriptionText(await _decrypt(text));
    final links = splitShareLinks(plain);
    if (links.isEmpty) {
      // 只记形态，不记内容：每条链接都带 UUID 和服务器地址。
      Log.error('Xray', '订阅解析不出节点（${describe(plain)}）');
      throw XrayException('订阅里没有节点');
    }
    // 核心能吃的那部分直接交给它（vmess-aead / vless / ss / trojan / hysteria2），
    // 老式 `vmess://base64` 它明确不支持，Dart 侧自己补。
    final supported = <String>[];
    final legacy = <Map<String, dynamic>>[];
    for (final link in links) {
      if (link.toLowerCase().startsWith('vmess://')) {
        final outbound = legacyVmessToOutbound(link);
        if (outbound != null) {
          legacy.add(outbound);
          continue;
        }
      }
      supported.add(link);
    }

    final nodes = <VpnNode>[];
    if (supported.isNotEmpty) {
      try {
        final outbounds = await XrayCore.convertLinks(supported.join('\n'));
        for (final outbound in outbounds) {
          nodes.add(
            VpnNode(
              name: (outbound['tag'] ?? '').toString().trim(),
              outbound: outbound,
            ),
          );
        }
      } on XrayException catch (e) {
        // 核心整批失败（一条都转不出来）时别把异常原样抛给用户：
        // "no valid outbound found" 看不出是协议不支持还是链接坏了。
        Log.error('Xray', '分享链接转换失败（${supported.length} 条）: ${e.message}');
        if (legacy.isEmpty) {
          throw XrayException('订阅里的节点都无法解析');
        }
      }
    }
    for (final outbound in legacy) {
      nodes.add(
        VpnNode(
          name: (outbound['tag'] ?? '').toString().trim(),
          outbound: outbound,
        ),
      );
    }
    if (nodes.isEmpty) {
      throw XrayException('${links.length} 条链接都无法解析');
    }
    // 名字为空或不唯一时补个序号：Xray 的 outbound tag 必须唯一。
    final seen = <String>{};
    for (var i = 0; i < nodes.length; i++) {
      var name = nodes[i].name;
      if (name.isEmpty) {
        name = 'Node ${i + 1}';
      }
      var unique = name;
      var suffix = 2;
      while (!seen.add(unique)) {
        unique = '$name ($suffix)';
        suffix++;
      }
      nodes[i] = VpnNode(
        name: unique,
        outbound: {...nodes[i].outbound, 'tag': unique},
      );
    }

    // 机场爱把「剩余流量：798.52 GB」「套餐到期：长期有效」做成节点塞在最前面，
    // 复用一台真实机器。它们能连，但选中时界面只显示一串账单信息，看不出是哪个
    // 地区。挪到列表末尾：默认选中项（nodes.first）就落在一个真节点上。
    final ordered = [
      ...nodes.where((n) => !isInfoNode(n.name)),
      ...nodes.where((n) => isInfoNode(n.name)),
    ];

    return VpnSubscription(
      url: url,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      nodes: ordered,
    );
  }

  /// 这个名字像不像「用节点名传话」的信息条（流量余额、到期时间等）。
  static bool isInfoNode(String name) {
    final flat = name.replaceAll(RegExp(r'[\s\u3000]+'), '');
    if (flat.isEmpty) {
      return false;
    }
    const prefixes = ['剩余流量', '套餐到期', '到期时间', '套餐', '官网', '订阅', '有效期'];
    return prefixes.any(flat.startsWith);
  }

  static Future<String> _fetch(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme) {
      throw XrayException('订阅链接不完整');
    }
    final res =
        await AppDio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 20),
            receiveTimeout: const Duration(seconds: 40),
            responseType: ResponseType.plain,
            validateStatus: (s) => s != null && s < 400,
            headers: {
              // 不少机场按 UA 分发格式，认不出来就不给节点列表。
              'User-Agent': 'v2rayNG/1.9.16',
            },
          ),
        ).get<String>(
          uri.toString(),
          // 订阅链接本身就是凭据（token 在 query 里），响应体整篇是节点凭据。
          // 不标记的话两者都会原样进日志文件，用户一导日志就是明文泄露。
          options: Options(extra: {'redactLog': true}),
        );
    final body = res.data;
    if (body == null || body.trim().isEmpty) {
      throw XrayException('订阅内容为空');
    }
    return body;
  }

  /// age 加密的订阅交给核心解；非加密文本它会原样返回。
  ///
  /// 明文直接跳过这一步：每次都要过一次 MethodChannel + Go，没必要。
  static Future<String> _decrypt(String raw) async {
    final text = raw.trim();
    if (text.contains('://')) {
      return text;
    }
    try {
      final decoded = await XrayCore.decodeSubscription(text);
      if (decoded.trim().isNotEmpty) {
        return decoded;
      }
    } catch (e) {
      // 核心不认识就交给本地的 base64 兜底，不要因为这一步把订阅整个否掉。
      Log.error('Xray', '订阅解密失败: $e');
    }
    return text;
  }

  /// 把订阅原文变成「一行一条分享链接」的明文。
  ///
  /// **核心不解 base64**：`decodeSubscriptionText` 只处理 age 加密
  /// （`share/decode_subscription.go` 里就一次 `decryptShareText`），而绝大多数
  /// 机场发的正是 base64。之前拿核心的返回值直接按行找 `vless://`，明文其实还
  /// 是那串 base64，于是一条都找不到，界面报「订阅里没有节点」——同一个链接在
  /// v2rayNG 里明明好好的。
  static String plainSubscriptionText(String raw) {
    final text = raw.trim();
    if (text.isEmpty || text.contains('://')) {
      return text;
    }
    return _tryBase64(text) ?? text;
  }

  /// 整段 base64 → 明文。只认「解出来确实含 `://`」的结果，别把乱码当成功。
  static String? _tryBase64(String text) {
    final packed = text.replaceAll(RegExp(r'\s'), '');
    if (packed.length < 16) {
      return null;
    }
    try {
      // allowMalformed 默认 false：html 错误页解出来的乱码会被拒掉。
      final plain = utf8.decode(base64Decode(base64Normalize(packed)));
      return plain.contains('://') ? plain : null;
    } catch (_) {
      return null;
    }
  }

  /// 日志用：只说「收到了什么东西」，不说内容。
  ///
  /// 订阅正文里每条链接都是 `vless://<uuid>@<服务器>:<端口>`，一旦原样写进日志
  /// 文件，用户导出日志求助时就把整个账号送出去了。所以这里只给长度和形态，
  /// 足够判断"是 html 错误页 / 是 base64 没解开 / 是格式不认识"。
  static String describe(String text) {
    final flat = text.trim();
    if (flat.isEmpty) {
      return '空响应';
    }
    final tags = <String>['${flat.length} 字符'];
    if (flat.startsWith('<')) {
      tags.add('像 html');
    }
    if (flat.contains('://')) {
      tags.add('含链接但一行都认不出');
    } else if (_tryBase64(flat) != null) {
      tags.add('是 base64，但内容不是链接');
    } else {
      tags.add('既不是链接也不是 base64');
    }
    return tags.join('，');
  }

  /// 把订阅明文拆成一条条分享链接。
  static List<String> splitShareLinks(String text) {
    return [
      for (final line in text.split(RegExp(r'[\r\n]+')))
        if (_looksLikeLink(line.trim())) line.trim(),
    ];
  }

  static bool _looksLikeLink(String line) {
    if (line.isEmpty || line.startsWith('#')) {
      return false;
    }
    final lower = line.toLowerCase();
    return lower.startsWith('vmess://') ||
        lower.startsWith('vless://') ||
        lower.startsWith('ss://') ||
        lower.startsWith('trojan://') ||
        lower.startsWith('hysteria2://') ||
        lower.startsWith('hy2://') ||
        lower.startsWith('socks://');
  }

  /// 老式 `vmess://<base64(JSON)>` → Xray outbound。
  ///
  /// 新核心不认这种格式（只认 VMessAEAD 的 URI），但大量机场还在发它，
  /// 所以自己转一份。字段名见 v2rayN 的老格式。
  static Map<String, dynamic>? legacyVmessToOutbound(String link) {
    try {
      final payload = link.substring('vmess://'.length).trim();
      final json = jsonDecode(
        utf8.decode(base64Decode(base64Normalize(payload))),
      );
      if (json is! Map) {
        return null;
      }
      final address = (json['add'] ?? '').toString();
      final id = (json['id'] ?? '').toString();
      if (address.isEmpty || id.isEmpty) {
        return null;
      }
      final port = int.tryParse('${json['port']}') ?? 0;
      if (port <= 0) {
        return null;
      }
      final network = ((json['net'] ?? 'tcp').toString()).toLowerCase();
      final tls = ((json['tls'] ?? '').toString()).toLowerCase();
      final host = (json['host'] ?? '').toString();
      final path = (json['path'] ?? '').toString();
      final sni = (json['sni'] ?? '').toString();
      final alterId = int.tryParse('${json['aid']}') ?? 0;
      final security = (json['scy'] ?? 'auto').toString();

      final stream = <String, dynamic>{
        'network': network.isEmpty ? 'tcp' : network,
      };
      if (tls == 'tls' || tls == 'xtls') {
        stream['security'] = 'tls';
        stream['tlsSettings'] = {
          'serverName': sni.isNotEmpty ? sni : host,
          'allowInsecure': false,
        };
      } else {
        stream['security'] = 'none';
      }
      switch (network) {
        case 'ws':
          stream['wsSettings'] = {
            'path': path.isEmpty ? '/' : path,
            if (host.isNotEmpty) 'headers': {'Host': host},
          };
        case 'grpc':
          stream['grpcSettings'] = {'serviceName': path.isEmpty ? '' : path};
        case 'h2':
        case 'http':
          stream['network'] = 'h2';
          stream['httpSettings'] = {
            'path': path.isEmpty ? '/' : path,
            if (host.isNotEmpty) 'host': [host],
          };
        case 'tcp':
          if (host.isNotEmpty) {
            stream['tcpSettings'] = {
              'header': {
                'type': 'http',
                'request': {
                  'headers': {
                    'Host': [host],
                  },
                },
              },
            };
          }
      }

      return {
        'tag': (json['ps'] ?? '').toString(),
        'protocol': 'vmess',
        'settings': {
          'vnext': [
            {
              'address': address,
              'port': port,
              'users': [
                {
                  'id': id,
                  'alterId': alterId,
                  'security': security.isEmpty ? 'auto' : security,
                },
              ],
            },
          ],
        },
        'streamSettings': stream,
      };
    } catch (e) {
      Log.error('Xray', 'vmess 解析失败: $e');
      return null;
    }
  }
}

/// base64 在订阅里经常是 url-safe、且缺 padding。
String base64Normalize(String input) {
  var text = input
      .replaceAll('-', '+')
      .replaceAll('_', '/')
      .replaceAll('\n', '');
  text = text.replaceAll(RegExp(r'\s'), '');
  final mod = text.length % 4;
  if (mod == 2) {
    text += '==';
  } else if (mod == 3) {
    text += '=';
  } else if (mod == 1) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}
