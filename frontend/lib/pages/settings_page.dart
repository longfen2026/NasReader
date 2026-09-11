import 'dart:io';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:nas_reader/config/api_config.dart';
import 'package:nas_reader/config/theme_manager.dart'; // 👈 引入 ThemeManager
import 'package:nas_reader/core/network_client.dart';
import 'package:nas_reader/services/auth_service.dart';
import 'package:nas_reader/services/favorite_service.dart';
import 'package:nas_reader/services/server_endpoint_service.dart';
import 'package:nas_reader/services/server_profile_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'login_page.dart';
import 'trash_bin_page.dart';
import '../services/app_logger.dart';
import '../services/update_service.dart';

class SettingsPage extends StatefulWidget {
  final Dio? dio;

  const SettingsPage({
    super.key,
    this.dio,
  });

  @override
  State<SettingsPage> createState() => SettingsPageState();
}

class SettingsPageState extends State<SettingsPage>
    with WidgetsBindingObserver {
  String _cacheSizeStr = '计算中...';
  bool _isClearing = false;
  bool _isCalculating = false;
  String _versionStr = '';
  bool _isCheckingUpdate = false;

  // release 包的隐藏入口：连点“存储与诊断”标题解锁日志面板
  static const _unlockTapCount = 5;
  static const _unlockTapGap = Duration(seconds: 2);
  bool _diagnosticsUnlocked = false;
  int _secretTaps = 0;
  DateTime? _lastSecretTap;

  void _handleSecretTap() {
    if (_diagnosticsUnlocked) return;

    final now = DateTime.now();
    final last = _lastSecretTap;
    _secretTaps = (last == null || now.difference(last) > _unlockTapGap)
        ? 1
        : _secretTaps + 1;
    _lastSecretTap = now;

    if (_secretTaps < _unlockTapCount) return;

    setState(() => _diagnosticsUnlocked = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已开启网络诊断日志')),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    calculateCacheSize();
    _loadVersion();
  }

  /// 源于 pubspec.yaml 的 version，构建时注入到各平台包信息
  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() => _versionStr = 'v${info.version}+${info.buildNumber}');
    } catch (e) {
      AppLogger.log('⚠️ 读取版本信息失败: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      calculateCacheSize();
    }
  }

  Future<void> calculateCacheSize() async {
    if (_isCalculating) return;
    _isCalculating = true;

    try {
      int totalBytes = 0;

      final tempDir = await getTemporaryDirectory();
      if (tempDir.existsSync()) {
        totalBytes += await _getDirSize(tempDir);
      }

      final appDir = await getApplicationDocumentsDirectory();
      final booksDir = Directory(p.join(appDir.path, 'books'));
      if (booksDir.existsSync()) {
        totalBytes += await _getDirSize(booksDir);
      }

      if (!mounted) return;
      setState(() {
        _cacheSizeStr = _formatSize(totalBytes);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cacheSizeStr = '未知';
      });
      AppLogger.log('❌ 统计缓存异常: $e');
    } finally {
      _isCalculating = false;
    }
  }

  Future<int> _getDirSize(Directory dir) async {
    int bytes = 0;
    try {
      final list = dir.listSync(recursive: true, followLinks: false);
      for (final item in list) {
        if (item is File) {
          bytes += await item.length();
        }
      }
    } catch (e) {
      AppLogger.log('⚠️ 缓存大小统计不完整: $e');
    }
    return bytes;
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '0.00 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(2)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清理本地缓存'),
        content: const Text('将清空已下载的离线书籍与网络临时文件。确认清除？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认清除'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isClearing = true);

    try {
      final tempDir = await getTemporaryDirectory();
      if (tempDir.existsSync()) {
        final list = tempDir.listSync();
        for (final item in list) {
          try {
            item.deleteSync(recursive: true);
          } catch (e) {
            AppLogger.log('⚠️ 临时文件未能删除 [${item.path}]: $e');
          }
        }
      }

      final appDir = await getApplicationDocumentsDirectory();
      final booksDir = Directory(p.join(appDir.path, 'books'));
      if (booksDir.existsSync()) {
        final list = booksDir.listSync();
        for (final item in list) {
          try {
            item.deleteSync(recursive: true);
          } catch (e) {
            AppLogger.log('⚠️ 缓存书籍未能删除 [${item.path}]: $e');
          }
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本地缓存已全部清除')),
      );
      await calculateCacheSize();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('清理缓存失败: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) {
        setState(() => _isClearing = false);
      }
    }
  }

  void _toast(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        backgroundColor: isError ? Colors.red : null,
      ),
    );
  }

  Future<void> _checkUpdate() async {
    setState(() => _isCheckingUpdate = true);

    try {
      final result = await UpdateService.check();
      if (!mounted) return;

      if (!result.hasUpdate) {
        _toast('当前已是最新版本 v${result.currentVersion}');
        return;
      }
      _showUpdateDialog(result);
    } catch (e) {
      AppLogger.log('⚠️ 检查更新失败: $e');
      if (!mounted) return;
      _toast('检查更新失败，请稍后重试', isError: true);
    } finally {
      if (mounted) {
        setState(() => _isCheckingUpdate = false);
      }
    }
  }

  void _showUpdateDialog(UpdateCheckResult result) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.system_update, color: Color(0xFF5A4A3A)),
            SizedBox(width: 8),
            Text('发现新版本'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '当前版本 v${result.currentVersion}，最新版本 v${result.latestVersion}。',
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
            if (result.releaseNotes.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('更新说明：',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(
                  child: Text(
                    result.releaseNotes,
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade700, height: 1.4),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            const Divider(),
            const Text(
              '将跳转浏览器打开 GitHub Release 页面下载安装包。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('稍后再说'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF382E25),
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _openReleasePage(result.releaseUrl);
            },
            child: const Text('前往下载'),
          ),
        ],
      ),
    );
  }

  Future<void> _openReleasePage(String url) async {
    try {
      final opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (opened || !mounted) return;
      _toast('无法打开浏览器，请手动访问 ${UpdateService.releasePageUrl}', isError: true);
    } catch (e) {
      AppLogger.log('⚠️ 打开 Release 页面失败: $e');
      if (!mounted) return;
      _toast('无法打开浏览器，请手动访问 ${UpdateService.releasePageUrl}', isError: true);
    }
  }

  void _showAboutDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.auto_stories, color: Color(0xFF5A4A3A)),
            SizedBox(width: 8),
            Text('关于 NAS Reader'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'NAS Reader 是一款面向个人 NAS 私有云的书籍阅读与多设备同步工具。',
              style: TextStyle(fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 12),
            const Text('核心功能：',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              '• 支持 TXT 高速排版引擎、EPUB 精准重排与 PDF 原生渲染\n'
              '• 挂载 NAS 物理存储目录，支持即点即读与离线缓存\n'
              '• 基于 LWW 策略的云端进度与书签跨设备毫秒级同步\n'
              '• 原生跟手滑动翻页与手势热区定制',
              style: TextStyle(
                  fontSize: 12, color: Colors.grey.shade700, height: 1.4),
            ),
            const SizedBox(height: 12),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('版本',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                Text(
                  _versionStr.isEmpty ? '读取中...' : _versionStr,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ApiConfig.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text('系统设置'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新计算缓存',
            onPressed: calculateCacheSize,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: calculateCacheSize,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 8),

            // 1. 账号中心入口
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('账号与服务',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.grey)),
            ),
            ListTile(
              leading: CircleAvatar(
                radius: 18,
                backgroundColor: const Color(0xFF5A4A3A),
                child: Text(
                  (user?.username.isNotEmpty ?? false)
                      ? user!.username[0].toUpperCase()
                      : 'U',
                  style: const TextStyle(
                      fontSize: 14,
                      color: Colors.white,
                      fontWeight: FontWeight.bold),
                ),
              ),
              title: const Text('账号中心'),
              subtitle: Text(
                ApiConfig.isLoggedIn
                    ? (user?.nickname?.isNotEmpty == true
                        ? user!.nickname!
                        : (user?.username ?? '已登录'))
                    : '未登录',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const AccountCenterPage(),
                  ),
                );
              },
            ),
            const Divider(),

            // 2. 外观与主题（直接与 ThemeManager.themeModeNotifier 联动）
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('外观与主题',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.grey)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: ValueListenableBuilder<ThemeMode>(
                valueListenable: ThemeManager.themeModeNotifier,
                builder: (context, currentMode, _) {
                  return SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment<ThemeMode>(
                        value: ThemeMode.system,
                        label: Text('跟随系统'),
                        icon: Icon(Icons.brightness_auto),
                      ),
                      ButtonSegment<ThemeMode>(
                        value: ThemeMode.light,
                        label: Text('浅色'),
                        icon: Icon(Icons.light_mode),
                      ),
                      ButtonSegment<ThemeMode>(
                        value: ThemeMode.dark,
                        label: Text('深色'),
                        icon: Icon(Icons.dark_mode),
                      ),
                    ],
                    selected: {currentMode},
                    onSelectionChanged: (Set<ThemeMode> newSelection) {
                      // 触发全局 ThemeManager 更新并通知 main.dart 重绘
                      ThemeManager.updateTheme(newSelection.first);
                    },
                  );
                },
              ),
            ),
            const Divider(),

            // 3. 存储与诊断
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _handleSecretTap,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text('存储与诊断',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, color: Colors.grey)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.cleaning_services_outlined),
              title: const Text('清除本地缓存'),
              subtitle: Text('包含已下载书籍及网络临时文件 ($_cacheSizeStr)'),
              trailing: _isClearing
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right),
              onTap: _isClearing ? null : _clearCache,
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('垃圾箱'),
              subtitle: const Text('浏览已移动到 NAS 垃圾箱的书籍'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const TrashBinPage()),
              ),
            ),
            // 诊断日志含请求地址与错误详情，release 包需连点标题 5 次解锁
            if (kDebugMode || _diagnosticsUnlocked)
              ListTile(
                leading: const Icon(Icons.receipt_long_outlined),
                title: const Text('查看网络诊断日志'),
                subtitle: const Text('抓包与 API 调试'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => AppLogger.showLogModal(context),
              ),
            const Divider(),

            // 4. 关于
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('系统信息',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.grey)),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('关于'),
              subtitle: const Text('App 概述与版本信息'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _showAboutDialog,
            ),
            ListTile(
              leading: const Icon(Icons.system_update_outlined),
              title: const Text('检查更新'),
              subtitle: Text(
                _versionStr.isEmpty ? '获取 GitHub 最新发布版本' : '当前版本 $_versionStr',
              ),
              trailing: _isCheckingUpdate
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right),
              onTap: _isCheckingUpdate ? null : _checkUpdate,
            ),
          ],
        ),
      ),
    );
  }
}

/// 账号信息二级页面（包含退出登录）
class AccountCenterPage extends StatefulWidget {
  const AccountCenterPage({super.key});

  @override
  State<AccountCenterPage> createState() => _AccountCenterPageState();
}

class _AccountCenterPageState extends State<AccountCenterPage> {
  ServerEndpoints _endpoints = const ServerEndpoints();

  @override
  void initState() {
    super.initState();
    _loadEndpoints();
  }

  Future<void> _loadEndpoints() async {
    final endpoints = await ServerEndpointService.load();
    if (!mounted) return;
    setState(() => _endpoints = endpoints);
  }

  Future<void> _handleLogout(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出当前账号并返回登录页吗？退出后将无法自动同步阅读进度。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    await _performLogout(context);
  }

  /// 清理本地凭证并回到登录页（退出登录与修改密码共用）
  static Future<void> _performLogout(BuildContext context) async {
    try {
      await ApiConfig.onLogout();
      await AuthService.clearAuth();
      // 收藏夹按账号维度同步，登出后必须清本地副本防止账号间串数据
      await FavoriteService.clearLocal();

      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('jwt_token');
      await prefs.remove('token');
      await prefs.remove('is_logged_in');
    } catch (e) {
      AppLogger.log('❌ 清理 Token 异常: $e');
    }

    if (!context.mounted) return;

    Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 150),
        pageBuilder: (context, animation, secondaryAnimation) =>
            const LoginPage(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      ),
      (route) => false,
    );
  }

  Future<void> _openServerEditor() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const ServerEndpointEditorPage()),
    );

    if (changed != true) return;
    await _loadEndpoints();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _openChangePassword(BuildContext context) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const ChangePasswordPage()),
    );

    if (changed != true || !context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('密码已修改，请使用新密码重新登录')),
    );
    await _performLogout(context);
  }

  @override
  Widget build(BuildContext context) {
    final user = ApiConfig.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text('账号中心'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            elevation: 0,
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: 0.4),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 32,
                    backgroundColor: const Color(0xFF5A4A3A),
                    child: Text(
                      (user?.username.isNotEmpty ?? false)
                          ? user!.username[0].toUpperCase()
                          : 'U',
                      style: const TextStyle(
                          fontSize: 24,
                          color: Colors.white,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user?.nickname?.isNotEmpty == true
                              ? user!.nickname!
                              : (user?.username ?? '未登录'),
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '用户 ID: ${user?.id ?? "未知"}',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600),
                        ),
                        if (user?.email != null && user!.email!.isNotEmpty)
                          Text(
                            user.email!,
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade600),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text('服务状态',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey)),
          const SizedBox(height: 8),
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: Colors.grey.shade300),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.cloud_outlined,
                      color: Colors.blueAccent),
                  title: const Text('局域网服务器', style: TextStyle(fontSize: 14)),
                  subtitle: Text(
                    ApiConfig.baseUrl.isNotEmpty ? ApiConfig.baseUrl : '未配置',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: const Text('直连',
                      style:
                          TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ),
                const Divider(height: 1),
                ListTile(
                  leading:
                      const Icon(Icons.dns_outlined, color: Color(0xFF5A4A3A)),
                  title: const Text('服务器地址配置', style: TextStyle(fontSize: 14)),
                  subtitle: Text(
                    '局域网：${_endpoints.primary.isNotEmpty ? _endpoints.primary : "未配置"}\n'
                    'Tailnet：${_endpoints.hasTailnetTarget ? _endpoints.tailnetTarget : "未配置"}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _openServerEditor,
                ),
                const Divider(height: 1),
                ListTile(
                  leading:
                      const Icon(Icons.sync_lock_outlined, color: Colors.green),
                  title: const Text('多端同步状态', style: TextStyle(fontSize: 14)),
                  trailing: Text(
                    ApiConfig.isLoggedIn ? '已连接' : '未授权',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: ApiConfig.isLoggedIn
                          ? Colors.green
                          : Colors.redAccent,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const Text('安全设置',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey)),
          const SizedBox(height: 8),
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: Colors.grey.shade300),
            ),
            child: ListTile(
              leading:
                  const Icon(Icons.password_outlined, color: Color(0xFF5A4A3A)),
              title: const Text('修改登录密码', style: TextStyle(fontSize: 14)),
              subtitle:
                  const Text('修改成功后需重新登录', style: TextStyle(fontSize: 12)),
              trailing: const Icon(Icons.chevron_right),
              enabled: ApiConfig.isLoggedIn,
              onTap: ApiConfig.isLoggedIn
                  ? () => _openChangePassword(context)
                  : null,
            ),
          ),
          const SizedBox(height: 32),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              foregroundColor: Colors.redAccent,
              backgroundColor: Colors.redAccent.withValues(alpha: 0.1),
            ),
            onPressed: () => _handleLogout(context),
            child: const Text('退出登录',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}

/// 局域网服务器及可选 Tailnet 目标编辑页。
class ServerEndpointEditorPage extends StatefulWidget {
  const ServerEndpointEditorPage({super.key});

  @override
  State<ServerEndpointEditorPage> createState() =>
      _ServerEndpointEditorPageState();
}

class _ServerEndpointEditorPageState extends State<ServerEndpointEditorPage> {
  final _formKey = GlobalKey<FormState>();
  final _primaryController = TextEditingController();
  final _tailnetTargetController = TextEditingController();

  bool _isLoading = true;
  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final endpoints = await ServerEndpointService.load();
    if (!mounted) return;
    setState(() {
      _primaryController.text =
          endpoints.primary.isNotEmpty ? endpoints.primary : ApiConfig.baseUrl;
      _tailnetTargetController.text = endpoints.tailnetTarget;
      _isLoading = false;
    });
  }

  @override
  void dispose() {
    _primaryController.dispose();
    _tailnetTargetController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    final primary = ServerProfileService.normalizeUrl(_primaryController.text);
    final tailnetTarget = ServerEndpointService.normalizeTailnetTarget(
      _tailnetTargetController.text,
    );

    try {
      await ServerEndpointService.save(
        primary: primary,
        tailnetTarget: tailnetTarget,
      );

      // 地址变更后必须重建 Dio，否则旧 baseUrl 会被单例继续复用
      NetworkClient.reset();
      await ApiConfig.setBaseUrl(primary);
      await AuthService.saveBaseUrl(primary);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('服务器地址已保存'),
        ),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = '保存失败: $e');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  String? _validateUrl(String? value, {required bool required}) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return required ? '请输入服务器地址' : null;

    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return '请输入完整地址，例如 http://nas:6088';
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return '仅支持 http 或 https';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('服务器地址')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      controller: _primaryController,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: '局域网服务器地址',
                        prefixIcon: Icon(Icons.dns_outlined),
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) => _validateUrl(v, required: true),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _tailnetTargetController,
                      decoration: const InputDecoration(
                        labelText: 'Tailnet 目标（可选）',
                        helperText:
                            '局域网连接失败时通过 Tailnet 访问，例如 nas.example.ts.net:6088',
                        prefixIcon: Icon(Icons.vpn_lock_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _errorMessage!,
                        style: const TextStyle(color: Colors.red, fontSize: 13),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _isSubmitting ? null : _submit,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        backgroundColor: const Color(0xFF382E25),
                      ),
                      child: _isSubmitting
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('检测并保存'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// 修改登录密码页面：成功后由调用方触发登出
class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key});

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _oldController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _isSubmitting = false;
  String? _errorMessage;

  @override
  void dispose() {
    _oldController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSubmitting = true;
      _errorMessage = null;
    });

    try {
      final dio = NetworkClient.getDio();
      await dio.post(
        '/api/v1/auth/password',
        data: {
          'oldPassword': _oldController.text,
          'newPassword': _newController.text,
        },
      );

      // 旧密码已失效，清掉本地记住的密码避免自动填充错误凭证
      await ServerProfileService.clearPassword(ApiConfig.baseUrl);

      if (!mounted) return;
      Navigator.pop(context, true);
    } on DioException catch (e) {
      final data = e.response?.data;
      var msg = '修改失败，请稍后重试';
      if (data is Map) {
        msg = (data['error'] ?? data['message'] ?? msg).toString();
      } else if (e.response == null) {
        msg = '网络连接失败，请检查服务器地址';
      }
      if (!mounted) return;
      setState(() => _errorMessage = msg);
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = '发生错误: $e');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('修改密码')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _oldController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '当前密码',
                  prefixIcon: Icon(Icons.lock_outline),
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v == null || v.length < 6) ? '请输入当前密码' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _newController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '新密码',
                  helperText: '至少 8 位',
                  prefixIcon: Icon(Icons.lock_reset_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  if (v == null || v.length < 8) return '新密码长度至少 8 位';
                  if (v == _oldController.text) return '新密码不能与当前密码相同';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _confirmController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '确认新密码',
                  prefixIcon: Icon(Icons.check_circle_outline),
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    v != _newController.text ? '两次输入的新密码不一致' : null,
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 16),
                Text(
                  _errorMessage!,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 28),
              FilledButton(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: const Color(0xFF382E25),
                ),
                onPressed: _isSubmitting ? null : _submit,
                child: _isSubmitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('确认修改', style: TextStyle(fontSize: 16)),
              ),
              const SizedBox(height: 12),
              const Text(
                '修改成功后将立即退出登录，请使用新密码重新登录。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
