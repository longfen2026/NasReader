import 'package:flutter/material.dart';

class ReaderThemeData {
  final String name;
  final Color bgColor;
  final Color textColor;

  /// 纸纹背景图 asset 路径，为空表示纯色背景；有值时 bgColor 作为图片加载前的兜底底色
  final String? backgroundImage;

  const ReaderThemeData({
    required this.name,
    required this.bgColor,
    required this.textColor,
    this.backgroundImage,
  });
}

class ReaderThemes {
  static const parchment = ReaderThemeData(
    name: '羊皮纸1',
    bgColor: Color(0xFFF6EFE2),
    textColor: Color(0xFF382E25),
    backgroundImage: 'assets/readbg_1.png',
  );
  static const parchment2 = ReaderThemeData(
    name: '羊皮纸2',
    bgColor: Color(0xFFF6EFE2),
    textColor: Color(0xFF382E25),
    backgroundImage: 'assets/readbg_2.jpg',
  );
  static const nightSky = ReaderThemeData(
    name: '夜空',
    bgColor: Color(0xFF020B1E),
    textColor: Color(0xFFF5F5F5),
    backgroundImage: 'assets/readbg_3.jpg',
  );
  static const night = ReaderThemeData(
    name: '黑夜',
    bgColor: Color(0xFF38424B),
    textColor: Color(0xFFF5F5F5),
    backgroundImage: 'assets/readbg_4.jpg',
  );
  static const white = ReaderThemeData(
    name: '纯白',
    bgColor: Color(0xFFFFFFFF),
    textColor: Color(0xFF1A1A1A),
  );

  static const List<ReaderThemeData> all = [
    parchment,
    parchment2,
    nightSky,
    night,
    white
  ];
}
