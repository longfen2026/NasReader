import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

/// Android 原生 tsnet 转发器的连接结果。
class TailnetTransportResult {
  final String baseUrl;

  const TailnetTransportResult(this.baseUrl);
}

/// 当前原生 tsnet 节点的连接状态。
class TailnetStatus {
  final String backendState;
  final String? authUrl;

  const TailnetStatus({required this.backendState, this.authUrl});

  bool get needsAuthorization => authUrl != null && authUrl!.isNotEmpty;

  bool get isAuthorized =>
      backendState.toLowerCase() == 'running' && !needsAuthorization;

  factory TailnetStatus.fromJson(Map<String, dynamic> json) {
    final authUrl = json['authUrl'] as String?;
    return TailnetStatus(
      backendState: (json['backendState'] as String?) ?? 'Unknown',
      authUrl: authUrl == null || authUrl.isEmpty ? null : authUrl,
    );
  }
}

/// 表示需要用户在浏览器完成 Tailscale 授权。
class TailnetAuthorizationRequired implements Exception {
  final TailnetStatus status;

  const TailnetAuthorizationRequired(this.status);

  @override
  String toString() => 'Tailnet authorization required: ${status.authUrl}';
}

/// 将 Tailnet 连接转换为供 Dio 使用的 loopback HTTP 地址。
///
/// 配置保存的是 Tailnet 中后端的主机和端口；返回的 loopback 地址仅供
/// 当前请求重放使用，绝不写入 [ApiConfig] 或服务器历史记录。
abstract class TailnetTransport {
  Future<TailnetTransportResult?> connect(String target);

  Future<TailnetStatus?> status() async => null;
}

class TailnetTransportService implements TailnetTransport {
  static const MethodChannel _channel = MethodChannel('nas_reader/tailnet');
  static const _authorizationCompletedKey = 'tailnet_authorization_completed';

  const TailnetTransportService();

  @override
  Future<TailnetTransportResult?> connect(String target) async {
    if (!Platform.isAndroid || target.trim().isEmpty) return null;

    try {
      final response = await _channel.invokeMethod<String>(
        'connect',
        <String, String>{'target': target.trim()},
      );
      final status = _parseStatus(response);
      if (status.needsAuthorization) {
        throw TailnetAuthorizationRequired(status);
      }

      await _recordAuthorizationStatus(status);

      final data = jsonDecode(response ?? '') as Map<String, dynamic>;
      final baseUrl = data['baseUrl'] as String?;
      if (baseUrl == null || baseUrl.isEmpty) return null;
      return TailnetTransportResult(baseUrl);
    } on TailnetAuthorizationRequired {
      rethrow;
    } on PlatformException catch (error) {
      AppLogger.log('⚠️ Tailnet 连接失败: ${error.message ?? error.code}');
      return null;
    } catch (error) {
      AppLogger.log('⚠️ Tailnet 连接异常: $error');
      return null;
    }
  }

  @override
  Future<TailnetStatus?> status() async {
    if (!Platform.isAndroid) return null;

    try {
      final response = await _channel.invokeMethod<String>('status');
      final status = _parseStatus(response);
      await _recordAuthorizationStatus(status);
      return status;
    } on PlatformException catch (error) {
      AppLogger.log('⚠️ Tailnet 状态读取失败: ${error.message ?? error.code}');
      return null;
    } catch (error) {
      AppLogger.log('⚠️ Tailnet 状态读取异常: $error');
      return null;
    }
  }

  Future<TailnetStatus?> beginAuthorization() async {
    if (!Platform.isAndroid) return null;

    try {
      final response = await _channel.invokeMethod<String>('authorize');
      final status = _parseStatus(response);
      await _recordAuthorizationStatus(status);
      return status;
    } on PlatformException catch (error) {
      AppLogger.log('⚠️ Tailnet 授权启动失败: ${error.message ?? error.code}');
      return null;
    } catch (error) {
      AppLogger.log('⚠️ Tailnet 授权启动异常: $error');
      return null;
    }
  }

  Future<bool> logout() async {
    if (!Platform.isAndroid) return false;

    try {
      await _channel.invokeMethod<void>('logout');
      final preferences = await SharedPreferences.getInstance();
      await preferences.remove(_authorizationCompletedKey);
      return true;
    } on PlatformException catch (error) {
      AppLogger.log('⚠️ Tailnet 注销失败: ${error.message ?? error.code}');
      return false;
    } catch (error) {
      AppLogger.log('⚠️ Tailnet 注销异常: $error');
      return false;
    }
  }

  Future<bool> hasCompletedAuthorization() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_authorizationCompletedKey) ?? false;
  }

  Future<void> _recordAuthorizationStatus(TailnetStatus status) async {
    if (!status.isAuthorized) return;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_authorizationCompletedKey, true);
  }

  TailnetStatus _parseStatus(String? response) {
    if (response == null || response.isEmpty) {
      return const TailnetStatus(backendState: 'Unknown');
    }
    final data = jsonDecode(response) as Map<String, dynamic>;
    return TailnetStatus.fromJson(data);
  }
}
