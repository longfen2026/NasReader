import 'dart:io';

import 'package:flutter/services.dart';

import 'app_logger.dart';

/// Android 原生 tsnet 转发器的连接结果。
class TailnetTransportResult {
  final String baseUrl;

  const TailnetTransportResult(this.baseUrl);
}

/// 将 Tailnet 连接转换为供 Dio 使用的 loopback HTTP 地址。
///
/// 配置保存的是 Tailnet 中后端的主机和端口；返回的 loopback 地址仅供
/// 当前请求重放使用，绝不写入 [ApiConfig] 或服务器历史记录。
abstract class TailnetTransport {
  Future<TailnetTransportResult?> connect(String target);
}

class TailnetTransportService implements TailnetTransport {
  static const MethodChannel _channel = MethodChannel('nas_reader/tailnet');

  const TailnetTransportService();

  @override
  Future<TailnetTransportResult?> connect(String target) async {
    if (!Platform.isAndroid || target.trim().isEmpty) return null;

    try {
      final response = await _channel.invokeMethod<String>(
        'connect',
        <String, String>{'target': target.trim()},
      );
      if (response == null || response.isEmpty) return null;
      return TailnetTransportResult(response);
    } on PlatformException catch (error) {
      AppLogger.log('⚠️ Tailnet 连接失败: ${error.message ?? error.code}');
      return null;
    } catch (error) {
      AppLogger.log('⚠️ Tailnet 连接异常: $error');
      return null;
    }
  }
}