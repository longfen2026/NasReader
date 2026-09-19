import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:nas_reader/core/book_fingerprint.dart';
import 'package:nas_reader/core/book_format.dart';
import 'package:nas_reader/core/network_client.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../readers/stream_txt_reader_page.dart';
import '../readers/epub_reader_page.dart';
import '../readers/pdf_reader_page.dart';
import '../services/progress_sync_service.dart';
import '../services/favorite_service.dart';
import '../services/mobi_converter.dart';
import '../services/app_logger.dart';
import '../widgets/book_leading_icon.dart';

enum FileSortType {
  nameAsc('名称 (A-Z)'),
  nameDesc('名称 (Z-A)'),
  timeDesc('时间 (从新到旧)'),
  timeAsc('时间 (从旧到新)'),
  sizeAsc('体积 (从小到大)'),
  sizeDesc('体积 (从大到小)'),
  type('按文件类型');

  final String label;
  const FileSortType(this.label);
}

class NasFileItem {
  final String name;
  final String path;
  final bool isDir;
  final int size;
  final String? bookId;
  final int modTime;

  NasFileItem({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    this.bookId,
    required this.modTime,
  });

  factory NasFileItem.fromJson(Map<String, dynamic> json) {
    String rawPath = (json['path'] ?? '').toString();
    if (!rawPath.startsWith('/')) {
      rawPath = '/$rawPath';
    }

    final rawModTime = json['mod_time'] ?? json['ModTime'] ?? 0;
    final modTime = (rawModTime is num)
        ? rawModTime.toInt()
        : (int.tryParse(rawModTime.toString()) ?? 0);

    return NasFileItem(
      name: json['name'] ?? '',
      path: rawPath,
      isDir: json['is_dir'] == true,
      size: (json['size'] as num?)?.toInt() ?? 0,
      bookId: json['book_id']?.toString(),
      modTime: modTime,
    );
  }

  /// 同步用书籍唯一标识：优先使用后端文件指纹，缺失时退化为文件名
  String get syncBookId => (bookId != null && bookId!.isNotEmpty) ? bookId! : name;

  /// 本地缓存文件名，带指纹前缀以避免同名书籍互相覆盖
  String get cacheFileName =>
      BookCacheNaming.buildFileName(bookId: bookId, originalName: name);
}

/// 搜索结果所在目录的展示文案。全库搜索会跨目录返回同名书籍，必须标出位置才能区分。
String formatSearchLocation(String remotePath) {
  final dir = p.dirname(remotePath);
  if (dir.isEmpty || dir == '.' || dir == '/') return '书库根目录';
  return dir;
}

class FileBrowserPage extends StatefulWidget {
  final Dio? dio; // 👈 优化为可选，内部自动从 NetworkClient / ApiConfig 回退

  const FileBrowserPage({super.key, this.dio});

  @override
  State<FileBrowserPage> createState() => FileBrowserPageState();
}

class FileBrowserPageState extends State<FileBrowserPage> {
  static const String _sortPrefKey = 'nas_file_sort_type';

  late Dio _dio;
  String _currentPath = '/';
  List<NasFileItem> _items = [];
  bool _isLoading = true;
  String? _errorMessage;

  FileSortType _currentSort = FileSortType.timeDesc;
  final Set<String> _cachedFileNames = {};
  Set<String> _favoriteIds = {};
  Set<String> _shelfBookIds = {};

  // 搜索态与目录浏览态互不干扰：退出搜索后 _currentPath / _items 原样保留
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  String _searchKeyword = '';
  List<NasFileItem> _searchResults = [];
  bool _isSearchLoading = false;
  String? _searchError;
  bool _searchTruncated = false;

  @override
  void initState() {
    super.initState();
    // 优先使用传入的 Dio，默认从 NetworkClient 获取（自动包含 ApiConfig.baseUrl 与 JWT Token）
    _dio = widget.dio ?? NetworkClient.getDio();
    FavoriteService.revision.addListener(_refreshFavoriteIds);
    _initAndLoad();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    FavoriteService.revision.removeListener(_refreshFavoriteIds);
    super.dispose();
  }

  Future<void> _refreshFavoriteIds() async {
    final ids = await FavoriteService.getFavoriteIds();
    if (mounted) setState(() => _favoriteIds = ids);
  }

  Future<void> _toggleFavorite(NasFileItem item) async {
    final title = p.basenameWithoutExtension(item.name);
    final added = await FavoriteService.toggle(
      bookId: item.syncBookId,
      title: title,
      fileName: item.name,
      remotePath: item.path,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(added ? '已收藏《$title》' : '已取消收藏《$title》'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _initAndLoad() async {
    await _loadSavedSortPreference();
    await _loadDirectory(_currentPath);
  }

  Future<void> _loadSavedSortPreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedSortName = prefs.getString(_sortPrefKey);
      if (savedSortName != null) {
        _currentSort = FileSortType.values.firstWhere(
          (e) => e.name == savedSortName,
          orElse: () => FileSortType.timeDesc,
        );
      }
    } catch (e) {
      AppLogger.log('⚠️ 排序偏好读取失败，使用默认排序: $e');
    }
  }

  Future<void> _changeSort(FileSortType newSort) async {
    setState(() {
      _currentSort = newSort;
      _applySort();
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sortPrefKey, newSort.name);
    } catch (e) {
      AppLogger.log('❌ 保存排序配置失败: $e');
    }
  }

  void _applySort() {
    _items.sort((a, b) {
      if (a.isDir && !b.isDir) return -1;
      if (!a.isDir && b.isDir) return 1;

      switch (_currentSort) {
        case FileSortType.nameAsc:
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case FileSortType.nameDesc:
          return b.name.toLowerCase().compareTo(a.name.toLowerCase());
        case FileSortType.timeDesc:
          final comp = b.modTime.compareTo(a.modTime);
          return comp != 0 ? comp : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case FileSortType.timeAsc:
          final comp = a.modTime.compareTo(b.modTime);
          return comp != 0 ? comp : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case FileSortType.sizeAsc:
          final comp = a.size.compareTo(b.size);
          return comp != 0 ? comp : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case FileSortType.sizeDesc:
          final comp = b.size.compareTo(a.size);
          return comp != 0 ? comp : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case FileSortType.type:
          final extA = p.extension(a.name).toLowerCase();
          final extB = p.extension(b.name).toLowerCase();
          final comp = extA.compareTo(extB);
          return comp != 0 ? comp : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
    });
  }

  Future<void> _updateCachedFiles() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final booksDir = Directory(p.join(appDir.path, 'books'));
      if (!booksDir.existsSync()) {
        booksDir.createSync(recursive: true);
      }

      final files = booksDir.listSync();
      _cachedFileNames.clear();
      for (var f in files) {
        if (f is File && f.lengthSync() > 0) {
          _cachedFileNames.add(p.basename(f.path));
        }
      }
    } catch (e) {
      AppLogger.log('❌ 扫描本地已缓存文件失败: $e');
    }
  }

  /// 新命名（带指纹前缀）与旧命名（纯文件名）都视为已缓存
  bool _isItemCached(NasFileItem item) =>
      _cachedFileNames.contains(item.cacheFileName) ||
      _cachedFileNames.contains(item.name);

  /// 书架与本地书架页保持一致：有本地阅读记录或已缓存即视为在书架
  bool _isOnShelf(NasFileItem item) =>
      _shelfBookIds.contains(item.syncBookId) || _isItemCached(item);

  Future<void> _refreshShelfBookIds() async {
    final list = await ProgressSyncService.getAllLocalProgress();
    _shelfBookIds = list.map((e) => e.bookId).toSet();
  }

  Future<void> _loadDirectory(String targetPath) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await _updateCachedFiles();
      _favoriteIds = await FavoriteService.getFavoriteIds();
      await _refreshShelfBookIds();

      final res = await _dio.get(
        '/api/v1/files/browse',
        queryParameters: {'path': targetPath},
      );

      if (res.statusCode == 200 && res.data != null) {
        List<dynamic> rawList = [];

        if (res.data is Map && res.data['items'] is List) {
          rawList = res.data['items'];
        } else if (res.data is Map && res.data['data'] is List) {
          rawList = res.data['data'];
        } else if (res.data is List) {
          rawList = res.data;
        }

        AppLogger.log('📂 成功加载目录 $targetPath, 解析到文件数: ${rawList.length}');

        _items = rawList
            .map((e) => NasFileItem.fromJson(Map<String, dynamic>.from(e)))
            .toList();

        _applySort();

        if (mounted) {
          setState(() {
            _currentPath = targetPath;
            _isLoading = false;
          });
        }
      } else {
        throw Exception('获取文件列表失败: ${res.statusCode}');
      }
    } catch (e) {
      AppLogger.log('❌ 加载目录失败: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = '加载失败: $e';
        });
      }
    }
  }

  /// 打开搜索态：仅切换 UI，目录列表状态原样保留，退出后无需重新加载
  void _enterSearchMode() {
    setState(() {
      _isSearching = true;
      _searchError = null;
      _searchTruncated = false;
    });
  }

  /// 退出搜索态并清空搜索上下文
  void _exitSearchMode() {
    _searchDebounce?.cancel();
    _searchController.clear();
    setState(() {
      _isSearching = false;
      _searchKeyword = '';
      _searchResults = [];
      _isSearchLoading = false;
      _searchError = null;
      _searchTruncated = false;
    });
  }

  /// 输入防抖，避免每敲一个字都触发一次服务端全库遍历
  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    final keyword = value.trim();

    if (keyword.isEmpty) {
      setState(() {
        _searchKeyword = '';
        _searchResults = [];
        _isSearchLoading = false;
        _searchError = null;
        _searchTruncated = false;
      });
      return;
    }

    _searchDebounce = Timer(const Duration(milliseconds: 400), () {
      _runSearch(keyword);
    });
  }

  Future<void> _runSearch(String keyword) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return;

    setState(() {
      _searchKeyword = trimmed;
      _isSearchLoading = true;
      _searchError = null;
      _searchTruncated = false;
    });

    try {
      await _updateCachedFiles();
      _favoriteIds = await FavoriteService.getFavoriteIds();
      await _refreshShelfBookIds();

      final res = await _dio.get(
        '/api/v1/files/search',
        queryParameters: {'q': trimmed},
        // 服务端无索引，全库递归遍历比单目录浏览慢得多，超时按本次请求放宽
        options: Options(receiveTimeout: const Duration(seconds: 60)),
      );

      if (res.statusCode == 200 && res.data != null) {
        List<dynamic> rawList = [];

        if (res.data is Map && res.data['items'] is List) {
          rawList = res.data['items'];
        } else if (res.data is Map && res.data['data'] is List) {
          rawList = res.data['data'];
        } else if (res.data is List) {
          rawList = res.data;
        }

        final results = rawList
            .map((e) => NasFileItem.fromJson(Map<String, dynamic>.from(e)))
            .toList();

        AppLogger.log('🔎 全库搜索「$trimmed」命中 ${results.length} 本');

        if (!mounted) return;
        setState(() {
          _searchResults = results;
          _searchTruncated =
              res.data is Map && res.data['truncated'] == true;
          _isSearchLoading = false;
        });
      } else {
        throw Exception('搜索失败: ${res.statusCode}');
      }
    } catch (e) {
      AppLogger.log('❌ 全库搜索失败: $e');
      if (!mounted) return;
      setState(() {
        _isSearchLoading = false;
        _searchError = '搜索失败: $e';
      });
    }
  }

  /// 定位书籍的本地缓存文件：优先带指纹前缀的新命名，
  /// 若只存在旧版无前缀文件则就地重命名迁移。
  Future<File> _resolveLocalFile(NasFileItem item) async {
    final appDir = await getApplicationDocumentsDirectory();
    final booksDir = p.join(appDir.path, 'books');
    final target = File(p.join(booksDir, item.cacheFileName));

    if (target.existsSync() || item.cacheFileName == item.name) return target;

    final legacy = File(p.join(booksDir, item.name));
    if (legacy.existsSync() && legacy.lengthSync() > 0) {
      try {
        return await legacy.rename(target.path);
      } catch (e) {
        AppLogger.log('❌ 迁移旧缓存文件失败，继续沿用旧文件: $e');
        return legacy;
      }
    }
    return target;
  }

  Future<void> _handleItemTap(NasFileItem item) async {
    if (item.isDir) {
      _loadDirectory(item.path);
      return;
    }

    final ext = p.extension(item.name).toLowerCase();
    if (BookFormat.fromExtension(ext) == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('暂不支持此格式阅读，目前支持 ${BookFormat.labels}')),
      );
      return;
    }

    final targetFile = await _resolveLocalFile(item);
    final localFilePath = targetFile.path;

    if (targetFile.existsSync() && targetFile.lengthSync() > 0) {
      _openReader(targetFile, item);
      return;
    }

    final ValueNotifier<double> downloadProgress = ValueNotifier<double>(0.0);
    final CancelToken cancelToken = CancelToken();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            cancelToken.cancel('用户取消下载');
          },
          child: Dialog(
            backgroundColor: Theme.of(context).cardColor,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 48,
                    height: 48,
                    child: CircularProgressIndicator(strokeWidth: 3.5),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    '正在下载《${p.basenameWithoutExtension(item.name)}》',
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  const SizedBox(height: 12),
                  ValueListenableBuilder<double>(
                    valueListenable: downloadProgress,
                    builder: (context, progress, _) {
                      return Column(
                        children: [
                          LinearProgressIndicator(
                            value: progress > 0 ? progress : null,
                            minHeight: 6,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            progress > 0
                                ? '${(progress * 100).toStringAsFixed(1)}%'
                                : '正在从 NAS 建立传输连接...',
                            style: const TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: () {
                      cancelToken.cancel('用户取消');
                      Navigator.pop(ctx);
                    },
                    child: const Text('取消下载'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    try {
      await _dio.download(
        '/api/v1/files/download',
        localFilePath,
        queryParameters: {'path': item.path},
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            downloadProgress.value = (received / total).clamp(0.0, 1.0);
          }
        },
      );

      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }

      setState(() {
        _cachedFileNames.add(p.basename(localFilePath));
      });

      if (mounted) {
        _openReader(targetFile, item);
      }
    } catch (e) {
      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
      final isCanceled = e is DioException && CancelToken.isCancel(e);
      if (!isCanceled && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _openReader(File file, NasFileItem item) async {
    final bookId = item.syncBookId;
    final title = p.basenameWithoutExtension(item.name);

    // 旧版本用文件名作为 bookId，此处把历史记录迁移到指纹键
    if (bookId != item.name) {
      await ProgressSyncService.migrateLegacyBookId(
        legacyBookId: item.name,
        newBookId: bookId,
      );
    }

    // 曾从书架移除过的书，重新打开时把云端进度拉回本地
    await ProgressSyncService.restoreToShelf(bookId, _dio);

    final progressList = await ProgressSyncService.getAllLocalProgress();
    final savedRecord = progressList.firstWhere(
      (p) => p.bookId == bookId,
      orElse: () => BookProgress(
        bookId: bookId,
        title: title,
        filePath: item.path,
        progress: 0.0,
        locator: '',
        clientUpdatedAt: 0,
      ),
    );

    final ext = p.extension(item.name).toLowerCase();
    if (!mounted) return;
    final initialOffset = savedRecord.txtByteOffset ?? 0;
    final initialCfi = savedRecord.epubCfi;

    if (ext == '.mobi') {
      final epubFile = await MobiConverter.toEpub(file, bookId);
      if (!mounted) return;
      if (epubFile == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('MOBI 解析失败，可能为加密或不受支持的变体')),
        );
        return;
      }
      Navigator.push(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 120),
          pageBuilder: (context, animation, secondaryAnimation) => EpubReaderPage(
            bookId: bookId,
            file: epubFile,
            title: title,
            initialCfi: initialCfi,
            initialProgress: savedRecord.progress,
            onProgressChanged: (cfi, progress) {
              ProgressSyncService.updateProgress(
                dio: _dio,
                bookId: bookId,
                title: title,
                filePath: item.path,
                progressPercent: progress,
                locator: cfi,
              );
            },
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
      ).then((_) => _updateCachedFiles());
    } else if (ext == '.txt') {
      Navigator.push(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 120),
          pageBuilder: (context, animation, secondaryAnimation) => StreamTxtReaderPage(
            bookId: bookId,
            file: file,
            title: title,
            initialByteOffset: initialOffset,
            onProgressChanged: (byteOffset, progress) {
              ProgressSyncService.updateProgress(
                dio: _dio,
                bookId: bookId,
                title: title,
                filePath: item.path,
                progressPercent: progress,
                locator: byteOffset.toString(),
              );
            },
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
      ).then((_) => _updateCachedFiles());
    } else if (ext == '.epub') {
      Navigator.push(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 120),
          pageBuilder: (context, animation, secondaryAnimation) => EpubReaderPage(
            bookId: bookId,
            file: file,
            title: title,
            initialCfi: initialCfi,
            initialProgress: savedRecord.progress,
            onProgressChanged: (cfi, progress) {
              ProgressSyncService.updateProgress(
                dio: _dio,
                bookId: bookId,
                title: title,
                filePath: item.path,
                progressPercent: progress,
                locator: cfi,
              );
            },
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
      ).then((_) => _updateCachedFiles());
    } else if (ext == '.pdf') {
      Navigator.push(
        context,
        PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 120),
          pageBuilder: (context, animation, secondaryAnimation) => PdfReaderPage(
            bookId: bookId,
            file: file,
            title: title,
            initialPage: savedRecord.pdfPage,
            initialProgress: savedRecord.progress,
            onProgressChanged: (pageIndex, progress) {
              ProgressSyncService.updateProgress(
                dio: _dio,
                bookId: bookId,
                title: title,
                filePath: item.path,
                progressPercent: progress,
                locator: pageIndex.toString(),
              );
            },
          ),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            return FadeTransition(opacity: animation, child: child);
          },
        ),
      ).then((_) => _updateCachedFiles());
    }  
  }

  Future<void> _confirmMoveToTrash(NasFileItem item) async {
    final title = p.basenameWithoutExtension(item.name);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移动到垃圾箱'),
        content: Text(
          '确定要把《$title》移动到 NAS 垃圾箱吗？\n\n'
          '• 书架缓存、阅读进度、书签与收藏将一并清除\n'
          '• 可在“设置 - 垃圾箱”中查看或恢复文件',
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移动', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      await _dio.post('/api/v1/files/trash', data: {'path': item.path});
      await _purgeBookTraces(item);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已把《$title》移动到垃圾箱')),
      );
      if (_isSearching) {
        await _runSearch(_searchKeyword);
      } else {
        await _loadDirectory(_currentPath);
      }
    } catch (e) {
      AppLogger.log('移动到垃圾箱失败: ${item.path} -> $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('移动失败，请检查网络或服务端权限'),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  /// 书籍已进垃圾箱，书架缓存与它的进度、书签、收藏一并清掉（云端记录同步删除）
  Future<void> _purgeBookTraces(NasFileItem item) async {
    try {
      final localFile = await _resolveLocalFile(item);
      if (localFile.existsSync()) await localFile.delete();
    } catch (e) {
      AppLogger.log('清理本地缓存文件失败: ${item.name} -> $e');
    }

    await FavoriteService.remove(item.syncBookId);
    await ProgressSyncService.deleteBookEverything(item.syncBookId, _dio);
  }

  /// 加入书架：不预先下载文件，先建立一条零进度记录，书架以“云端记录”展示
  Future<void> _handleAddToShelf(NasFileItem item) async {
    final title = p.basenameWithoutExtension(item.name);
    try {
      await ProgressSyncService.restoreToShelf(item.syncBookId, _dio);
      if (!_shelfBookIds.contains(item.syncBookId)) {
        await ProgressSyncService.updateProgress(
          dio: _dio,
          bookId: item.syncBookId,
          title: title,
          filePath: item.path,
          progressPercent: 0.0,
          locator: '0',
        );
      }
      await _refreshShelfBookIds();
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已把《$title》加入书架'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      AppLogger.log('❌ 加入书架失败: ${item.path} -> $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加入书架失败: $e'), backgroundColor: Colors.redAccent),
      );
    }
  }

  /// 移出书架：清本地缓存与本地进度/书签，云端记录保留
  Future<void> _handleRemoveFromShelf(NasFileItem item) async {
    final title = p.basenameWithoutExtension(item.name);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移出书架', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Text(
          '确定要把《$title》从书架移出吗？\n\n'
          '• 本地缓存文件与本地阅读进度、书签将被清理\n'
          '• 云端阅读进度与书签保留，重新加入书架后可继续阅读\n'
          '• NAS 原始文件不受影响',
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移出书架', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      final localFile = await _resolveLocalFile(item);
      if (localFile.existsSync()) await localFile.delete();
      await ProgressSyncService.removeFromShelfLocally(item.syncBookId);
      await _updateCachedFiles();
      await _refreshShelfBookIds();
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已把《$title》移出书架'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      AppLogger.log('❌ 移出书架失败: ${item.path} -> $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('移出书架失败: $e'), backgroundColor: Colors.redAccent),
      );
    }
  }

  /// 行尾三点菜单：收藏、书架、扔到垃圾箱
  Widget _buildBookActionMenu(NasFileItem item) {
    final isFavorite = _favoriteIds.contains(item.syncBookId);
    final onShelf = _isOnShelf(item);
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, color: Colors.grey),
      tooltip: '更多操作',
      onSelected: (action) async {
        switch (action) {
          case 'favorite':
            await _toggleFavorite(item);
            break;
          case 'shelf':
            if (onShelf) {
              await _handleRemoveFromShelf(item);
            } else {
              await _handleAddToShelf(item);
            }
            break;
          case 'trash':
            await _confirmMoveToTrash(item);
            break;
        }
      },
      itemBuilder: (ctx) => [
        PopupMenuItem(
          value: 'favorite',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              isFavorite ? Icons.star_border : Icons.star,
              color: Colors.amber.shade700,
            ),
            title: Text(isFavorite ? '移出收藏' : '加入收藏'),
          ),
        ),
        PopupMenuItem(
          value: 'shelf',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              onShelf ? Icons.delete_sweep_outlined : Icons.library_add_outlined,
              color: onShelf ? Colors.orange : Colors.blue,
            ),
            title: Text(onShelf ? '移出书架' : '加入书架'),
          ),
        ),
        const PopupMenuItem(
          value: 'trash',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline, color: Colors.redAccent),
            title: Text('扔到垃圾箱'),
          ),
        ),
      ],
    );
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final isRoot = _currentPath == '/' || _currentPath.isEmpty;

    return PopScope(
      // 搜索态下返回键先退出搜索，其次才是回上级目录
      canPop: isRoot && !_isSearching,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_isSearching) {
          _exitSearchMode();
          return;
        }
        if (!isRoot) {
          final parent = p.dirname(_currentPath);
          _loadDirectory(parent.isEmpty ? '/' : parent);
        }
      },
      child: Scaffold(
        appBar: _isSearching ? _buildSearchAppBar() : _buildBrowseAppBar(isRoot),
        body: _isSearching ? _buildSearchContent() : _buildContent(),
      ),
    );
  }

  AppBar _buildBrowseAppBar(bool isRoot) {
    return AppBar(
      title: Text(
        isRoot ? 'NAS 书库' : p.basename(_currentPath),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      leading: !isRoot
          ? IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () {
                final parent = p.dirname(_currentPath);
                _loadDirectory(parent.isEmpty ? '/' : parent);
              },
            )
          : null,
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: '搜索整个书库',
          onPressed: _enterSearchMode,
        ),
        PopupMenuButton<FileSortType>(
          icon: const Icon(Icons.sort),
          tooltip: '排序方式',
          onSelected: _changeSort,
          itemBuilder: (context) => FileSortType.values.map((type) {
            final isSelected = type == _currentSort;
            return PopupMenuItem<FileSortType>(
              value: type,
              child: Row(
                children: [
                  Icon(
                    isSelected ? Icons.check : Icons.radio_button_unchecked,
                    size: 18,
                    color: isSelected ? Theme.of(context).primaryColor : Colors.grey,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    type.label,
                    style: TextStyle(
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      color: isSelected ? Theme.of(context).primaryColor : null,
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: '刷新当前目录',
          onPressed: () => _loadDirectory(_currentPath),
        ),
      ],
    );
  }

  AppBar _buildSearchAppBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        tooltip: '退出搜索',
        onPressed: _exitSearchMode,
      ),
      titleSpacing: 0,
      title: TextField(
        controller: _searchController,
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: const InputDecoration(
          hintText: '搜索整个书库的书名',
          border: InputBorder.none,
          isCollapsed: true,
        ),
        onChanged: _onSearchChanged,
        onSubmitted: (value) {
          _searchDebounce?.cancel();
          _runSearch(value);
        },
      ),
      actions: [
        // 监听输入框自身变化，不依赖防抖后的 setState 才能显示清空按钮
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _searchController,
          builder: (context, value, _) {
            if (value.text.isEmpty) return const SizedBox.shrink();
            return IconButton(
              icon: const Icon(Icons.close),
              tooltip: '清空关键词',
              onPressed: () {
                _searchController.clear();
                _onSearchChanged('');
              },
            );
          },
        ),
      ],
    );
  }

  Widget _buildSearchContent() {
    if (_isSearchLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text(
              '正在检索整个书库...',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      );
    }

    if (_searchError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
              const SizedBox(height: 12),
              Text(_searchError!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
                onPressed: () => _runSearch(_searchKeyword),
              ),
            ],
          ),
        ),
      );
    }

    if (_searchKeyword.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '输入书名关键词，检索整个 NAS 书库',
            style: TextStyle(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (_searchResults.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '没有找到包含「$_searchKeyword」的书籍',
            style: const TextStyle(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: Theme.of(context).dividerColor.withValues(alpha: 0.08),
          child: Text(
            _searchTruncated
                ? '命中较多，仅显示前 ${_searchResults.length} 本，请补充关键词'
                : '共找到 ${_searchResults.length} 本书',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: _searchResults.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) =>
                _buildSearchResultTile(_searchResults[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildSearchResultTile(NasFileItem item) {
    final ext = p.extension(item.name).toLowerCase();
    final format = BookFormat.fromExtension(ext);
    final isCached = _isItemCached(item);
    final size = _formatSize(item.size);
    final location = formatSearchLocation(item.path);

    return ListTile(
      // 48px 的三点按钮内部自带 12px 视觉留白，右侧内边距取 4px 即为 16px
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      leading: BookLeadingIcon(
        icon: format?.icon ?? Icons.insert_drive_file_outlined,
        iconColor: format?.color ?? Colors.grey,
        isFavorite: _favoriteIds.contains(item.syncBookId),
      ),
      title: Text(
        item.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        size.isEmpty ? location : '$size · $location',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, color: Colors.grey),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isCached ? Icons.check_circle_outline : Icons.cloud_download_outlined,
            size: 20,
            color: isCached ? Colors.green : Colors.grey,
          ),
          if (format != null) _buildBookActionMenu(item),
        ],
      ),
      onTap: () => _handleItemTap(item),
    );
  }

  Widget _buildContent() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
              const SizedBox(height: 12),
              Text(_errorMessage!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
                onPressed: () => _loadDirectory(_currentPath),
              ),
            ],
          ),
        ),
      );
    }

    if (_items.isEmpty) {
      return const Center(
        child: Text('当前目录为空', style: TextStyle(color: Colors.grey)),
      );
    }

    return RefreshIndicator(
      onRefresh: () => _loadDirectory(_currentPath),
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final item = _items[index];
          final ext = p.extension(item.name).toLowerCase();
          final isCached = !item.isDir && _isItemCached(item);
          final format = item.isDir ? null : BookFormat.fromExtension(ext);
          final isBook = format != null;

          IconData iconData = Icons.insert_drive_file_outlined;
          Color iconColor = Colors.grey;

          if (item.isDir) {
            iconData = Icons.folder;
            iconColor = Colors.amber.shade700;
          } else if (format != null) {
            iconData = format.icon;
            iconColor = format.color;
          }

          return ListTile(
            // 48px 的三点按钮内部自带 12px 视觉留白，右侧内边距取 4px 即为 16px
            contentPadding: isBook
                ? const EdgeInsets.only(left: 16, right: 4)
                : const EdgeInsets.symmetric(horizontal: 16),
            leading: isBook
                ? BookLeadingIcon(
                    icon: iconData,
                    iconColor: iconColor,
                    isFavorite: _favoriteIds.contains(item.syncBookId),
                  )
                : Icon(iconData, color: iconColor, size: 28),
            title: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            subtitle: item.isDir
                ? const Text('文件夹', style: TextStyle(fontSize: 12, color: Colors.grey))
                : Text(
                    _formatSize(item.size),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  item.isDir
                      ? Icons.chevron_right
                      : (isCached ? Icons.check_circle_outline : Icons.cloud_download_outlined),
                  size: 20,
                  color: isCached ? Colors.green : Colors.grey,
                ),
                if (isBook) _buildBookActionMenu(item),
              ],
            ),
            onTap: () => _handleItemTap(item),
          );
        },
      ),
    );
  }
}