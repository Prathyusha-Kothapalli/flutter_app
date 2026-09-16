import 'package:flutter/foundation.dart';

class ApiConstants {
  // Prevent instantiation
  ApiConstants._();

  /// Customizable server URL for mobile APK devices
  static String? customServerUrl;

  /// Default local machine Wi-Fi IP where Node.js & Neon PostgreSQL backend runs
  static const String defaultLocalIp = 'http://192.168.1.87:5000';
  static const String defaultVpsUrl = 'https://elevateiq-softtech.com/video-platform-api';

  /// Base URL for backend server
  static String get baseUrl {
    if (customServerUrl != null && customServerUrl!.trim().isNotEmpty) {
      return customServerUrl!.trim().replaceAll(RegExp(r'/+$'), '');
    }
    if (kIsWeb) {
      final host = Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
      final scheme = Uri.base.scheme.isNotEmpty ? Uri.base.scheme : 'http';
      if (host != 'localhost' && host != '127.0.0.1') {
        return '$scheme://$host/video-platform-api';
      }
      return 'http://$host:5000';
    }
    // On physical mobile devices (APK), connect directly to local backend server
    return defaultLocalIp;
  }

  static const String apiVersion = '/api/v1';

  // API Endpoints
  static String get healthEndpoint => '/health';
  static String get adminsEndpoint => '$apiVersion/admins';
  static String get vendorsEndpoint => '$apiVersion/vendors';
  static String get candidatesEndpoint => '$apiVersion/candidates';
  static String get videosEndpoint => '$apiVersion/videos';
  static String get videoUploadEndpoint => '$apiVersion/videos/upload';
  static String get qcReviewsEndpoint => '$apiVersion/qc-reviews';

  // Request Headers
  static const Map<String, String> defaultHeaders = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  static Map<String, String> getHeadersWithAuth([String? token]) {
    final Map<String, String> headers = Map.from(defaultHeaders);
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }
}
