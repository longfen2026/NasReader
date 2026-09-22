// --- 全局 Dio 单例构建与拦截器注入 ---
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:nas_reader/config/api_config.dart';
import 'package:nas_reader/main_navigation_container.dart';
import 'package:nas_reader/pages/login_page.dart';
import 'package:nas_reader/services/app_logger.dart';
import 'package:nas_reader/services/auth_service.dart';
import 'package:nas_reader/services/server_endpoint_service.dart';
import 'package:nas_reader/services/tailnet_transport_service.dart';
import 'package:url_launcher/url_launcher.dart';

// 全局 Navigation Key，用于在 Dio 拦截器中触发 401 登出跳转
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

enum ServerConnectionPath {
  lan,
  tailnet,
}

class NetworkClient {
  static Dio? _dioInstance;
  static bool _tailnetAuthorizationDialogVisible = false;

  /// 最近一次成功请求实际使用的传输路径，供服务状态页面展示。
  static final ValueNotifier<ServerConnectionPath> connectionPath =
      ValueNotifier<ServerConnectionPath>(ServerConnectionPath.lan);

  /// 标记请求已经历过一次 Tailnet 重试，避免无限重放。
  static const String _tailnetRetryFlag = 'tailnetRetried';
  static TailnetTransport _tailnetTransport = const TailnetTransportService();

  /// 仅连接层失败才触发 Tailnet 回退；服务端返回了响应说明链路通畅。
  static bool _isConnectionFailure(DioException error) {
    if (error.response != null) return false;
    return error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.error is SocketException;
  }

  /// 清洗 BaseUrl：去除协议外末尾的斜杠、/api、/api/v1 等多余前缀，避免路由重复拼装
  static String sanitizeBaseUrl(String? rawUrl) {
    if (rawUrl == null || rawUrl.trim().isEmpty) {
      rawUrl = ApiConfig.baseUrl; // 回退到全局配置
    }
    String cleaned = rawUrl.trim();
    // 递归剔除结尾的 /api/v1、/api 以及所有尾部斜杠
    cleaned = cleaned
        .replaceAll(RegExp(r'/api/v\d+/?$'), '')
        .replaceAll(RegExp(r'/api/?$'), '')
        .replaceAll(RegExp(r'/+$'), '');
    return cleaned;
  }

  /// 获取 Dio 单例
  static Dio getDio({String? baseUrl, String? token}) {
    final targetBaseUrl = sanitizeBaseUrl(baseUrl ?? ApiConfig.baseUrl);

    // 1. 如果单例已存在，且 baseUrl 没有变更，直接复用
    if (_dioInstance != null &&
        _dioInstance!.options.baseUrl == targetBaseUrl) {
      return _dioInstance!;
    }

    // 2. 如果 baseUrl 变更或初次初始化，创建新的 Dio 实例
    final options = BaseOptions(
      baseUrl: targetBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      contentType: 'application/json',
    );

    final dio = Dio(options);

    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (reqOptions, handler) async {
          // 每次请求前动态获取最新的 Token（优先使用传入的 token，次选 ApiConfig/AuthService）
          final currentToken =
              token ?? ApiConfig.authToken ?? await AuthService.getToken();
          if (currentToken != null && currentToken.isNotEmpty) {
            reqOptions.headers['Authorization'] = 'Bearer $currentToken';
          }

          AppLogger.log(
              '🌐 [HTTP REQUEST] ${reqOptions.method} ${reqOptions.uri}');
          return handler.next(reqOptions);
        },
        onResponse: (response, handler) {
          connectionPath.value =
              response.requestOptions.extra[_tailnetRetryFlag] == true
                  ? ServerConnectionPath.tailnet
                  : ServerConnectionPath.lan;
          AppLogger.log(
              '✅ [HTTP ${response.statusCode}] ${response.requestOptions.uri}');
          return handler.next(response);
        },
        onError: (DioException error, handler) async {
          AppLogger.log(
              '❌ [HTTP ERROR ${error.response?.statusCode}] -> ${error.requestOptions.uri}');

          // 401 鉴权失效：重置网络单例、清理本地凭证并切回登录页
          if (error.response?.statusCode == 401) {
            reset();
            await ApiConfig.onLogout();
            await AuthService.clearAuth();

            navigatorKey.currentState?.pushAndRemoveUntil(
              MaterialPageRoute(builder: (context) => const LoginPage()),
              (route) => false,
            );
            return handler.next(error);
          }

          // 局域网直连失败后，原生层会把 Tailnet 连接转为本机 TCP 转发。
          if (_isConnectionFailure(error) &&
              error.requestOptions.extra[_tailnetRetryFlag] != true) {
            final endpoints = await ServerEndpointService.load();
            try {
              final transport =
                  await _tailnetTransport.connect(endpoints.tailnetTarget);
              if (transport != null) {
                final retryOptions = error.requestOptions
                  ..baseUrl = sanitizeBaseUrl(transport.baseUrl)
                  ..extra[_tailnetRetryFlag] = true;
                // FormData 一经发送即被 finalize，重试必须换用克隆体，否则报 already finalized
                if (retryOptions.data is FormData) {
                  retryOptions.data = (retryOptions.data as FormData).clone();
                }
                try {
                  return handler.resolve(await dio.fetch(retryOptions));
                } on DioException catch (retryError) {
                  return handler.next(retryError);
                }
              }
            } on TailnetAuthorizationRequired catch (auth) {
              AppLogger.log('⚠️ Tailnet 需要授权: ${auth.status.authUrl}');
              _showTailnetAuthorization(auth.status.authUrl!);
            }
          }
          return handler.next(error);
        },
      ),
    );

    _dioInstance = dio;
    return dio;
  }

  /// 退出登录或切换服务器时，主动重置 Dio 实例
  static void reset() {
    _dioInstance?.close(force: true);
    _dioInstance = null;
    connectionPath.value = ServerConnectionPath.lan;
  }

  /// 服务器地址变更时原地改写 baseUrl，让已经持有该实例的页面立即用上新地址。
  static void updateBaseUrl(String baseUrl) {
    final cleaned = sanitizeBaseUrl(baseUrl);
    if (_dioInstance == null || _dioInstance!.options.baseUrl == cleaned)
      return;
    _dioInstance!.options.baseUrl = cleaned;
    AppLogger.log('🔁 [HTTP] baseUrl 已更新为 $cleaned');
  }

  /// 仅用于单元测试替换原生 Tailnet 调用。
  static void setTailnetTransportForTesting(TailnetTransport transport) {
    _tailnetTransport = transport;
  }

  static void resetTailnetTransportForTesting() {
    _tailnetTransport = const TailnetTransportService();
  }

  static void _showTailnetAuthorization(String authUrl) {
    if (_tailnetAuthorizationDialogVisible) return;
    final context = navigatorKey.currentContext;
    if (context == null) return;

    _tailnetAuthorizationDialogVisible = true;
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        title: const Text('需要连接 Tailnet'),
        content: const Text('请在浏览器中完成 Tailscale 授权，然后返回应用重试。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () async {
              final uri = Uri.tryParse(authUrl);
              if (uri != null) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
              }
            },
            child: const Text('去授权'),
          ),
        ],
      ),
    ).whenComplete(() => _tailnetAuthorizationDialogVisible = false);
  }
}

// --- 启动引导检查页 ---
class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  @override
  void initState() {
    super.initState();
    _checkAuthStatus();
  }

  Future<void> _checkAuthStatus() async {
    final token = await AuthService.getToken();
    final baseUrl = await AuthService.getBaseUrl();
    final dio = NetworkClient.getDio(baseUrl: baseUrl, token: token);

    await Future.delayed(const Duration(milliseconds: 300));

    if (!mounted) return;

    if (token != null && token.isNotEmpty) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => MainNavigationContainer(dio: dio),
        ),
      );
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => const LoginPage(),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
  }
}
