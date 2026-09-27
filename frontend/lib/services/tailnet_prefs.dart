// lib/services/tailnet_prefs.dart
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/build_config.dart';
import 'app_logger.dart';
import 'tailnet_transport_service.dart';

/// Tailnet 能力开关，默认关闭。关闭时不展示相关配置项，且不触发 Tailnet 回退。
///
/// notailnet 风味（`--dart-define=TAILNET_SUPPORTED=false`）下开关恒为关闭，
/// 且忽略持久化的历史值，确保不会调用未注册的原生 MethodChannel。
class TailnetPrefs {
  static const String _key = 'tailnet_enabled';

  static final ValueNotifier<bool> enabledNotifier = ValueNotifier<bool>(false);

  /// 关闭开关时用于停止原生 tsnet；测试可替换以避免触发 MethodChannel。
  static TailnetTransport transport = const TailnetTransportService();

  static Future<void> init() async {
    if (!BuildConfig.tailnetSupported) {
      enabledNotifier.value = false;
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      enabledNotifier.value = prefs.getBool(_key) ?? false;
    } catch (e) {
      AppLogger.log('⚠️ Tailnet 开关读取失败，默认关闭: $e');
    }
  }

  static Future<void> setEnabled(bool enabled) async {
    if (!BuildConfig.tailnetSupported) return;
    enabledNotifier.value = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, enabled);
    } catch (e) {
      AppLogger.log('⚠️ Tailnet 开关保存失败，重启后将丢失: $e');
    }
    // 关闭时停止原生服务，但保留授权信息（不调用 logout）。
    if (!enabled) {
      await transport.stop();
    }
  }

  /// 供 NetworkClient 等非 UI 场景在无 Notifier 时同步读取。
  static Future<bool> isEnabled() async {
    if (!BuildConfig.tailnetSupported) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_key) ?? false;
    } catch (e) {
      AppLogger.log('⚠️ Tailnet 开关读取失败，默认关闭: $e');
      return false;
    }
  }
}
