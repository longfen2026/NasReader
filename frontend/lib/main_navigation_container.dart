import 'package:flutter/material.dart';
import 'package:dio/dio.dart';

import 'pages/favorites_page.dart';
import 'pages/file_browser_page.dart';
import 'pages/local_bookshelf_page.dart';
import 'pages/settings_page.dart';

class MainNavigationContainer extends StatefulWidget {
  final Dio dio;

  const MainNavigationContainer({
    super.key,
    required this.dio,
  });

  @override
  State<MainNavigationContainer> createState() => _MainNavigationContainerState();
}

class _MainNavigationContainerState extends State<MainNavigationContainer>
    with WidgetsBindingObserver {
  int _currentIndex = 0;

  // 挂载 Key 用于 Tab 切换时联动刷新
  final GlobalKey<LocalBookshelfPageState> _bookshelfKey = GlobalKey<LocalBookshelfPageState>();
  final GlobalKey<FavoritesPageState> _favoritesKey = GlobalKey<FavoritesPageState>();
  // 用于在切到设置页时主动触发缓存统计刷新
  final GlobalKey<SettingsPageState> _settingsKey = GlobalKey<SettingsPageState>();

  late final List<Widget> _pages;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pages = [
      LocalBookshelfPage(
        key: _bookshelfKey,
        dio: widget.dio,
      ),
      FavoritesPage(
        key: _favoritesKey,
        dio: widget.dio,
      ),
      FileBrowserPage(dio: widget.dio),
      SettingsPage(
        key: _settingsKey,
        dio: widget.dio,
      ),
    ];
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _bookshelfKey.currentState?.loadLocalBooks();
      _favoritesKey.currentState?.loadFavorites();
    }
  }

  void _onTabTapped(int index) {
    setState(() {
      _currentIndex = index;
    });

    // 1. 切到「本地书架」(index = 0) 时自动重新扫描目录
    if (index == 0) {
      _bookshelfKey.currentState?.loadLocalBooks();
    }
    // 2. 切到「收藏夹」(index = 1) 时刷新收藏列表
    if (index == 1) {
      _favoritesKey.currentState?.loadFavorites();
    }
    // 3. 切到「系统设置」(index = 3) 时自动刷新缓存大小
    if (index == 3) {
      _settingsKey.currentState?.calculateCacheSize();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _pages,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: _onTabTapped,
        type: BottomNavigationBarType.fixed,
        backgroundColor: theme.colorScheme.surface,
        selectedItemColor: theme.colorScheme.primary,
        unselectedItemColor: theme.colorScheme.onSurfaceVariant,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.book_outlined),
            activeIcon: Icon(Icons.book),
            label: '本地书架',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.star_border),
            activeIcon: Icon(Icons.star),
            label: '收藏夹',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.cloud_outlined),
            activeIcon: Icon(Icons.cloud),
            label: 'NAS 书库',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined),
            activeIcon: Icon(Icons.settings),
            label: '系统设置',
          ),
        ],
      ),
    );
  }
}