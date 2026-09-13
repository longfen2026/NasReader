import 'package:flutter/material.dart';
import 'package:nas_reader/config/api_config.dart';
import 'package:nas_reader/config/theme_manager.dart';
import 'package:nas_reader/core/network_client.dart';
import 'package:nas_reader/services/tailnet_transport_service.dart';

// 引入本地书架与 NAS 文件浏览器页面
import 'pages/login_page.dart';
import 'main_navigation_container.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ApiConfig.init();
  await ThemeManager.init(); // 👈 初始化主题配置
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
    _showFirstTailnetAuthorizationHint();
  }

  Future<void> _showFirstTailnetAuthorizationHint() async {
    final hasCompletedAuthorization =
        await const TailnetTransportService().hasCompletedAuthorization();
    if (hasCompletedAuthorization || !mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = navigatorKey.currentContext;
      if (context == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请到设置-账号中心进行首次 Tailscale 登录授权。'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 4),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeManager.themeModeNotifier,
      builder: (context, currentThemeMode, _) {
        return ValueListenableBuilder<AppThemePreset>(
          valueListenable: ThemeManager.presetNotifier,
          builder: (context, currentPreset, _) {
            return MaterialApp(
              title: 'NAS Reader',
              navigatorKey: navigatorKey,
              debugShowCheckedModeBanner: false,
              // 1. 绑定全局主题模式（跟随系统/浅色/深色）
              themeMode: currentThemeMode,
              // 2. 浅色主题配置：颜色值来自主题色预设（Purple / Blue）
              theme: ThemeData(
                colorScheme: currentPreset.lightColorScheme,
                useMaterial3: true,
              ),
              // 3. 深色主题配置（必须配置，否则深色模式下不会生效）
              darkTheme: ThemeData(
                colorScheme: currentPreset.darkColorScheme,
                useMaterial3: true,
              ),
              home: ApiConfig.isLoggedIn
                  ? MainNavigationContainer(dio: NetworkClient.getDio())
                  : const LoginPage(),
            );
          },
        );
      },
    );
  }
}
