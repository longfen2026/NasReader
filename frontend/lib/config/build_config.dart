// lib/config/build_config.dart
/// 编译期能力开关。
///
/// 通过 `--dart-define=TAILNET_SUPPORTED=true|false` 注入。默认 true，
/// 与打包 tailnet AAR 的 `tailnet` 产品风味对应；notailnet 风味构建时应传
/// `--dart-define=TAILNET_SUPPORTED=false`，隐藏所有 Tailnet 相关 UI 与逻辑，
/// 避免调用未注册的 MethodChannel。
class BuildConfig {
  static const bool tailnetSupported =
      bool.fromEnvironment('TAILNET_SUPPORTED', defaultValue: true);
}
