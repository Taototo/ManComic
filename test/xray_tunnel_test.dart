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

  group('订阅原文解码', () {
    // 真实的机场订阅就是这个形状：整段 base64，解出来才是每行一条 vless://。
    const plain =
        'vless://38f85244-d8c2-4cc3-9f42-3066712f5b01@a.example.com:443'
        '?type=tcp&security=reality&sni=updates.cdn-apple.com&pbk=70V0&sid=3191#日本节点\n'
        'vless://38f85244-d8c2-4cc3-9f42-3066712f5b01@b.example.com:443'
        '?type=ws&security=tls&sni=viphk1.example.com#香港节点';

    test('核心只解 age、不解 base64，所以这一层必须自己兜住', () {
      final packed = base64Encode(utf8.encode(plain));
      final decoded = SubscriptionService.plainSubscriptionText(packed);
      expect(decoded, plain);
      expect(SubscriptionService.splitShareLinks(decoded), hasLength(2));
    });

    test('url-safe、缺 padding、夹换行和空白也要解开', () {
      var packed = base64Encode(
        utf8.encode(plain),
      ).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
      // 订阅站常把长 base64 折行
      packed = '${packed.substring(0, 20)}\r\n${packed.substring(20)}';
      expect(SubscriptionService.plainSubscriptionText(packed), plain);
    });

    test('已经是明文就原样返回，不去动它', () {
      expect(SubscriptionService.plainSubscriptionText(plain), plain);
      expect(
        SubscriptionService.plainSubscriptionText('  $plain  '),
        plain,
        reason: '两侧空白要 trim 掉',
      );
    });

    test('html 错误页、纯广告词不会被当成 base64', () {
      const page = '<!DOCTYPE html><html><body>token 无效</body></html>';
      expect(SubscriptionService.plainSubscriptionText(page), page);
      expect(
        SubscriptionService.splitShareLinks(
          SubscriptionService.plainSubscriptionText(page),
        ),
        isEmpty,
        reason: '解不出来就该是空列表，由上层报「订阅里没有节点」',
      );
    });

    test('用节点名传话的信息条认得出来，真节点不误伤', () {
      expect(SubscriptionService.isInfoNode('剩余流量：798.52 GB'), isTrue);
      expect(SubscriptionService.isInfoNode('套餐到期：长期有效'), isTrue);
      expect(SubscriptionService.isInfoNode(' 到期时间 2027-01-01'), isTrue);
      // 真节点的名字里也可能带「套餐」以外的字样，不能一眼当成信息条
      expect(SubscriptionService.isInfoNode('🇯🇵日本•移联01'), isFalse);
      expect(SubscriptionService.isInfoNode('香港 01'), isFalse);
      expect(SubscriptionService.isInfoNode(''), isFalse);
    });

    test('日志里的"形态"不能带出节点凭据', () {
      final shapes = [
        SubscriptionService.describe('<html>token 无效</html>'),
        SubscriptionService.describe('dmxlc3M6Ly8xMjM0NTY3OA=='),
        SubscriptionService.describe(plain),
        SubscriptionService.describe(''),
      ];
      for (final shape in shapes) {
        expect(shape.contains('://'), isFalse, reason: '不能回显链接: $shape');
        expect(
          shape.toLowerCase().contains('38f85244'),
          isFalse,
          reason: '不能回显 UUID: $shape',
        );
        expect(
          shape.contains('example.com'),
          isFalse,
          reason: '不能回显服务器: $shape',
        );
      }
      expect(SubscriptionService.describe('<html>x</html>'), contains('html'));
      expect(SubscriptionService.describe(''), contains('空'));
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

  group('连接测试', () {
    test('隧道没在跑时直接给结论，不去发请求', () async {
      final probe = await XrayTunnel.probe();
      expect(probe.ok, isFalse);
      expect(probe.message, isNotNull);
      expect(probe.milliseconds, isNull, reason: '失败时不该有耗时');
    });
  });
}
