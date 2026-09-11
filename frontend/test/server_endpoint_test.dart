import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_reader/services/server_endpoint_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 按 baseUrl 前缀决定可达性的假适配器，避免测试发起真实网络请求
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.reachable);

  final Set<String> reachable;
  final List<String> requested = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    requested.add(url);
    if (reachable.any(url.startsWith)) {
      return ResponseBody.fromString('{}', 200);
    }
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'host unreachable',
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _dioWith(Set<String> reachable) {
  final dio = Dio(BaseOptions(validateStatus: (_) => true));
  dio.httpClientAdapter = _FakeAdapter(reachable);
  return dio;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('normalizeUrl 复用 profile 的归一化规则', () {
    expect(ServerEndpointService.normalizeUrl(' http://nas:6088// '), 'http://nas:6088');
  });

  test('normalizeTailnetTarget 只保留 tsnet dial 所需的 host:port', () {
    expect(
      ServerEndpointService.normalizeTailnetTarget(' https://nas.example.ts.net:6088/ '),
      'nas.example.ts.net:6088',
    );
  });

  test('isReachableStatus 把 4xx 也视为服务可达', () {
    expect(ServerEndpointService.isReachableStatus(200), isTrue);
    expect(ServerEndpointService.isReachableStatus(404), isTrue);
    expect(ServerEndpointService.isReachableStatus(500), isFalse);
    expect(ServerEndpointService.isReachableStatus(null), isFalse);
  });

  test('probe 对空地址直接返回不可用，不发起请求', () async {
    expect(await ServerEndpointService.probe('   '), isFalse);
  });

  test('pickAvailable 在地址为空时返回 null', () async {
    expect(await ServerEndpointService.pickAvailable(primary: ''), isNull);
  });

  test('pickAvailable 仅返回可达的局域网地址', () async {
    const primary = 'http://nas:6088';
    final pick = await ServerEndpointService.pickAvailable(
      primary: primary,
      client: _dioWith({primary}),
    );

    expect(pick?.url, primary);
  });

  test('save 持久化局域网地址并清理旧主备键', () async {
    SharedPreferences.setMockInitialValues({
      'server_backup_url': 'http://backup:6088',
      'server_using_backup': true,
    });

    await ServerEndpointService.save(
      primary: ' http://nas:6088/ ',
      tailnetTarget: 'https://nas.example.ts.net:6088/',
    );
    final prefs = await SharedPreferences.getInstance();

    expect((await ServerEndpointService.load()).primary, 'http://nas:6088');
    expect(
      (await ServerEndpointService.load()).tailnetTarget,
      'nas.example.ts.net:6088',
    );
    expect(prefs.containsKey('server_backup_url'), isFalse);
    expect(prefs.containsKey('server_using_backup'), isFalse);
  });
}
