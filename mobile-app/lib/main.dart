import 'package:flutter/material.dart';
import 'config/routes/app_routes.dart';
import 'core/constants/app_constants.dart';
import 'core/theme/app_theme.dart';

import 'core/constants/api_constants.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ApiConstants.init();
  runApp(const VideoPlatformApp());
}

class VideoPlatformApp extends StatelessWidget {
  const VideoPlatformApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      initialRoute: AppRoutes.splash,
      routes: AppRoutes.routes,
      onGenerateRoute: AppRoutes.onGenerateRoute,
    );
  }
}
