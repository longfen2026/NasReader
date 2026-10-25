// lib/services/server_endpoint_service.dart
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';
import 'server_profile_service.dart';

/// 用户配置的局域网服务器地址。
class ServerEndpoints {
  final String primary;
  final String tailnetTarget;

  /// 备用服务器地址，主服务器不可用时自动切换使用。
  final String backupUrl;

  const ServerEndpoints({
    this.primary = '',
    this.tailnetTarget = '',
    this.backupUrl = '',
  });

  bool get hasTailnetTarget => tailnetTarget.isNotEmpty;
  bool get hasBackupUrl => backupUrl.isNotEmpty;
}

/// 管理主/备服务器地址与直连健康检查。
class ServerEndpointService {
  static const String _keyPrimary = 'server_primary_url';
  static const String _keyTailnetTarget = 'server_tailnet_target';
  // 备用服务器使用新 key，避免被移除的旧版主备功能留下的残留值复活；
  // 旧版的 server_backup_url / server_using_backup 仅在保存时清理。
  static const String _keyBackupUrl = 'server_backup_url_v2';
  static const String _keyLegacyBackup = 'server_backup_url';
  static const String _keyLegacyUsingBackup = 'server_using_backup';

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
    final backupUrl = prefs.getString(_keyBackupUrl) ?? '';
    return ServerEndpoints(
      primary: primary,
      tailnetTarget: tailnetTarget,
      backupUrl: backupUrl,
    );
  }

  static Future<void> save({
    required String primary,
    String tailnetTarget = '',
    String backupUrl = '',
  }) async {
    final normalizedPrimary = normalizeUrl(primary);
    final normalizedTailnetTarget = normalizeTailnetTarget(tailnetTarget);
    final normalizedBackupUrl = normalizeUrl(backupUrl);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPrimary, normalizedPrimary);
    if (normalizedTailnetTarget.isEmpty) {
      await prefs.remove(_keyTailnetTarget);
    } else {
      await prefs.setString(_keyTailnetTarget, normalizedTailnetTarget);
    }
    if (normalizedBackupUrl.isEmpty) {
      await prefs.remove(_keyBackupUrl);
    } else {
      await prefs.setString(_keyBackupUrl, normalizedBackupUrl);
    }
    await prefs.remove(_keyLegacyBackup);
    await prefs.remove(_keyLegacyUsingBackup);
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

  /// 优先探测主服务器，不可用时回落备用服务器；均不可用返回 null。
  static Future<ServerEndpointPick?> pickAvailable({
    required String primary,
    String backupUrl = '',
    Dio? client,
  }) async {
    final normalizedPrimary = normalizeUrl(primary);
    final normalizedBackupUrl = normalizeUrl(backupUrl);

    if (normalizedPrimary.isNotEmpty &&
        await probe(normalizedPrimary, client: client)) {
      return ServerEndpointPick(url: normalizedPrimary, usingBackup: false);
    }

    if (normalizedBackupUrl.isNotEmpty &&
        await probe(normalizedBackupUrl, client: client)) {
      AppLogger.log('🔀 主服务器不可用，切换到备用服务器 $normalizedBackupUrl');
      return ServerEndpointPick(url: normalizedBackupUrl, usingBackup: true);
    }

    return null;
  }
}

/// 主/备直连健康检查的结果。
class ServerEndpointPick {
  final String url;

  /// 选中的是否为备用服务器地址。
  final bool usingBackup;

  const ServerEndpointPick({required this.url, this.usingBackup = false});
}
