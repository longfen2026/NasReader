import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_reader/config/api_config.dart';
import 'package:nas_reader/core/network_client.dart';
import 'package:nas_reader/services/server_endpoint_service.dart';
import 'package:nas_reader/services/server_failover_service.dart';
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
  TestWidgetsFlutterBinding.ensureInitialized();

  const primary = 'http://nas:6088';
  const backup = 'http://backup:6088';

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'server_base_url': primary,
      // 单元测试无安全存储插件，走明文回落路径注入登录态
      'auth_token': 'test-token',
    });
    await ApiConfig.init();
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

  test('未配置备用服务器时不做任何探测', () async {
    await ServerEndpointService.save(primary: primary);
    final probeDio = _dioWith({});
    ServerFailoverService.probeClientForTesting = probeDio;

    final pick = await ServerFailoverService.ensureAvailable(force: true);

    expect(pick, isNull);
    expect(
        (probeDio.httpClientAdapter as _FakeAdapter).requested, isEmpty);
    expect(ApiConfig.baseUrl, primary);
  });

  test('主服务器可用时保持不变，返回 null', () async {
    ServerFailoverService.probeClientForTesting = _dioWith({primary});

    final pick = await ServerFailoverService.ensureAvailable(force: true);

    expect(pick, isNull);
    expect(ApiConfig.baseUrl, primary);
    expect(NetworkClient.getDio().options.baseUrl, primary);
  });

  test('主服务器不可用时静默切换到备用服务器', () async {
    ServerFailoverService.probeClientForTesting = _dioWith({backup});
    NetworkClient.getDio(baseUrl: primary);

    final pick = await ServerFailoverService.ensureAvailable(force: true);

    expect(pick?.url, backup);
    expect(pick?.usingBackup, isTrue);
    expect(ApiConfig.baseUrl, backup);
    // 已持有的 Dio 实例被原地改写，立即指向备用地址
    expect(NetworkClient.getDio().options.baseUrl, backup);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('server_base_url'), backup);
  });

  test('主服务器恢复后自动切回', () async {
    await ApiConfig.setBaseUrl(backup);
    ServerFailoverService.probeClientForTesting = _dioWith({primary});
    NetworkClient.getDio(baseUrl: backup);

    final pick = await ServerFailoverService.ensureAvailable(force: true);

    expect(pick?.url, primary);
    expect(pick?.usingBackup, isFalse);
    expect(ApiConfig.baseUrl, primary);
    expect(NetworkClient.getDio().options.baseUrl, primary);
  });

  test('非 force 调用受最小间隔节流', () async {
    ServerFailoverService.probeClientForTesting = _dioWith({primary});
    // 先 force 触发一次探测并记录时间
    await ServerFailoverService.ensureAvailable(force: true);

    final probeDio = _dioWith({primary});
    ServerFailoverService.probeClientForTesting = probeDio;
    final pick = await ServerFailoverService.ensureAvailable();

    expect(pick, isNull);
    expect(
        (probeDio.httpClientAdapter as _FakeAdapter).requested, isEmpty);
  });
}
