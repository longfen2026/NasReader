// lib/pages/app_lock_page.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_lock_service.dart';

/// 应用锁定设置二级页面：开关 + 锁定方式选择
class AppLockSettingsPage extends StatefulWidget {
  const AppLockSettingsPage({super.key});

  @override
  State<AppLockSettingsPage> createState() => _AppLockSettingsPageState();
}

class _AppLockSettingsPageState extends State<AppLockSettingsPage> {
  bool _biometricSupported = false;
  bool _isCheckingBiometric = true;

  @override
  void initState() {
    super.initState();
    _checkBiometricSupport();
  }

  /// 指纹识别依赖系统生物特征能力，不支持时隐藏该选项
  Future<void> _checkBiometricSupport() async {
    final supported = await AppLockService.isBiometricSupported();
    if (!mounted) return;
    setState(() {
      _biometricSupported = supported;
      _isCheckingBiometric = false;
    });
  }

  Future<void> _handleEnableChanged(bool enable) async {
    if (!enable) {
      await AppLockService.setEnabled(false);
      if (mounted) setState(() {});
      return;
    }

    // 首次开启必须先完成一种验证方式的配置，取消则视为未开启
    if (!AppLockService.isConfigured) {
      final configured = await _configureMethod();
      if (!configured) return;
    }

    await AppLockService.setEnabled(true);
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('应用锁定已开启，打开 App 或从后台返回时需要验证'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// 选择并配置锁定方式，返回是否配置成功
  Future<bool> _configureMethod() async {
    final method = await _showMethodPicker();
    if (method == null || !mounted) return false;

    if (method == AppLockMethod.pin) {
      final pin = await Navigator.push<String>(
        context,
        MaterialPageRoute(builder: (_) => const PinSetupPage()),
      );
      if (pin == null) return false;
      await AppLockService.setMethod(AppLockMethod.pin);
    } else {
      // 指纹方式开启前先完成一次认证，确认系统可正常调用
      final passed = await AppLockService.authenticateWithBiometrics(
        '请验证指纹以开启应用锁定',
      );
      if (!mounted) return false;
      if (!passed) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('指纹验证未通过，未开启指纹锁定'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return false;
      }
      await AppLockService.setMethod(AppLockMethod.biometric);
    }

    if (mounted) setState(() {});
    return true;
  }

  Future<AppLockMethod?> _showMethodPicker() {
    return showModalBottomSheet<AppLockMethod>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('选择锁定方式',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              ListTile(
                leading: const Icon(Icons.pin_outlined),
                title: const Text('数字密码'),
                subtitle: const Text('4 位数字密码'),
                onTap: () => Navigator.pop(sheetContext, AppLockMethod.pin),
              ),
              ListTile(
                leading: const Icon(Icons.fingerprint),
                title: Text(
                  '指纹识别',
                  style: _biometricSupported
                      ? null
                      : const TextStyle(color: Colors.grey),
                ),
                subtitle: Text(
                  _biometricSupported ? '使用系统指纹验证' : '当前设备不支持指纹识别',
                ),
                onTap: _biometricSupported
                    ? () => Navigator.pop(sheetContext, AppLockMethod.biometric)
                    : null,
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled = AppLockService.enabled;
    final method = AppLockService.method;

    return Scaffold(
      appBar: AppBar(title: const Text('应用锁定')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: Colors.grey.shade300),
            ),
            child: SwitchListTile(
              secondary: Icon(
                Icons.lock_outline,
                color: enabled ? Theme.of(context).colorScheme.primary : Colors.grey,
              ),
              title: const Text('启用应用锁定'),
              subtitle: const Text('打开 App 或从后台返回时需要验证'),
              value: enabled,
              onChanged: _handleEnableChanged,
            ),
          ),
          if (enabled) ...[
            const SizedBox(height: 20),
            const Text('锁定方式',
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
                    leading: const Icon(Icons.pin_outlined),
                    title: const Text('数字密码'),
                    subtitle: const Text('4 位数字密码'),
                    trailing: method == AppLockMethod.pin
                        ? Icon(Icons.check,
                            color: Theme.of(context).colorScheme.primary)
                        : const Icon(Icons.chevron_right),
                    onTap: () async {
                      final pin = await Navigator.push<String>(
                        context,
                        MaterialPageRoute(builder: (_) => const PinSetupPage()),
                      );
                      if (pin == null || !mounted) return;
                      await AppLockService.setMethod(AppLockMethod.pin);
                      if (mounted) setState(() {});
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.fingerprint),
                    title: Text(
                      '指纹识别',
                      style: _biometricSupported
                          ? null
                          : const TextStyle(color: Colors.grey),
                    ),
                    subtitle: Text(
                      _isCheckingBiometric
                          ? '正在检测设备支持情况'
                          : _biometricSupported
                              ? '使用系统指纹验证'
                              : '当前设备不支持指纹识别',
                    ),
                    trailing: method == AppLockMethod.biometric
                        ? Icon(Icons.check,
                            color: Theme.of(context).colorScheme.primary)
                        : _biometricSupported
                            ? const Icon(Icons.chevron_right)
                            : null,
                    onTap: _biometricSupported
                        ? () async {
                            final passed =
                                await AppLockService.authenticateWithBiometrics(
                                    '请验证指纹以切换到指纹锁定');
                            if (!mounted) return;
                            if (!passed) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('指纹验证未通过，锁定方式未变更'),
                                  behavior: SnackBarBehavior.floating,
                                ),
                              );
                              return;
                            }
                            await AppLockService.setMethod(
                                AppLockMethod.biometric);
                            if (mounted) setState(() {});
                          }
                        : null,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 4 位数字密码设置页：输入 + 确认，成功后返回密码给调用方
class PinSetupPage extends StatefulWidget {
  const PinSetupPage({super.key});

  @override
  State<PinSetupPage> createState() => _PinSetupPageState();
}

class _PinSetupPageState extends State<PinSetupPage> {
  final _firstController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _isConfirmStep = false;
  String? _errorMessage;

  @override
  void dispose() {
    _firstController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _onSubmitted() {
    final value = _isConfirmStep ? _confirmController.text : _firstController.text;

    if (value.length != 4) {
      setState(() => _errorMessage = '请输入 4 位数字密码');
      return;
    }

    if (!_isConfirmStep) {
      setState(() {
        _isConfirmStep = true;
        _errorMessage = null;
      });
      return;
    }

    if (value != _firstController.text) {
      setState(() {
        _errorMessage = '两次输入的密码不一致，请重新输入';
        _isConfirmStep = false;
        _firstController.clear();
        _confirmController.clear();
      });
      return;
    }

    AppLockService.savePin(value);
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置数字密码')),
      body: SafeArea(
        child: AutofillGroup(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                _isConfirmStep ? '请再次输入密码确认' : '请输入 4 位数字密码',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _isConfirmStep ? _confirmController : _firstController,
                autofocus: true,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 4,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: _isConfirmStep ? '确认密码' : '数字密码',
                  prefixIcon: const Icon(Icons.password_outlined),
                  border: const OutlineInputBorder(),
                  counterText: '',
                ),
                onSubmitted: (_) => _onSubmitted(),
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 8),
                Text(
                  _errorMessage!,
                  style: const TextStyle(color: Colors.red, fontSize: 13),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: Theme.of(context).colorScheme.primary,
                ),
                onPressed: _onSubmitted,
                child: Text(_isConfirmStep ? '确认' : '下一步'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 锁定验证页：以覆盖层形式盖在所有页面之上，验证通过后自动消失
class AppLockVerifyPage extends StatefulWidget {
  const AppLockVerifyPage({super.key});

  @override
  State<AppLockVerifyPage> createState() => _AppLockVerifyPageState();
}

class _AppLockVerifyPageState extends State<AppLockVerifyPage> {
  String _input = '';
  bool _isError = false;
  bool _isBiometricPrompting = false;

  /// 指纹方式下是否改用密码输入（存在历史密码时作为兜底入口）
  bool _usePinEntry = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startBiometricAuthIfNeeded(auto: true);
    });
  }

  Future<void> _startBiometricAuthIfNeeded({bool auto = false}) async {
    if (AppLockService.method != AppLockMethod.biometric) return;
    if (_usePinEntry) return;
    if (_isBiometricPrompting) return;

    _isBiometricPrompting = true;
    final passed = await AppLockService.authenticateWithBiometrics(
      '请验证指纹以进入应用',
    );
    _isBiometricPrompting = false;
    if (!mounted) return;

    if (passed) {
      AppLockService.unlock();
    } else if (auto) {
      // 自动唤起的认证被取消时，静默等待用户手动点击重试，不弹错误
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('指纹验证未通过，请重试'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _onKeyTap(String digit) {
    if (_isError) {
      _input = '';
      _isError = false;
    }
    if (_input.length >= 4) return;

    setState(() => _input += digit);
    if (_input.length == 4) {
      Future.delayed(const Duration(milliseconds: 120), _verifyPin);
    }
  }

  void _onBackspace() {
    if (_input.isEmpty) return;
    setState(() => _input = _input.substring(0, _input.length - 1));
  }

  Future<void> _verifyPin() async {
    if (AppLockService.verifyPin(_input)) {
      AppLockService.unlock();
      return;
    }

    if (!mounted) return;
    HapticFeedback.heavyImpact();
    setState(() {
      _isError = true;
    });
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) {
        setState(() {
          _input = '';
          _isError = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final method = AppLockService.method;
    final showBiometric = method == AppLockMethod.biometric && !_usePinEntry;
    final theme = Theme.of(context);

    return PopScope(
      canPop: false,
      child: Material(
        color: theme.colorScheme.surface,
        child: SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.lock_outline,
                size: 48,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 12),
              const Text(
                '应用已锁定',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                showBiometric ? '请验证指纹以继续' : '请输入 4 位数字密码',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 24),

              if (showBiometric) ...[
                IconButton(
                  iconSize: 72,
                  icon: Icon(
                    Icons.fingerprint,
                    color: theme.colorScheme.primary,
                  ),
                  tooltip: '指纹解锁',
                  onPressed: () => _startBiometricAuthIfNeeded(),
                ),
                if (AppLockService.hasPin) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => setState(() => _usePinEntry = true),
                    child: const Text('使用密码解锁'),
                  ),
                ],
              ] else ...[
                // 4 位密码指示点
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < 4; i++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        margin: const EdgeInsets.symmetric(horizontal: 10),
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _isError
                              ? theme.colorScheme.error
                              : i < _input.length
                                  ? theme.colorScheme.primary
                                  : Colors.grey.shade400,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_isError)
                  const Text(
                    '密码错误，请重试',
                    style: TextStyle(color: Colors.red, fontSize: 13),
                  ),
                const SizedBox(height: 12),
                _buildPinPad(theme),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPinPad(ThemeData theme) {
    const keys = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['', '0', 'del'],
    ];

    return SizedBox(
      width: 260,
      child: Column(
        children: [
          for (final row in keys)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final key in row)
                  Padding(
                    padding: const EdgeInsets.all(6),
                    child: _buildKey(theme, key),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildKey(ThemeData theme, String key) {
    if (key.isEmpty) return const SizedBox(width: 68, height: 56);

    return SizedBox(
      width: 68,
      height: 56,
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => key == 'del' ? _onBackspace() : _onKeyTap(key),
          child: Center(
            child: key == 'del'
                ? const Icon(Icons.backspace_outlined)
                : Text(
                    key,
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w500),
                  ),
          ),
        ),
      ),
    );
  }
}
