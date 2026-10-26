// lib/services/app_lock_service.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 应用锁定方式：4 位数字密码或指纹识别
enum AppLockMethod { pin, biometric }

extension AppLockMethodLabel on AppLockMethod {
  String get label => this == AppLockMethod.pin ? '数字密码' : '指纹识别';
}

class AppLockService {
  AppLockService._();

  static const _prefEnabledKey = 'app_lock_enabled';
  static const _prefMethodKey = 'app_lock_method';
  static const _securePinKey = 'app_lock_pin';

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  static final LocalAuthentication _localAuth = LocalAuthentication();

  /// 是否启用应用锁定，设置页与锁定门共用，变更立即生效
  static final ValueNotifier<bool> enabledNotifier = ValueNotifier(false);

  /// 当前锁定方式
  static final ValueNotifier<AppLockMethod?> methodNotifier =
      ValueNotifier(null);

  /// 锁定门是否处于待验证状态（打开 App 或从后台返回时置为 true）
  static final ValueNotifier<bool> lockedNotifier = ValueNotifier(false);

  /// PIN 缓存在内存中，校验用；明文仅存在于系统安全存储
  static String? _pin;

  static bool get enabled => enabledNotifier.value;
  static AppLockMethod? get method => methodNotifier.value;
  static bool get hasPin => _pin != null;

  /// 配置是否完整（启用且已设置有效的验证方式），锁定门据此判断是否拦截
  static bool get isConfigured {
    if (!enabled) return false;
    switch (method) {
      case AppLockMethod.pin:
        return _pin != null;
      case AppLockMethod.biometric:
        return true;
      case null:
        return false;
    }
  }

  /// App 启动时加载持久化配置
  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final pin = await _secureStorage.read(key: _securePinKey);

      _pin = (pin != null && pin.length == 4) ? pin : null;
      methodNotifier.value = _parseMethod(prefs.getString(_prefMethodKey));
      enabledNotifier.value = prefs.getBool(_prefEnabledKey) ?? false;
    } catch (e) {
      // 读取失败按未配置处理，保证应用可正常进入
      _pin = null;
      methodNotifier.value = null;
      enabledNotifier.value = false;
    }
  }

  static AppLockMethod? _parseMethod(String? raw) {
    if (raw == AppLockMethod.pin.name) return AppLockMethod.pin;
    if (raw == AppLockMethod.biometric.name) return AppLockMethod.biometric;
    return null;
  }

  static Future<void> setEnabled(bool value) async {
    enabledNotifier.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefEnabledKey, value);
  }

  static Future<void> setMethod(AppLockMethod value) async {
    methodNotifier.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefMethodKey, value.name);
  }

  static Future<void> savePin(String pin) async {
    _pin = pin;
    await _secureStorage.write(key: _securePinKey, value: pin);
  }

  static bool verifyPin(String input) => _pin == input;

  /// 设备是否支持指纹识别（有已录入的生物特征才视为可用）
  static Future<bool> isBiometricSupported() async {
    try {
      if (!await _localAuth.isDeviceSupported()) return false;
      if (!await _localAuth.canCheckBiometrics) return false;
      final biometrics = await _localAuth.getAvailableBiometrics();
      return biometrics.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  /// 发起指纹认证，返回是否通过
  static Future<bool> authenticateWithBiometrics(String reason) async {
    try {
      return await _localAuth.authenticate(
        localizedReason: reason,
        // 仅使用指纹，不回落到系统锁屏凭据
        biometricOnly: true,
        // 认证过程中退到后台后，回到前台自动重新发起认证
        persistAcrossBackgrounding: true,
      );
    } catch (e) {
      return false;
    }
  }

  /// 进入待验证状态（锁定门在启动与后台返回时调用）
  static void lock() {
    if (isConfigured) lockedNotifier.value = true;
  }

  /// 验证通过后解除锁定
  static void unlock() {
    lockedNotifier.value = false;
  }
}
