import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_reader/services/bookmark_sync_service.dart';
import 'package:nas_reader/widgets/reader_drawer.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/full_txt_engine.dart';
import '../core/reader_theme.dart';
import '../core/page_turn_view.dart';
import '../widgets/eye_care_config.dart';
import '../widgets/eye_care_controls.dart';
import '../widgets/theme_color_picker_dialog.dart';
import '../widgets/typography_config.dart';
import '../widgets/typography_settings_modal.dart';
import '../services/app_logger.dart';
import '../services/eye_care_prefs.dart';
import '../services/reader_theme_prefs.dart';
import '../services/typography_prefs.dart';
import '../models/bookmark_model.dart';

enum HandMode {
  standard('常规手势'),
  oneHand('单手模式');

  final String label;
  const HandMode(this.label);
}

class StreamTxtReaderPage extends StatefulWidget {
  final File file;
  final String bookId;
  final String title;
  final int initialByteOffset;
  final Function(int byteOffset, double progressPercent)? onProgressChanged;

  const StreamTxtReaderPage({
    super.key,
    required this.file,
    required this.bookId,
    required this.title,
    this.initialByteOffset = 0,
    this.onProgressChanged,
  });

  @override
  State<StreamTxtReaderPage> createState() => _StreamTxtReaderPageState();
}

class _StreamTxtReaderPageState extends State<StreamTxtReaderPage>
    with WidgetsBindingObserver {
  bool _isLoading = true;
  String? _errorMessage;
  bool _showControls = false;

  List<FullTxtPageSlice> _pages = [];
  List<FullTxtChapterItem> _toc = [];
  int _totalFileSize = 1;
  List<Bookmark> _bookmarks = [];

  int _currentPageIndex = 0;
  int _currentChapterIndex = 0;
  int _lastReportedOffset = -1;
  bool _isTurningPage = false; // 防抖锁状态标记

  ReaderThemeData _currentTheme = ReaderThemes.parchment;
  // 各主题的自定义文字颜色（name -> ARGB int），与主题绑定持久化
  Map<String, int> _customTextColors = {};
  HandMode _handMode = HandMode.standard;
  TypographyConfig _typoConfig = const TypographyConfig();
  EyeCareConfig _eyeCare = const EyeCareConfig();

  FullTxtContentLoader? _contentLoader;
  FullTxtLayoutMetrics? _lastMetrics;
  int _paginationGeneration = 0;
  Timer? _repaginateDebounce;

  final GlobalKey<PageTurnViewState> _turnViewKey = GlobalKey<PageTurnViewState>();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  static const double kHorizontalPadding = 20.0;
  static const double kVerticalPadding = 12.0;
  static const double kHeaderHeight = 22.0;
  static const double kFooterHeight = 22.0;
  static const double kHeaderSpacing = 8.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _loadHandMode();
    _loadEyeCare();
    _loadReaderTheme();
    _loadCustomTextColors();
    _loadBookmarks();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _loadEyeCare() async {
    final saved = await EyeCarePrefs.load();
    if (!mounted || saved == _eyeCare) return;
    setState(() => _eyeCare = saved);
  }

  void _updateEyeCare(EyeCareConfig config) {
    if (config == _eyeCare) return;
    setState(() => _eyeCare = config);
    EyeCarePrefs.save(config);
  }

  Future<void> _loadReaderTheme() async {
    final saved = await ReaderThemePrefs.load();
    if (!mounted || saved.name == _currentTheme.name) return;
    setState(() => _currentTheme = saved);
  }

  Future<void> _loadCustomTextColors() async {
    final saved = await ReaderThemePrefs.loadCustomTextColors();
    if (!mounted || saved.isEmpty) return;
    setState(() => _customTextColors = saved);
  }

  /// 当前主题实际生效的文字颜色：有自定义颜色优先，否则用默认色
  Color get _effectiveTextColor =>
      ReaderThemePrefs.effectiveTextColor(_currentTheme, _customTextColors);

  /// 长按主题打开调色盘，自定义该主题的文字颜色
  void _openColorPicker(ReaderThemeData theme) {
    final savedValue = _customTextColors[theme.name];
    ThemeColorPickerDialog.show(
      context,
      themeName: theme.name,
      defaultColor: theme.textColor,
      customColor: savedValue != null ? Color(savedValue) : null,
      onConfirm: (color) async {
        setState(() => _customTextColors[theme.name] = color.toARGB32());
        await ReaderThemePrefs.saveCustomTextColor(theme.name, color);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('已自定义主题文字颜色'),
                duration: Duration(milliseconds: 1000)),
          );
        }
      },
      onReset: () async {
        setState(() => _customTextColors.remove(theme.name));
        await ReaderThemePrefs.clearCustomTextColor(theme.name);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('已还原主题默认文字颜色'),
                duration: Duration(milliseconds: 1000)),
          );
        }
      },
    );
  }

  void _updateReaderTheme(ReaderThemeData theme) {
    if (theme.name == _currentTheme.name) return;
    setState(() => _currentTheme = theme);
    ReaderThemePrefs.save(theme);
  }

  Future<void> _bootstrap() async {
    // 先取回持久化排版，避免用默认值白排一遍
    final saved = await TypographyPrefs.load();
    if (!mounted) return;
    if (saved != _typoConfig) {
      setState(() => _typoConfig = saved);
    }
    await _paginateEntireBook();
  }

  @override
  void dispose() {
    _saveCurrentProgress();
    _repaginateDebounce?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _contentLoader?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (!mounted || _isLoading || _pages.isEmpty) return;
    _scheduleRepaginate(delay: const Duration(milliseconds: 350), onlyIfMetricsChanged: true);
  }

  void _scheduleRepaginate({
    Duration delay = const Duration(milliseconds: 250),
    bool onlyIfMetricsChanged = false,
  }) {
    _repaginateDebounce?.cancel();
    _repaginateDebounce = Timer(delay, () {
      if (!mounted) return;
      if (onlyIfMetricsChanged && _buildMetrics() == _lastMetrics) return;
      final offset =
          _pages.isNotEmpty && _currentPageIndex < _pages.length
              ? _pages[_currentPageIndex].startByteOffset
              : 0;
      _paginateEntireBook(targetByteOffset: offset);
    });
  }

  Future<void> _loadHandMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedMode = prefs.getString('txt_hand_mode');
      if (savedMode == HandMode.oneHand.name && mounted) {
        setState(() => _handMode = HandMode.oneHand);
      }
    } catch (e) {
      AppLogger.log('⚠️ TXT 手势模式读取失败: $e');
    }
  }

  Future<void> _saveHandMode(HandMode mode) async {
    setState(() => _handMode = mode);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('txt_hand_mode', mode.name);
    } catch (e) {
      AppLogger.log('⚠️ TXT 手势模式保存失败: $e');
    }
  }

  Future<void> _loadBookmarks() async {
    final list = await BookmarkSyncService.syncWithServer(widget.bookId);
    if (mounted) setState(() => _bookmarks = list);
  }

  // 添加当前页为书签
  Future<void> _toggleBookmark() async {
    if (_pages.isEmpty || _currentPageIndex >= _pages.length) return;
    final slice = _pages[_currentPageIndex];
    
    final chapterTitle = _toc.isNotEmpty && _currentChapterIndex < _toc.length
        ? _toc[_currentChapterIndex].title
        : '第 ${_currentPageIndex + 1} 页';
        
    final snippet = _contentOf(slice).replaceAll('\n', ' ').trim();
    final displaySnippet = snippet.length > 60 ? '${snippet.substring(0, 60)}...' : snippet;
    final now = DateTime.now().millisecondsSinceEpoch;

    final bookmark = Bookmark(
      id: '${widget.bookId}_${slice.startByteOffset}',
      bookId: widget.bookId,
      title: chapterTitle,
      snippet: displaySnippet,
      progressPercent: (slice.endByteOffset / _totalFileSize).clamp(0.0, 1.0),
      byteOffset: slice.startByteOffset,
      createdAt: now,
      updatedAt: now,
    );

    await BookmarkSyncService.saveBookmark(bookmark);
    await _loadBookmarks();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已添加书签并同步'), duration: Duration(milliseconds: 1200)),
      );
    }
  }

  // 点击书签跳转
  void _jumpToBookmark(Bookmark b) {
    Navigator.pop(context);
    if (b.byteOffset == null || _pages.isEmpty) return;

    final target = _locatePageByByteOffset(_pages, b.byteOffset!);
    setState(() {
      _currentPageIndex = target;
      _showControls = false;
    });
    _turnViewKey.currentState?.jumpToPage(target);
    _saveCurrentProgress();
  }

  /// 取最后一个起始偏移不超过目标值的页，避免落回更早的页
  static int _locatePageByByteOffset(List<FullTxtPageSlice> pages, int byteOffset) {
    if (pages.isEmpty || byteOffset <= 0) return 0;
    int target = 0;
    for (int i = 0; i < pages.length; i++) {
      if (pages[i].startByteOffset <= byteOffset) {
        target = i;
      } else {
        break;
      }
    }
    return target;
  }

  Size _getContentSize() {
    final mq = MediaQuery.of(context);
    final availableWidth = mq.size.width - (kHorizontalPadding * 2);
    final availableHeight = mq.size.height -
        mq.padding.top -
        mq.padding.bottom -
        (kVerticalPadding * 2) -
        kHeaderHeight -
        kFooterHeight -
        kHeaderSpacing -
        16.0;

    return Size(
      availableWidth.clamp(100.0, 3000.0),
      availableHeight.clamp(100.0, 4000.0),
    );
  }

  /// 用 TextPainter 实测标定值，替代按等宽字符估算（compute isolate 内无法使用 TextPainter）
  FullTxtLayoutMetrics _buildMetrics() {
    final size = _getContentSize();
    final bodyStyle = TextStyle(
      fontSize: _typoConfig.fontSize,
      height: _typoConfig.lineHeight,
      letterSpacing: _typoConfig.letterSpacing,
      fontFamily: _typoConfig.customFontFamily,
    );
    final titleStyle = TextStyle(
      fontSize: _typoConfig.fontSize * 1.25,
      fontWeight: FontWeight.bold,
      height: 1.4,
      letterSpacing: _typoConfig.letterSpacing + 0.5,
      fontFamily: _typoConfig.customFontFamily,
    );

    final body = _measureStyle(bodyStyle);
    final title = _measureStyle(titleStyle);

    return FullTxtLayoutMetrics(
      contentWidth: size.width,
      contentHeight: size.height,
      bodyAsciiWidth: body.asciiWidth,
      bodyWideWidth: body.wideWidth,
      bodyLineHeight: body.lineHeight,
      titleAsciiWidth: title.asciiWidth,
      titleWideWidth: title.wideWidth,
      titleLineHeight: title.lineHeight,
      indentFirstLine: _typoConfig.indentFirstLine,
    );
  }

  _StyleMeasurement _measureStyle(TextStyle style) {
    double widthOf(String sample) {
      final painter = TextPainter(
        text: TextSpan(text: sample, style: style),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final width = painter.width / sample.length;
      painter.dispose();
      return width;
    }

    final probe = TextPainter(
      text: TextSpan(text: '中文Ag', style: style),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final lineHeight = probe.height;
    probe.dispose();

    return _StyleMeasurement(
      asciiWidth: widthOf('abcdefghijklmnopqrstuvwxyz0123456789'),
      wideWidth: widthOf('汉字测量样本中文排版宽度基准值参照'),
      lineHeight: lineHeight,
    );
  }

  String _contentOf(FullTxtPageSlice slice) =>
      _contentLoader?.contentOf(slice) ?? '';

  Future<void> _paginateEntireBook({int? targetByteOffset}) async {
    final generation = ++_paginationGeneration;
    final metrics = _buildMetrics();
    final offsetToLocate = targetByteOffset ?? widget.initialByteOffset;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final result = await FullTxtEngine.paginate(
        FullTxtPaginationParams(filePath: widget.file.path, metrics: metrics),
      );

      if (!mounted || generation != _paginationGeneration) return;

      final targetPage = _locatePageByByteOffset(result.pages, offsetToLocate);

      _contentLoader?.dispose();
      _contentLoader = FullTxtContentLoader(
        filePath: widget.file.path,
        encoding: result.encoding,
        metrics: metrics,
      );
      _lastMetrics = metrics;
      _lastReportedOffset = -1; // 重排后页边界变了，去重基准需要重置

      setState(() {
        _pages = result.pages;
        _toc = result.chapters;
        _totalFileSize = result.totalBytes > 0 ? result.totalBytes : 1;
        _currentPageIndex = targetPage;
        _isLoading = false;
        _errorMessage = null;
      });

      _updateCurrentChapterByPageIndex(targetPage);

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || generation != _paginationGeneration) return;
        _turnViewKey.currentState?.jumpToPage(targetPage);
        _saveCurrentProgress();
      });
    } on FullTxtEngineException catch (e) {
      AppLogger.log('❌ 全本排版失败: $e');
      if (!mounted || generation != _paginationGeneration) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e.userMessage;
      });
    } catch (e, stack) {
      AppLogger.log('❌ 全本排版异常: $e\n$stack');
      if (!mounted || generation != _paginationGeneration) return;
      setState(() {
        _isLoading = false;
        _errorMessage = '文本排版失败，请稍后重试';
      });
    }
  }

  void _saveCurrentProgress() {
    if (_pages.isEmpty || _currentPageIndex >= _pages.length) return;
    final slice = _pages[_currentPageIndex];
    if (slice.startByteOffset == _lastReportedOffset) return;
    _lastReportedOffset = slice.startByteOffset;

    final progress = (slice.endByteOffset / _totalFileSize).clamp(0.0, 1.0);
    widget.onProgressChanged?.call(slice.startByteOffset, progress);
  }

  void _updateCurrentChapterByPageIndex(int pageIndex) {
    if (_toc.isEmpty) return;
    int activeIdx = 0;
    for (int i = 0; i < _toc.length; i++) {
      if (pageIndex >= _toc[i].pageIndex) {
        activeIdx = i;
      } else {
        break;
      }
    }
    if (_currentChapterIndex != activeIdx) {
      setState(() => _currentChapterIndex = activeIdx);
    }
  }

  void _onPageChanged(int pageIndex) {
    if (pageIndex < 0 || pageIndex >= _pages.length) return;
    _currentPageIndex = pageIndex;
    _isTurningPage = false; // 翻页完成，释放锁
    _updateCurrentChapterByPageIndex(pageIndex);
    _saveCurrentProgress();
  }

  /// 点击瞬切调度（无过渡动画）
  void _turnToPage(int targetIndex) {
    if (_isTurningPage) return;
    if (targetIndex < 0 || targetIndex >= _pages.length) return;
    if (targetIndex == _currentPageIndex) return;

    _isTurningPage = true;
    _currentPageIndex = targetIndex;
    _updateCurrentChapterByPageIndex(targetIndex);

    _turnViewKey.currentState?.jumpToPage(targetIndex);

    // 延时释放防抖保护
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) {
        _isTurningPage = false;
      }
    });
  }

  void _prevPage() {
    _turnToPage(_currentPageIndex - 1);
  }

  void _nextPage() {
    _turnToPage(_currentPageIndex + 1);
  }

  void _jumpToChapter(FullTxtChapterItem chapter) {
    Navigator.pop(context);
    if (chapter.pageIndex < 0 || chapter.pageIndex >= _pages.length) return;

    setState(() {
      _currentPageIndex = chapter.pageIndex;
      _showControls = false;
    });
    _turnViewKey.currentState?.jumpToPage(chapter.pageIndex);
    _saveCurrentProgress();
  }

  void _openTypographySettings() {
    TypographySettingsModal.show(
      context,
      config: _typoConfig,
      onConfigChanged: (newConfig) {
        if (newConfig == _typoConfig) return;
        setState(() => _typoConfig = newConfig);
        TypographyPrefs.save(newConfig);
        _scheduleRepaginate();
      },
    );
  }

  /// 3x3 九宫格与水平手势复合层（点击瞬切 + 跟手滑动翻页共存）
  Widget _buildNineGridGestureLayer() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        final totalHeight = constraints.maxHeight;

        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          // 水平跟手拖动
          onHorizontalDragStart: (details) {
            if (_showControls) return;
            _turnViewKey.currentState?.handleHorizontalDragStart(details);
          },
          onHorizontalDragUpdate: (details) {
            if (_showControls) return;
            _turnViewKey.currentState?.handleHorizontalDragUpdate(details, totalWidth);
          },
          onHorizontalDragEnd: (details) {
            if (_showControls) return;
            _turnViewKey.currentState?.handleHorizontalDragEnd(details, totalWidth);
          },
          // 点击瞬切
          onTapUp: (details) {
            if (_isTurningPage) return; // 拦截高频并发点击

            if (_showControls) {
              setState(() => _showControls = false);
              return;
            }

            final dx = details.localPosition.dx;
            final dy = details.localPosition.dy;

            final col = (dx / (totalWidth / 3)).clamp(0.0, 2.0).toInt();
            final row = (dy / (totalHeight / 3)).clamp(0.0, 2.0).toInt();
            final zone = row * 3 + col + 1;

            if (zone == 5) {
              setState(() => _showControls = true);
              return;
            }

            if (_handMode == HandMode.standard) {
              if (zone >= 1 && zone <= 4) {
                _prevPage();
              } else {
                _nextPage();
              }
            } else {
              if (zone == 1 || zone == 2) {
                _prevPage();
              } else {
                _nextPage();
              }
            }
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: _currentTheme.bgColor,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: _effectiveTextColor),
              const SizedBox(height: 16),
              Text(
                '正在排版全文...',
                style: TextStyle(
                  color: _effectiveTextColor.withValues(alpha: 0.6),
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_errorMessage != null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: Center(
          child: Text(_errorMessage!, style: const TextStyle(color: Colors.redAccent)),
        ),
      );
    }

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        _saveCurrentProgress();
      },
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: _currentTheme.bgColor,
        drawer: ReaderDrawer(
          title: widget.title,
          bookmarks: _bookmarks,
          onBookmarkTap: _jumpToBookmark,
          onBookmarkDelete: (b) async {
            await BookmarkSyncService.deleteBookmark(widget.bookId, b.id);
            _loadBookmarks();
          },
          tocView: _toc.isEmpty
              ? const Center(child: Text('未识别到目录章节', style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  itemCount: _toc.length,
                  itemBuilder: (context, index) {
                    final item = _toc[index];
                    final isCurrent = index == _currentChapterIndex;

                    return ListTile(
                      dense: true,
                      title: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                          color: isCurrent ? Colors.brown : Colors.black87,
                        ),
                      ),
                      trailing: Text(
                        'P.${item.pageIndex + 1}',
                        style: const TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                      onTap: () => _jumpToChapter(item),
                    );
                  },
                ),
        ),
        body: Stack(
          children: [
            // 1. 全局单层翻页视图（默认无动画瞬切 + 滑动露底共存）
            PageTurnView(
              key: _turnViewKey,
              itemCount: _pages.length,
              initialIndex: _currentPageIndex,
              onPageChanged: _onPageChanged,
              pageBuilder: (context, index) {
                return _buildPageLayout(_pages[index], index, _pages.length);
              },
            ),

            // 2. 护眼滤镜层（盖住正文，但不影响手势与控制条）
            Positioned.fill(child: EyeCareOverlay(config: _eyeCare)),

            // 3. 顶层 3x3 九宫格与滑动拦截层
            Positioned.fill(
              child: _buildNineGridGestureLayer(),
            ),

            // 4. 顶部导航栏
            if (_showControls)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.black.withValues(alpha: 0.85),
                  child: SafeArea(
                    bottom: false,
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back, color: Colors.white),
                          onPressed: () {
                            _saveCurrentProgress();
                            Navigator.pop(context);
                          },
                        ),
                        Expanded(
                          child: Text(
                            widget.title,
                            style: const TextStyle(color: Colors.white, fontSize: 16),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.bookmark_add_outlined, color: Colors.white),
                          tooltip: '添加书签',
                          onPressed: _toggleBookmark,
                        ),
                        IconButton(
                          icon: const Icon(Icons.format_list_bulleted, color: Colors.white),
                          tooltip: '目录',
                          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // 5. 底部控制栏
            if (_showControls)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.black.withValues(alpha: 0.92),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 全书精确进度滑条
                        Slider(
                          value: _currentPageIndex.toDouble().clamp(0.0, (_pages.length - 1).toDouble()),
                          min: 0,
                          max: (_pages.length > 1 ? _pages.length - 1 : 1).toDouble(),
                          onChanged: (val) {
                            final targetPage = val.toInt();
                            setState(() => _currentPageIndex = targetPage);
                            _turnViewKey.currentState?.jumpToPage(targetPage);
                          },
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(
                                _toc.isNotEmpty && _currentChapterIndex < _toc.length
                                    ? _toc[_currentChapterIndex].title
                                    : '页码 ${_currentPageIndex + 1}/${_pages.length}',
                                style: const TextStyle(color: Colors.white70, fontSize: 12),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              '${((_currentPageIndex / (_pages.isNotEmpty ? _pages.length : 1)) * 100).toStringAsFixed(1)}%',
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                          ],
                        ),
                        const Divider(color: Colors.white24, height: 16),

                        // 手势模式切换（常规手势 / 单手模式）
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('手势操作', style: TextStyle(color: Colors.white70, fontSize: 12)),
                            Row(
                              children: HandMode.values.map((mode) {
                                final isSelected = _handMode == mode;
                                return Padding(
                                  padding: const EdgeInsets.only(left: 6),
                                  child: ChoiceChip(
                                    label: Text(mode.label),
                                    selected: isSelected,
                                    selectedColor: const Color(0xFF5A4A3A),
                                    backgroundColor: Colors.white.withValues(alpha: 0.12),
                                    checkmarkColor: Colors.white,
                                    showCheckmark: false,
                                    side: BorderSide(
                                      color: isSelected ? const Color(0xFF8D7358) : Colors.transparent,
                                    ),
                                    labelStyle: TextStyle(
                                      color: isSelected ? Colors.white : Colors.black87,
                                      fontSize: 11,
                                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                    ),
                                    onSelected: (_) => _saveHandMode(mode),
                                  ),
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),

                        // 排版与主题切换（已移除旧翻页选项）
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            OutlinedButton.icon(
                              icon: const Icon(Icons.text_format, color: Colors.white, size: 18),
                              label: const Text('排版 / 字体', style: TextStyle(color: Colors.white, fontSize: 12)),
                              onPressed: _openTypographySettings,
                            ),
                            // 主题数量增加后单行放不下，允许横向滚动而非硬挤压
                            Flexible(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: ReaderThemes.all.map((theme) {
                                    // 羊皮纸1/2 底色相同，只能按名称区分选中项
                                    final isSelected = _currentTheme.name == theme.name;
                                    return Padding(
                                      padding: const EdgeInsets.only(left: 6),
                                      child: GestureDetector(
                                        onTap: () => _updateReaderTheme(theme),
                                        // 长按打开调色盘，自定义该主题的文字颜色
                                        onLongPress: () =>
                                            _openColorPicker(theme),
                                        child: Container(
                                          width: 48,
                                          height: 28,
                                          decoration: BoxDecoration(
                                            color: theme.bgColor,
                                            image: theme.backgroundImage == null
                                                ? null
                                                : DecorationImage(
                                                    image: AssetImage(theme.backgroundImage!),
                                                    fit: BoxFit.cover,
                                                  ),
                                            borderRadius: BorderRadius.circular(4),
                                            border: Border.all(
                                              color: isSelected ? Colors.blueAccent : Colors.grey,
                                              width: isSelected ? 2 : 1,
                                            ),
                                          ),
                                          alignment: Alignment.center,
                                          child: Text(
                                            theme.name,
                                            style: TextStyle(
                                              // 展示该主题实际生效的文字颜色（含自定义色）
                                              color: ReaderThemePrefs
                                                  .effectiveTextColor(
                                                      theme,
                                                      _customTextColors),
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),

                        // 护眼模式与强度
                        EyeCareControlRow(
                          config: _eyeCare,
                          onChanged: _updateEyeCare,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPageLayout(FullTxtPageSlice slice, int pageIndex, int totalPages) {
    final currentChapterTitle = _toc.isNotEmpty && _currentChapterIndex < _toc.length
        ? _toc[_currentChapterIndex].title
        : widget.title;

    final hasChapterHeader = slice.chapterTitle != null && slice.chapterTitle!.isNotEmpty;
    final cleanContent = _contentOf(slice);

    return Container(
      decoration: BoxDecoration(
        color: _currentTheme.bgColor,
        image: _currentTheme.backgroundImage == null
            ? null
            : DecorationImage(
                image: AssetImage(_currentTheme.backgroundImage!),
                // cover 会按短边等比放大并居中裁切，竖屏下正好只保留图片中间部分
                fit: BoxFit.cover,
              ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kHorizontalPadding,
            vertical: kVerticalPadding,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 顶部小字章节提示
              SizedBox(
                height: kHeaderHeight,
                child: Text(
                  currentChapterTitle,
                  style: TextStyle(
                    fontSize: 11,
                    color: _effectiveTextColor.withValues(alpha: 0.5),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(height: kHeaderSpacing),

              // 正文区域
              Expanded(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text.rich(
                    TextSpan(
                      children: [
                        // 1. 章节大标题
                        if (hasChapterHeader)
                          TextSpan(
                            text: '${slice.chapterTitle!}\n',
                            style: TextStyle(
                              fontSize: _typoConfig.fontSize * 1.25,
                              fontWeight: FontWeight.bold,
                              height: 1.4,
                              letterSpacing: _typoConfig.letterSpacing + 0.5,
                              fontFamily: _typoConfig.customFontFamily,
                              color: _effectiveTextColor,
                            ),
                          ),
                        // 2. 正文内容
                        TextSpan(
                          text: cleanContent,
                          style: TextStyle(
                            fontSize: _typoConfig.fontSize,
                            height: _typoConfig.lineHeight,
                            letterSpacing: _typoConfig.letterSpacing,
                            fontFamily: _typoConfig.customFontFamily,
                            color: _effectiveTextColor,
                          ),
                        ),
                      ],
                    ),
                    strutStyle: StrutStyle(
                      fontSize: _typoConfig.fontSize,
                      height: _typoConfig.lineHeight,
                      forceStrutHeight: false,
                    ),
                  ),
                ),
              ),

              // 底部页码与总进度
              SizedBox(
                height: kFooterHeight,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${pageIndex + 1} / $totalPages',
                      style: TextStyle(
                        fontSize: 11,
                        color: _effectiveTextColor.withValues(alpha: 0.5),
                      ),
                    ),
                    Text(
                      '${(slice.endByteOffset / _totalFileSize * 100).toStringAsFixed(1)}%',
                      style: TextStyle(
                        fontSize: 11,
                        color: _effectiveTextColor.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
     ),
    );
  }
}

class _StyleMeasurement {
  final double asciiWidth;
  final double wideWidth;
  final double lineHeight;

  const _StyleMeasurement({
    required this.asciiWidth,
    required this.wideWidth,
    required this.lineHeight,
  });
}