// main.dart
// main.dart — thay toàn bộ
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app.dart';
import 'logic.dart';

void main() {
  // Bắt Flutter framework errors
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    debugPrint('═══ FLUTTER ERROR ═══');
    debugPrint(details.exceptionAsString());
    debugPrint(details.stack.toString());
  };

  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF080705),
      systemNavigationBarIconBrightness: Brightness.light,
    ));

    runApp(
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: const TocflApp(),
      ),
    );
  }, (error, stack) {
    // Bắt Dart async errors không được catch ở chỗ khác
    debugPrint('═══ ZONE ERROR ═══');
    debugPrint(error.toString());
    debugPrint(stack.toString());
  });
}
