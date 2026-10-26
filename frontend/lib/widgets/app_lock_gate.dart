// lib/widgets/app_lock_gate.dart
import 'package:flutter/material.dart';

import '../services/app_lock_service.dart';
import '../pages/app_lock_page.dart';

/// 应用锁定门：包裹在 MaterialApp.builder 最外层。
/// 应用锁定开启时，冷启动或从后台返回会以覆盖层形式展示验证页，
/// 验证通过前无法与底层页面交互。
class AppLockGate extends StatefulWidget {
  final Widget? child;

  const AppLockGate({super.key, required this.child});

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 冷启动即处于待验证状态
    AppLockService.lock();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 仅在应用完全退到后台时上锁，系统弹窗等 inactive 场景不触发
    if (state == AppLifecycleState.paused) {
      AppLockService.lock();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AppLockService.lockedNotifier,
      builder: (context, locked, _) {
        return Stack(
          children: [
            if (widget.child != null) widget.child!,
            if (locked && AppLockService.isConfigured)
              const Positioned.fill(child: AppLockVerifyPage()),
          ],
        );
      },
    );
  }
}
