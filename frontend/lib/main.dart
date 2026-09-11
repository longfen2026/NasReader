import 'package:flutter/material.dart';
import 'package:nas_reader/config/api_config.dart';
import 'package:nas_reader/config/theme_manager.dart';
import 'package:nas_reader/core/network_client.dart';

// 引入本地书架与 NAS 文件浏览器页面
import 'pages/login_page.dart';
import 'main_navigation_container.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ApiConfig.init();
  await ThemeManager.init(); // 👈 初始化主题配置
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeManager.themeModeNotifier,
      builder: (context, currentThemeMode, _) {
        return MaterialApp(
          title: 'NAS Reader',
          navigatorKey: navigatorKey,
          debugShowCheckedModeBanner: false,
          // 1. 绑定全局主题模式（跟随系统/浅色/深色）
          themeMode: currentThemeMode,
          // 2. 浅色主题配置
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF382E25),
              brightness: Brightness.light,
            ),
            useMaterial3: true,
          ),
          // 3. 深色主题配置（必须配置，否则深色模式下不会生效）
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF382E25),
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
          ),
          home: ApiConfig.isLoggedIn
              ? MainNavigationContainer(dio: NetworkClient.getDio())
              : const LoginPage(),
        );
      },
    );
  }
}