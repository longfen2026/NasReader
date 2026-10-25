import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_reader/config/api_config.dart';
import 'package:nas_reader/core/network_client.dart';
import 'package:nas_reader/services/server_endpoint_service.dart';
import 'package:nas_reader/services/server_failover_service.dart';
import 'package:nas_reader/services/tailnet_prefs.dart';
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
      return ResponseBody.fromString('{"ok":true}', 200);
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
  TestWidgetsFlutterBinding.ensureInitialized();

  const primary = 'http://nas.local:6088';
  const backup = 'http://backup.local:6088';

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'server_base_url': primary,
      // 单元测试无安全存储插件，走明文回落路径注入登录态
      'auth_token': 'test-token',
    });
    await ApiConfig.init();
    await TailnetPrefs.setEnabled(false);
    await ServerEndpointService.save(
      primary: primary,
      backupUrl: backup,
    );
    NetworkClient.reset();
    ServerFailoverService.probeClientForTesting = _dioWith({});
  });

  tearDown(() {
    NetworkClient.reset();
    ServerFailoverService.resetProbeClientForTesting();
  });

  test('主服务器连接失败时静默切到备用并重放请求', () async {
    final dio = NetworkClient.getDio(baseUrl: primary);
    final adapter = _FakeAdapter({backup});
    dio.httpClientAdapter = adapter;
    ServerFailoverService.probeClientForTesting = _dioWith({backup});

    final response = await dio.get('/api/v1/files');

    expect(response.statusCode, 200);
    expect(adapter.requested, <String>[
      '$primary/api/v1/files',
      '$backup/api/v1/files',
    ]);
    expect(dio.options.baseUrl, backup);
    expect(ApiConfig.baseUrl, backup);
  });

  test('备用服务器也不可用时错误正常抛出且仅请求一次', () async {
    final dio = NetworkClient.getDio(baseUrl: primary);
    final adapter = _FakeAdapter({});
    dio.httpClientAdapter = adapter;

    await expectLater(dio.get('/api/v1/files'), throwsA(isA<DioException>()));

    expect(adapter.requested, hasLength(1));
  });

  test('已切到备用后主服务器恢复，请求失败会自动切回主服务器', () async {
    await ApiConfig.setBaseUrl(backup);
    final dio = NetworkClient.getDio(baseUrl: backup);
    final adapter = _FakeAdapter({primary});
    dio.httpClientAdapter = adapter;
    ServerFailoverService.probeClientForTesting = _dioWith({primary});

    final response = await dio.get('/api/v1/files');

    expect(response.statusCode, 200);
    expect(adapter.requested, <String>[
      '$backup/api/v1/files',
      '$primary/api/v1/files',
    ]);
    expect(dio.options.baseUrl, primary);
    expect(ApiConfig.baseUrl, primary);
  });

  test('连接层以外的失败不触发主备切换', () async {
    final dio = NetworkClient.getDio(baseUrl: primary);
    final adapter = _HttpStatusAdapter(500);
    dio.httpClientAdapter = adapter;
    ServerFailoverService.probeClientForTesting = _dioWith({backup});

    await expectLater(dio.get('/api/v1/files'), throwsA(isA<DioException>()));

    expect(adapter.requested, hasLength(1));
    expect(ApiConfig.baseUrl, primary);
  });
}

/// 返回指定 HTTP 状态码的适配器，用于模拟服务端 5xx 响应
class _HttpStatusAdapter implements HttpClientAdapter {
  _HttpStatusAdapter(this.statusCode);

  final int statusCode;
  final List<String> requested = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.uri.toString());
    return ResponseBody.fromString('error', statusCode);
  }

  @override
  void close({bool force = false}) {}
}
