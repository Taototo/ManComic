import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/subscription.dart';
import 'package:venera/network/proxy.dart';
import 'package:venera/network/xray_tunnel.dart';

/// 内置代理的两块纯逻辑：订阅解析（尤其老式 vmess://）和配置拼装。
///
/// 这两处错了的表现都是「连不上」，从 UI 上完全看不出是哪一环，所以必须用单测
/// 钉住：vmess 的字段映射、url-safe base64、以及入站必须是 http。

String _vmessLink(Map<String, dynamic> json) {
  final text = utf8.encode(jsonEncode(json));
  final b64 = base64Encode(
    text,
  ).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
  return 'vmess://$b64';
}

void main() {
  group('分享链接拆分', () {
    test('只认协议行，注释和空行跳过', () {
      final links = SubscriptionService.splitShareLinks('''
# 这是一行注释
vless://abc@host:443?type=ws#节点一

trojan://pass@host:443#节点二
随便一行废话
''');
      expect(links, [
        'vless://abc@host:443?type=ws#节点一',
        'trojan://pass@host:443#节点二',
      ]);
    });
  });

  group('老式 vmess:// 转 outbound', () {
    test('ws + tls 的基本字段', () {
      final outbound = SubscriptionService.legacyVmessToOutbound(
        _vmessLink({
          'v': '2',
          'ps': '香港 01',
          'add': 'example.com',
          'port': '443',
          'id': '11111111-2222-3333-4444-555555555555',
          'aid': '0',
          'scy': 'auto',
          'net': 'ws',
          'host': 'cdn.example.com',
          'path': '/ray',
          'tls': 'tls',
          'sni': 'sni.example.com',
        }),
      );
      expect(outbound, isNotNull);
      expect(outbound!['tag'], '香港 01');
      expect(outbound['protocol'], 'vmess');

      final vnext = outbound['settings']['vnext'][0];
      expect(vnext['address'], 'example.com');
      expect(vnext['port'], 443);
      expect(vnext['users'][0]['id'], '11111111-2222-3333-4444-555555555555');
      expect(vnext['users'][0]['security'], 'auto');

      final stream = outbound['streamSettings'];
      expect(stream['network'], 'ws');
      expect(stream['security'], 'tls');
      expect(stream['wsSettings']['path'], '/ray');
      expect(stream['wsSettings']['headers']['Host'], 'cdn.example.com');
      expect(stream['tlsSettings']['serverName'], 'sni.example.com');
    });

    test('url-safe base64、缺 padding 也要解出来', () {
      // 故意选一个 base64 里会出现 + / 的 id，再把它们换成 - _ 并去掉 =
      final link = _vmessLink({
        'ps': 'X',
        'add': 'a.example.com',
        'port': 8080,
        'id': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        'aid': 0,
        'net': 'tcp',
        'tls': '',
      });
      expect(link.contains('='), isFalse);
      final outbound = SubscriptionService.legacyVmessToOutbound(link);
      expect(outbound, isNotNull);
      expect(outbound!['settings']['vnext'][0]['port'], 8080);
      expect(outbound['streamSettings']['security'], 'none');
    });

    test('缺地址或 uuid 的残链返回 null，不能抛', () {
      expect(
        SubscriptionService.legacyVmessToOutbound(
          _vmessLink({'ps': 'x', 'add': '', 'port': 443, 'id': 'abc'}),
        ),
        isNull,
      );
      expect(
        SubscriptionService.legacyVmessToOutbound('vmess://notbase64!!!'),
        isNull,
      );
    });
  });

  group('Xray 配置', () {
    test('入站必须是 http、只监听 127.0.0.1，出口就是选中的节点', () {
      final config =
          jsonDecode(
                XrayTunnel.buildConfig(
                  port: 23456,
                  outbound: {'tag': '节点一', 'protocol': 'vmess'},
                ),
              )
              as Map<String, dynamic>;

      final inbound = config['inbounds'][0];
      expect(
        inbound['protocol'],
        'http',
        reason: 'Dart 自带的 HttpClient 不认 SOCKS，入站给 http 两边都能用',
      );
      expect(inbound['listen'], '127.0.0.1', reason: '只能监听回环，不能让局域网连进来');
      expect(inbound['port'], 23456);
      expect(config['outbounds'], [
        {'tag': '节点一', 'protocol': 'vmess'},
      ]);
    });
  });

  group('代理串 scheme', () {
    test('裸 host:port 补成 http://，已有 scheme 不动', () {
      expect(withProxyScheme('127.0.0.1:10809'), 'http://127.0.0.1:10809');
      expect(
        withProxyScheme('socks5://127.0.0.1:10808'),
        'socks5://127.0.0.1:10808',
      );
      expect(withoutProxyScheme('http://127.0.0.1:10809'), '127.0.0.1:10809');
      expect(withoutProxyScheme('127.0.0.1:10809'), '127.0.0.1:10809');
    });
  });
}
