import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_reader/core/network_client.dart';
import 'package:nas_reader/services/server_endpoint_service.dart';
import 'package:nas_reader/services/tailnet_transport_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TailnetAdapter implements HttpClientAdapter {
  final List<String> requestedUrls = <String>[];
  bool failLoopback = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    requestedUrls.add(url);

    if (options.uri.host == '127.0.0.1' && !failLoopback) {
      return ResponseBody.fromString('{"ok":true}', 200);
    }
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'unreachable',
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FakeTailnetTransport implements TailnetTransport {
  _FakeTailnetTransport(this.result);

  final TailnetTransportResult? result;
  final List<String> requestedTargets = <String>[];

  @override
  Future<TailnetTransportResult?> connect(String target) async {
    requestedTargets.add(target);
    return result;
  }

  @override
  Future<TailnetStatus?> status() async => null;

  Future<TailnetStatus?> beginAuthorization() async => null;

  Future<bool> hasCompletedAuthorization() async => false;
}

class _AuthorizationRequiredTransport implements TailnetTransport {
  final List<String> requestedTargets = <String>[];

  @override
  Future<TailnetTransportResult?> connect(String target) async {
    requestedTargets.add(target);
    throw const TailnetAuthorizationRequired(
      TailnetStatus(
        backendState: 'NeedsLogin',
        authUrl: 'https://login.tailscale.com/a/example',
      ),
    );
  }

  @override
  Future<TailnetStatus?> status() async => null;

  Future<TailnetStatus?> beginAuthorization() async => null;

  Future<bool> hasCompletedAuthorization() async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const lanUrl = 'http://nas.local:6088';
  const tailnetTarget = 'nas.example.ts.net:6088';

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await ServerEndpointService.save(
      primary: lanUrl,
      tailnetTarget: tailnetTarget,
    );
    NetworkClient.reset();
  });

  tearDown(() {
    NetworkClient.reset();
    NetworkClient.resetTailnetTransportForTesting();
  });

  test('仅运行状态代表 Tailnet 已授权', () {
    expect(
      const TailnetStatus(backendState: 'Running').isAuthorized,
      isTrue,
    );
    expect(
      const TailnetStatus(backendState: 'NeedsLogin').isAuthorized,
      isFalse,
    );
    expect(
      const TailnetStatus(
        backendState: 'Running',
        authUrl: 'https://login.tailscale.com/a/example',
      ).isAuthorized,
      isFalse,
    );
  });

  test('连接失败时仅重放一次到 Tailnet loopback，逻辑地址保持不变', () async {
    final adapter = _TailnetAdapter();
    final transport = _FakeTailnetTransport(
      const TailnetTransportResult('http://127.0.0.1:41837'),
    );
    NetworkClient.setTailnetTransportForTesting(transport);

    final dio = NetworkClient.getDio(baseUrl: lanUrl);
    dio.httpClientAdapter = adapter;

    final response = await dio.get('/api/v1/files');

    expect(response.statusCode, 200);
    expect(transport.requestedTargets, <String>[tailnetTarget]);
    expect(
      adapter.requestedUrls,
      <String>[
        '$lanUrl/api/v1/files',
        'http://127.0.0.1:41837/api/v1/files',
      ],
    );
    expect(dio.options.baseUrl, lanUrl);
    expect(NetworkClient.connectionPath.value, ServerConnectionPath.tailnet);
  });

  test('Tailnet 重试失败后不会再次尝试传输', () async {
    final adapter = _TailnetAdapter()..failLoopback = true;
    final transport = _FakeTailnetTransport(
      const TailnetTransportResult('http://127.0.0.1:41837'),
    );
    NetworkClient.setTailnetTransportForTesting(transport);

    final dio = NetworkClient.getDio(baseUrl: lanUrl);
    dio.httpClientAdapter = adapter;

    await expectLater(dio.get('/api/v1/files'), throwsA(isA<DioException>()));

    expect(transport.requestedTargets, <String>[tailnetTarget]);
    expect(adapter.requestedUrls, hasLength(2));
  });

  test('Tailnet 等待授权时保留原始局域网失败且不重放请求', () async {
    final adapter = _TailnetAdapter();
    final transport = _AuthorizationRequiredTransport();
    NetworkClient.setTailnetTransportForTesting(transport);

    final dio = NetworkClient.getDio(baseUrl: lanUrl);
    dio.httpClientAdapter = adapter;

    await expectLater(dio.get('/api/v1/files'), throwsA(isA<DioException>()));

    expect(transport.requestedTargets, <String>[tailnetTarget]);
    expect(adapter.requestedUrls, <String>['$lanUrl/api/v1/files']);
  });
}
