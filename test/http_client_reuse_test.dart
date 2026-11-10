import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/reusable_client.dart';

/// 假 client。rhttp 的 Rust 库在 `flutter test` 里加载不了，所以复用逻辑
/// 只测「同一个 key 只建一次」这件事——它跟 rhttp 无关。
class _FakeClient {
  final int id;

  _FakeClient(this.id);
}

void main() {
  group('ReusableClient', () {
    test('同一个 key 只创建一次，后续直接复用', () async {
      var pool = ReusableClient<_FakeClient>();
      var created = 0;

      var a = await pool.acquire('k1', () async => _FakeClient(++created));
      var b = await pool.acquire('k1', () async => _FakeClient(++created));

      expect(created, 1);
      expect(identical(a, b), isTrue);
      expect(pool.key, 'k1');
    });

    test('并发请求共用同一次创建', () async {
      var pool = ReusableClient<_FakeClient>();
      var created = 0;
      var gate = Completer<void>();

      Future<_FakeClient> acquire() => pool.acquire('k1', () async {
            created++;
            await gate.future;
            return _FakeClient(created);
          });

      // 五个请求同时进来，此时第一次创建还没完成。
      var futures = List.generate(5, (_) => acquire());
      await Future.delayed(Duration.zero);
      gate.complete();
      var clients = await Future.wait(futures);

      expect(created, 1, reason: '并发时不该各建一个，否则又变成每次重新握手');
      expect(clients.map((e) => e.id).toSet().length, 1);
    });

    test('key 变了就重建，旧实例不影响', () async {
      var pool = ReusableClient<_FakeClient>();
      var created = 0;

      var a = await pool.acquire('k1', () async => _FakeClient(++created));
      var b = await pool.acquire('k2', () async => _FakeClient(++created));

      expect(created, 2);
      expect(identical(a, b), isFalse);
      expect(pool.key, 'k2');
    });

    test('创建失败不留缓存，下次还能重试', () async {
      var pool = ReusableClient<_FakeClient>();

      await expectLater(
        pool.acquire('k1', () async => throw StateError('boom')),
        throwsStateError,
      );
      expect(pool.value, isNull);
      expect(pool.key, isNull);

      var ok = await pool.acquire('k1', () async => _FakeClient(1));
      expect(ok.id, 1);
      expect(pool.key, 'k1');
    });

    test('clear 之后下一个请求会重建', () async {
      var pool = ReusableClient<_FakeClient>();
      var created = 0;

      await pool.acquire('k1', () async => _FakeClient(++created));
      pool.clear();
      await pool.acquire('k1', () async => _FakeClient(++created));

      expect(created, 2);
    });
  });

  group('rhttpSettingsKey', () {
    test('配置相同时 key 相同', () {
      expect(
        rhttpSettingsKey(
          proxy: 'http://127.0.0.1:7890',
          sni: true,
          verifyCertificates: true,
          dnsOverrides: {
            'a.com': ['1.2.3.4'],
          },
        ),
        rhttpSettingsKey(
          proxy: 'http://127.0.0.1:7890',
          sni: true,
          verifyCertificates: true,
          dnsOverrides: {
            'a.com': ['1.2.3.4'],
          },
        ),
      );
    });

    test('DNS 覆盖的书写顺序不影响 key', () {
      var k1 = rhttpSettingsKey(
        proxy: null,
        sni: true,
        verifyCertificates: true,
        dnsOverrides: {
          'b.com': ['2.2.2.2', '1.1.1.1'],
          'a.com': ['1.2.3.4'],
        },
      );
      var k2 = rhttpSettingsKey(
        proxy: null,
        sni: true,
        verifyCertificates: true,
        dnsOverrides: {
          'a.com': ['1.2.3.4'],
          'b.com': ['1.1.1.1', '2.2.2.2'],
        },
      );
      expect(k1, k2, reason: '顺序抖一下就要重建 client、重握手一轮');
    });

    test('代理 / SNI / 证书校验变化都会让 key 变', () {
      var base = rhttpSettingsKey(
        proxy: null,
        sni: true,
        verifyCertificates: true,
        dnsOverrides: {},
      );
      var keys = {
        base,
        rhttpSettingsKey(
          proxy: 'socks5://127.0.0.1:1080',
          sni: true,
          verifyCertificates: true,
          dnsOverrides: {},
        ),
        rhttpSettingsKey(
          proxy: null,
          sni: false,
          verifyCertificates: true,
          dnsOverrides: {},
        ),
        rhttpSettingsKey(
          proxy: null,
          sni: true,
          verifyCertificates: false,
          dnsOverrides: {},
        ),
        rhttpSettingsKey(
          proxy: null,
          sni: true,
          verifyCertificates: true,
          dnsOverrides: {
            'a.com': ['1.2.3.4'],
          },
        ),
      };
      expect(keys.length, 5, reason: '每项配置都该进指纹');
    });
  });

  // 这条是防回退的：用 `rhttp.Rhttp.request(...)`（不带 client）时，Rust 侧
  // 每个请求都会 `RequestClient::new(settings)`，连接池和 TLS 会话缓存全丢，
  // 等于每张图重新握手一次。表现是下载一会儿就 `tls handshake eof`，但功能
  // 测试全绿——所以只能在这儿守。
  test('图片/网络请求走共享 client，不用每次新建的 API', () {
    var source = File('lib/network/app_dio.dart').readAsStringSync();
    expect(
      source.contains('rhttp.Rhttp.request('),
      isFalse,
      reason: 'rhttp 的这个入口每次都会新建 reqwest::Client，等于每张图重新握手',
    );
    expect(
      source.contains('_clients.acquire'),
      isTrue,
      reason: '要用 ReusableClient 复用连接池',
    );
  });
}
