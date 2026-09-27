package com.example.nas_reader

import io.flutter.embedding.android.FlutterActivity

// notailnet 风味：不打包 tailnet AAR（省去 arm64 gojni.so ≈20MB），
// 也不注册 nas_reader/tailnet MethodChannel。Dart 侧 kTailnetSupported=false，
// 不会发起相关调用，因此无需桩实现。
class MainActivity: FlutterActivity()
