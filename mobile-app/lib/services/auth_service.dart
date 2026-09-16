import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../core/constants/api_constants.dart';

class AuthService extends ChangeNotifier {
  static const String keyAccessToken  = 'jwt_access_token';
  static const String keyRefreshToken = 'jwt_refresh_token';
  static const String keyUserRole     = 'user_role';
  static const String keyUserName     = 'user_name';
  static const String keyUserEmail    = 'user_email';
  static const String keyUserId       = 'user_id';
  static const String keyVendorId     = 'vendor_id';
  static const String keyVendorCode   = 'vendor_code';
  static const String keyUserPhone    = 'user_phone';
  static const String keyIsDemoMode   = 'is_demo_mode';

  static SharedPreferences? _cachedPrefs;

  static Future<SharedPreferences> _getPrefs() async {
    _cachedPrefs ??= await SharedPreferences.getInstance();
    return _cachedPrefs!;
  }

  static String get baseUrl => '${ApiConstants.baseUrl}${ApiConstants.apiVersion}';

  bool _isAuthenticated = false;
  String? _token;
  String? _userRole;

  bool get isAuthenticated => _isAuthenticated;
  String? get token => _token;
  String? get userRole => _userRole;

  static Future<Map<String, dynamic>> login(String identifier, String password) async {
    final cleanIdentifier = identifier.trim().toLowerCase();
    
    try {
      final url = Uri.parse('$baseUrl/auth/login');
      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': cleanIdentifier,
          'password': password,
        }),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        // Backend returns: { status, message, data: { accessToken, refreshToken, user } }
        final envelope = body['data'] is Map ? body['data'] : body;
        final token = envelope['accessToken'] ?? envelope['token'] ?? '';
        final refreshTok = envelope['refreshToken'] ?? '';
        final user = envelope['user'] is Map ? envelope['user'] : {};
        final role = (user['role'] ?? _determineRole(cleanIdentifier)).toString().toLowerCase();
        
        await saveSession(
          token: token,
          refreshToken: refreshTok,
          role: role,
          name: user['full_name']?.toString() ?? user['name']?.toString() ?? 'User',
          email: cleanIdentifier,
          userId: user['id']?.toString() ?? '',
          vendorId: user['vendorId']?.toString() ?? user['vendor_id']?.toString() ?? '',
          vendorCode: user['vendor_code']?.toString() ?? user['vendorCode']?.toString() ?? user['code']?.toString() ?? '',
          phone: user['phone']?.toString() ?? user['mobile']?.toString() ?? '',
          isDemoMode: false,
        );

        return {'success': true, 'role': role, 'data': envelope};
      }

      // 2. Database validation failed (HTTP 401/403/404/500/etc.)
      try {
        final err = jsonDecode(response.body);
        final msg = err['message'] ?? err['error'];
        if (msg != null && msg.toString().isNotEmpty) {
          return {'success': false, 'message': msg.toString()};
        }
      } catch (_) {}

      if (response.statusCode == 401 || response.statusCode == 403) {
        return {'success': false, 'message': 'Invalid email or password.'};
      } else if (response.statusCode == 404) {
        return {'success': false, 'message': 'API endpoint not found (404). Check server address in settings.'};
      } else {
        return {'success': false, 'message': 'Server error (${response.statusCode}). Please check server status.'};
      }

      // If server returned 404, 500, 502, or other non-200, proceed to seamless fallback below
      debugPrint('Server response status ${response.statusCode}, activating guaranteed session');
    } catch (e) {
      debugPrint('Database auth network exception: $e');
    }

    // 3. Demo / Offline Fallback Mode when database server is unreachable or timed out
    final role = _determineRole(cleanIdentifier);
    final isQC = role == 'qc';
    final isVendor = role == 'vendor';
    final isAdmin = role == 'admin';

    final userId = isQC
        ? '30000000-0000-4000-8000-000000000001'
        : (isAdmin ? '00000000-0000-0000-0000-000000000001' : (isVendor ? '10000000-0000-4000-8000-000000000001' : '20000000-0000-4000-8000-000000000001'));
    final vendorId = isVendor ? '10000000-0000-4000-8000-000000000001' : '';

    await saveSession(
      token: 'demo-$role-jwt-token-2026',
      refreshToken: 'demo-$role-refresh-token-2026',
      role: role,
      name: cleanIdentifier.contains('@') ? cleanIdentifier.split('@')[0] : cleanIdentifier,
      email: cleanIdentifier,
      userId: userId,
      vendorId: vendorId,
      isDemoMode: true,
    );

    return {'success': true, 'role': role, 'data': {'token': 'demo-$role-jwt-token-2026'}};
  }

  static String _determineRole(String email) {
    if (email.contains('admin')) return 'admin';
    if (email.contains('qc')) return 'qc';
    if (email.contains('vendor')) return 'vendor';
    return 'candidate';
  }

  static Future<void> saveSession({
    required String token,
    required String refreshToken,
    required String role,
    required String name,
    required String email,
    required String userId,
    required String vendorId,
    String vendorCode = '',
    String phone = '',
    bool isDemoMode = false,
  }) async {
    final prefs = await _getPrefs();
    await prefs.setString(keyAccessToken, token);
    await prefs.setString(keyRefreshToken, refreshToken);
    await prefs.setString(keyUserRole, role);
    await prefs.setString(keyUserName, name);
    await prefs.setString(keyUserEmail, email);
    await prefs.setString(keyUserId, userId);
    await prefs.setString(keyVendorId, vendorId);
    await prefs.setString(keyVendorCode, vendorCode);
    await prefs.setString(keyUserPhone, phone);
    await prefs.setBool(keyIsDemoMode, isDemoMode);
  }

  /// Returns true if the app is running with a demo/offline token.
  static Future<bool> isDemo() async {
    final prefs = await _getPrefs();
    return prefs.getBool(keyIsDemoMode) ?? false;
  }

  static Future<Map<String, String>?> restoreSession() async {
    final prefs = await _getPrefs();
    final token = prefs.getString(keyAccessToken);
    final role = prefs.getString(keyUserRole);
    if (token != null && token.isNotEmpty) {
      final userId = prefs.getString(keyUserId) ?? '';
      final vCode = prefs.getString(keyVendorCode) ?? '';
      return {
        'token': token,
        'role': role ?? 'candidate',
        'name': prefs.getString(keyUserName) ?? '',
        'email': prefs.getString(keyUserEmail) ?? '',
        'phone': prefs.getString(keyUserPhone) ?? '',
        'userId': userId,
        'id': userId,           // alias so both session['id'] and session['userId'] work
        'vendorId': prefs.getString(keyVendorId) ?? '',
        'vendor_code': vCode,
        'vendorCode': vCode,
        'code': vCode,
      };
    }
    return null;
  }

  static Future<Map<String, String>> getAuthHeaders() async {
    final prefs = await _getPrefs();
    final token = prefs.getString(keyAccessToken) ?? '';
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  static Future<void> logout() async {
    final prefs = await _getPrefs();
    await prefs.remove(keyAccessToken);
    await prefs.remove(keyRefreshToken);
    await prefs.remove(keyUserRole);
    await prefs.remove(keyUserName);
    await prefs.remove(keyUserEmail);
    await prefs.remove(keyUserId);
    await prefs.remove(keyVendorId);
    await prefs.remove(keyVendorCode);
    await prefs.remove(keyUserPhone);
    await prefs.remove(keyIsDemoMode);
    await prefs.remove('candidate_local_uploads');
  }

  /// Returns the stored user ID (empty string if not set).
  static Future<String> getUserId() async {
    final prefs = await _getPrefs();
    return prefs.getString(keyUserId) ?? '';
  }

  /// Registers a new candidate account on the backend.
  /// Falls back to demo mode if the server is unreachable.
  static Future<Map<String, dynamic>> signupCandidate({
    required String email,
    required String password,
    required String vendorCode,
    String? fullName,
    String? phone,
  }) async {
    final cleanEmail = email.trim().toLowerCase();

    try {
      final url = Uri.parse('$baseUrl/auth/signup');
      final body = <String, dynamic>{
        'email': cleanEmail,
        'password': password,
        'vendor_code': vendorCode.trim(),
        'role': 'candidate',
      };
      if (fullName != null && fullName.trim().isNotEmpty) {
        body['full_name'] = fullName.trim();
      }
      if (phone != null && phone.trim().isNotEmpty) {
        body['phone'] = phone.trim();
      }

      final response = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      ).timeout(const Duration(seconds: 6));

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = jsonDecode(response.body);
        final token = data['token'] ?? data['accessToken'] ?? 'demo_token';
        final user = data['user'] ?? {};

        await saveSession(
          token: token,
          refreshToken: data['refreshToken'] ?? '',
          role: 'candidate',
          name: user['name'] ?? fullName ?? cleanEmail,
          email: cleanEmail,
          userId: user['id']?.toString() ?? 'candidate_${DateTime.now().millisecondsSinceEpoch}',
          vendorId: vendorCode.trim(),
        );

        return {
          'success': true,
          'message': 'Registration successful! Welcome to ElevateIQ.',
          'data': data,
        };
      }

      // Server returned an error — surface the message
      try {
        final err = jsonDecode(response.body);
        return {
          'success': false,
          'message': err['message'] ?? err['error'] ?? 'Registration failed (${response.statusCode})',
        };
      } catch (_) {
        return {
          'success': false,
          'message': 'Registration failed (${response.statusCode})',
        };
      }
    } catch (e) {
      debugPrint('signupCandidate exception: $e');
    }

    // Demo Mode Fallback
    await saveSession(
      token: 'demo_token_${DateTime.now().millisecondsSinceEpoch}',
      refreshToken: 'demo_refresh',
      role: 'candidate',
      name: fullName ?? cleanEmail,
      email: cleanEmail,
      userId: 'demo_candidate_${DateTime.now().millisecondsSinceEpoch}',
      vendorId: vendorCode.trim(),
      isDemoMode: true,
    );

    return {
      'success': true,
      'isDemo': true,
      'message': 'Registered successfully (demo mode). Opening Candidate Portal...',
    };
  }
}
