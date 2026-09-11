// lib/services/server_endpoint_service.dart
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';
import 'server_profile_service.dart';

/// 用户配置的局域网服务器地址。
class ServerEndpoints {
  final String primary;
  final String tailnetTarget;

  const ServerEndpoints({
    this.primary = '',
    this.tailnetTarget = '',
  });

  bool get hasTailnetTarget => tailnetTarget.isNotEmpty;
}

/// 管理局域网服务器地址与其直连健康检查。
class ServerEndpointService {
  static const String _keyPrimary = 'server_primary_url';
  static const String _keyTailnetTarget = 'server_tailnet_target';
  // 仅用于迁移既有主备配置，新的版本不会读取或写入它们。
  static const String _keyBackup = 'server_backup_url';
  static const String _keyUsingBackup = 'server_using_backup';

  /// 健康探针路径；旧版后端没有该路由时返回 404，仍视为“可达”
  static const String healthPath = '/api/v1/health';

  static const Duration probeTimeout = Duration(seconds: 4);

  static String normalizeUrl(String url) => ServerProfileService.normalizeUrl(url);

  /// HTTP 状态码 < 500 即认为服务可达（含 404，兼容无健康接口的旧后端）
  static bool isReachableStatus(int? statusCode) =>
      statusCode != null && statusCode < 500;

  static Future<ServerEndpoints> load() async {
    final prefs = await SharedPreferences.getInstance();
    final primary = prefs.getString(_keyPrimary) ?? '';
    final tailnetTarget = prefs.getString(_keyTailnetTarget) ?? '';
    return ServerEndpoints(primary: primary, tailnetTarget: tailnetTarget);
  }

  static Future<void> save({
    required String primary,
    String tailnetTarget = '',
  }) async {
    final normalizedPrimary = normalizeUrl(primary);
    final normalizedTailnetTarget = normalizeTailnetTarget(tailnetTarget);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPrimary, normalizedPrimary);
    if (normalizedTailnetTarget.isEmpty) {
      await prefs.remove(_keyTailnetTarget);
    } else {
      await prefs.setString(_keyTailnetTarget, normalizedTailnetTarget);
    }
    await prefs.remove(_keyBackup);
    await prefs.remove(_keyUsingBackup);
  }

  /// tsnet dial 使用 host:port，不接受 HTTP URL。
  static String normalizeTailnetTarget(String target) {
    var cleaned = target.trim();
    cleaned = cleaned.replaceFirst(RegExp(r'^https?://'), '');
    while (cleaned.endsWith('/')) {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    return cleaned;
  }

  /// 探测单个地址是否可用
  static Future<bool> probe(String url, {Dio? client}) async {
    final target = normalizeUrl(url);
    if (target.isEmpty) return false;

    final dio = client ??
        Dio(
          BaseOptions(
            connectTimeout: probeTimeout,
            receiveTimeout: probeTimeout,
            // 交由 isReachableStatus 判定，避免 4xx 抛异常
            validateStatus: (_) => true,
          ),
        );

    try {
      final response = await dio.get('$target$healthPath');
      return isReachableStatus(response.statusCode);
    } on DioException catch (e) {
      // 服务端返回了响应说明链路通畅，仅连接层失败才算不可用
      if (e.response != null) return isReachableStatus(e.response!.statusCode);
      AppLogger.log('⚠️ 服务探测失败 $target: ${e.type}');
      return false;
    } catch (e) {
      AppLogger.log('⚠️ 服务探测异常 $target: $e');
      return false;
    } finally {
      if (client == null) dio.close(force: true);
    }
  }

  /// 探测用户配置的局域网服务器；不可达时返回 null。
  static Future<ServerEndpointPick?> pickAvailable({
    required String primary,
    Dio? client,
  }) async {
    final normalizedPrimary = normalizeUrl(primary);

    if (normalizedPrimary.isNotEmpty && await probe(normalizedPrimary, client: client)) {
      return ServerEndpointPick(url: normalizedPrimary);
    }

    return null;
  }
}

/// 局域网直连健康检查的结果。
class ServerEndpointPick {
  final String url;

  const ServerEndpointPick({required this.url});
}
