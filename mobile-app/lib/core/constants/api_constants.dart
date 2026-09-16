import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ApiConstants {
  ApiConstants._();

  static const String _prefKeyBaseUrl = 'custom_server_base_url';
  static const String defaultLocalIp = '192.168.1.81';
  static const String defaultPort = '5000';
  static const String defaultVpsUrl = 'https://elevateiq-softtech.com/video-platform-api';

  static String? _customBaseUrl;

  static String? get customServerUrl => _customBaseUrl;
  static set customServerUrl(String? val) {
    if (val != null && val.isNotEmpty) {
      setBaseUrl(val);
    } else {
      resetBaseUrl();
    }
  }

  /// Initialize and load any saved custom server URL
  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _customBaseUrl = prefs.getString(_prefKeyBaseUrl);
    } catch (e) {
      debugPrint('Error loading saved server URL: $e');
    }
  }

  /// Update and persist server base URL
  static Future<void> setBaseUrl(String url) async {
    final clean = url.trim().replaceAll(RegExp(r'/+$'), '');
    _customBaseUrl = clean;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKeyBaseUrl, clean);
    } catch (e) {
      debugPrint('Error saving server URL: $e');
    }
  }

  /// Reset server base URL to default
  static Future<void> resetBaseUrl() async {
    _customBaseUrl = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefKeyBaseUrl);
    } catch (e) {
      debugPrint('Error resetting server URL: $e');
    }
  }

  /// Base URL for backend server
  static String get baseUrl {
    if (_customBaseUrl != null && _customBaseUrl!.isNotEmpty) {
      return _customBaseUrl!;
    }

    if (kIsWeb) {
      final host = Uri.base.host.isNotEmpty ? Uri.base.host : 'localhost';
      final scheme = Uri.base.scheme.isNotEmpty ? Uri.base.scheme : 'http';
      if (host != 'localhost' && host != '127.0.0.1') {
        return '$scheme://$host:5000';
      }
      return 'http://$host:5000';
    }

    // Default for Android & iOS mobile devices: use VPS production URL
    return defaultVpsUrl;
  }

  static const String apiVersion = '/api/v1';

  static String get healthEndpoint => '/health';
  static String get adminsEndpoint => '$apiVersion/admins';
  static String get vendorsEndpoint => '$apiVersion/vendors';
  static String get candidatesEndpoint => '$apiVersion/candidates';
  static String get videosEndpoint => '$apiVersion/videos';
  static String get videoUploadEndpoint => '$apiVersion/videos/upload';
  static String get qcReviewsEndpoint => '$apiVersion/qc-reviews';

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
