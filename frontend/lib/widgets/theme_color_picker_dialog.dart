// lib/widgets/theme_color_picker_dialog.dart
import 'package:flutter/material.dart';

/// 阅读主题长按后打开的调色盘对话框。
/// 拖动取色光标可实时预览颜色：
/// * [onConfirm]：点击“确定”回调，携带所选颜色；
/// * [onReset]：点击“重置”回调，用于还原主题默认文字颜色；
/// * 点击“取消”或对话框外部直接关闭，不产生任何变更。
class ThemeColorPickerDialog extends StatefulWidget {
  final String themeName;

  /// 主题默认文字颜色，作为重置参照与无自定义色时的初始光标颜色
  final Color defaultColor;

  /// 当前已保存的自定义颜色，无则为 null
  final Color? customColor;

  final ValueChanged<Color> onConfirm;
  final VoidCallback onReset;

  const ThemeColorPickerDialog({
    super.key,
    required this.themeName,
    required this.defaultColor,
    required this.customColor,
    required this.onConfirm,
    required this.onReset,
  });

  /// 便捷打开入口
  static void show(
    BuildContext context, {
    required String themeName,
    required Color defaultColor,
    required Color? customColor,
    required ValueChanged<Color> onConfirm,
    required VoidCallback onReset,
  }) {
    showDialog(
      context: context,
      builder: (_) => ThemeColorPickerDialog(
        themeName: themeName,
        defaultColor: defaultColor,
        customColor: customColor,
        onConfirm: onConfirm,
        onReset: onReset,
      ),
    );
  }

  @override
  State<ThemeColorPickerDialog> createState() => _ThemeColorPickerDialogState();
}

class _ThemeColorPickerDialogState extends State<ThemeColorPickerDialog> {
  late HSVColor _hsv;

  @override
  void initState() {
    super.initState();
    // 有自定义颜色则从自定义色起步，否则用主题默认色
    _hsv = HSVColor.fromColor(widget.customColor ?? widget.defaultColor);
  }

  Color get _currentColor => _hsv.toColor();

  String get _hexLabel {
    final argb = _currentColor.toARGB32().toRadixString(16).toUpperCase();
    return '#${argb.substring(2).padLeft(6, '0')}';
  }

  // ---- 操作按钮 ----

  void _confirm() {
    Navigator.of(context).pop();
    widget.onConfirm(_currentColor);
  }

  void _reset() {
    Navigator.of(context).pop();
    widget.onReset();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF2B2B2B),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 标题 + 当前颜色值
            Row(
              children: [
                Expanded(
                  child: Text(
                    '调色盘 · ${widget.themeName}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(_hexLabel,
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 12),
            _buildPreview(),
            const SizedBox(height: 12),
            _buildPalette(),
            const SizedBox(height: 12),
            _buildHueBar(),
            const SizedBox(height: 14),
            _buildActions(),
          ],
        ),
      ),
    );
  }

  // 颜色实时预览：固定白底，保证所选文字颜色总是可见
  Widget _buildPreview() {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white24),
      ),
      alignment: Alignment.center,
      child: Text(
        '预览文字 0123 阅读主题',
        style: TextStyle(
          color: _currentColor,
          fontSize: 13,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  // 饱和度/明度取色平面，拖动圆环光标取色
  Widget _buildPalette() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const areaHeight = 140.0;

          void pick(Offset localPosition) {
            final s =
                (localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
            final v = 1.0 - (localPosition.dy / areaHeight).clamp(0.0, 1.0);
            setState(() => _hsv = _hsv.withSaturation(s).withValue(v));
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => pick(d.localPosition),
            onTapMove: (d) => pick(d.localPosition),
            onPanStart: (d) => pick(d.localPosition),
            onPanUpdate: (d) => pick(d.localPosition),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                SizedBox(
                  width: constraints.maxWidth,
                  height: areaHeight,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 底层：当前色相的纯色
                      ColoredBox(
                        color: HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor(),
                      ),
                      // 横向：白 -> 透明（饱和度从左到右递增）
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [Colors.white, Color(0x00FFFFFF)],
                          ),
                        ),
                      ),
                      // 纵向：透明 -> 黑（明度从上到下递减）
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0x00000000), Colors.black],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // 取色光标
                Positioned(
                  left: _hsv.saturation * constraints.maxWidth - 10,
                  top: (1 - _hsv.value) * areaHeight - 10,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                      boxShadow: const [
                        BoxShadow(color: Colors.black38, blurRadius: 2),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // 色相条，拖动竖条光标改变色相
  Widget _buildHueBar() {
    return LayoutBuilder(
      builder: (context, constraints) {
        void pick(Offset localPosition) {
          final t = localPosition.dx / constraints.maxWidth;
          setState(() => _hsv = _hsv.withHue((t * 360).clamp(0.0, 360.0)));
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => pick(d.localPosition),
          onTapMove: (d) => pick(d.localPosition),
          onPanStart: (d) => pick(d.localPosition),
          onPanUpdate: (d) => pick(d.localPosition),
          child: SizedBox(
            height: 28,
            child: Stack(
              alignment: Alignment.center,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: const SizedBox(
                    width: double.infinity,
                    height: 28,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Color(0xFFFF0000),
                            Color(0xFFFFFF00),
                            Color(0xFF00FF00),
                            Color(0xFF00FFFF),
                            Color(0xFF0000FF),
                            Color(0xFFFF00FF),
                            Color(0xFFFF0000),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                // 色相光标
                Align(
                  alignment: Alignment(_hsv.hue / 180 - 1, 0),
                  child: Container(
                    width: 8,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: Colors.black54),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // 重置 / 取消 / 确定
  Widget _buildActions() {
    return Row(
      children: [
        TextButton(
          onPressed: _reset,
          style: TextButton.styleFrom(foregroundColor: Colors.orangeAccent),
          child: const Text('重置', style: TextStyle(fontSize: 13)),
        ),
        const Spacer(),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          style: TextButton.styleFrom(foregroundColor: Colors.white70),
          child: const Text('取消', style: TextStyle(fontSize: 13)),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _confirm,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF8D7358),
            foregroundColor: Colors.white,
            minimumSize: const Size(64, 36),
          ),
          child: const Text('确定', style: TextStyle(fontSize: 13)),
        ),
      ],
    );
  }
}
