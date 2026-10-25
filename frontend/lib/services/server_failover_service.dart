// lib/services/server_failover_service.dart
import 'package:dio/dio.dart';

import '../config/api_config.dart';
import '../core/network_client.dart';
import 'app_logger.dart';
import 'server_endpoint_service.dart';

/// 在启动、从后台恢复与请求连接失败时校验主/备服务器可用性，静默完成切换。
///
/// Tailnet 回退仍由 [NetworkClient] 处理；本服务只负责主/备服务器之间的切换，
/// 探测顺序天然优先主服务器，主服务器恢复后会自动切回。
class ServerFailoverService {
  /// 并发失败会同时触发校验，用锁合并为一次探测。
  static Future<ServerEndpointPick?>? _running;

  /// 两次探测的最小间隔，避免频繁切前后台时反复请求。
  static const Duration minInterval = Duration(seconds: 10);
  static DateTime? _lastCheckedAt;

  /// 仅用于单元测试注入健康探针客户端，避免发起真实网络请求。
  static Dio? probeClientForTesting;

  static void resetProbeClientForTesting() {
    probeClientForTesting = null;
    _lastCheckedAt = null;
    _running = null;
  }

  /// 探测并应用可用地址；发生切换时返回选中的结果，否则返回 null。
  static Future<ServerEndpointPick?> ensureAvailable({bool force = false}) {
    if (_running != null) return _running!;

    final last = _lastCheckedAt;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < minInterval) {
      return Future.value(null);
    }

    final task = _ensureAvailable();
    _running = task;
    return task.whenComplete(() {
      _running = null;
      _lastCheckedAt = DateTime.now();
    });
  }

  static Future<ServerEndpointPick?> _ensureAvailable() async {
    if (!ApiConfig.isLoggedIn) return null;

    final endpoints = await ServerEndpointService.load();
    // 未配置备用服务器时没有可切换的目标，直接跳过。
    if (!endpoints.hasBackupUrl) return null;

    try {
      final pick = await ServerEndpointService.pickAvailable(
        primary: endpoints.primary,
        backupUrl: endpoints.backupUrl,
        client: probeClientForTesting,
      );
      if (pick == null) return null;

      final target = NetworkClient.sanitizeBaseUrl(pick.url);
      if (target == NetworkClient.sanitizeBaseUrl(ApiConfig.baseUrl)) {
        return null;
      }

      AppLogger.log('🔀 服务切换：${ApiConfig.baseUrl} -> ${pick.url}');
      await ApiConfig.setBaseUrl(pick.url);
      // 原地改写 baseUrl，让已持有 Dio 实例的页面立即用上新地址。
      NetworkClient.updateBaseUrl(pick.url);
      return pick;
    } catch (e) {
      AppLogger.log('⚠️ 服务器可用性校验失败: $e');
      return null;
    }
  }
}
