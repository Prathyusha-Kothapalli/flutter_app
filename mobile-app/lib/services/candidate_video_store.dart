import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../core/constants/api_constants.dart';
import 'auth_service.dart';
import '../utils/web_helper.dart' as web;

class CandidateVideoStore {
  static int parseDurationSeconds(dynamic val) {
    if (val == null) return 0;
    if (val is int) return val;
    if (val is double) return val.toInt();
    final str = val.toString().trim();
    if (str.isEmpty) return 0;

    final numVal = int.tryParse(str);
    if (numVal != null) return numVal;

    final cleanStr = str.replaceAll(RegExp(r'[^0-9:]'), '');
    final parts = cleanStr.split(':');
    if (parts.length == 2) {
      final m = int.tryParse(parts[0]) ?? 0;
      final s = int.tryParse(parts[1]) ?? 0;
      return (m * 60) + s;
    } else if (parts.length == 3) {
      final h = int.tryParse(parts[0]) ?? 0;
      final m = int.tryParse(parts[1]) ?? 0;
      final s = int.tryParse(parts[2]) ?? 0;
      return (h * 3600) + (m * 60) + s;
    }
    return 0;
  }

  static String formatDurationString(dynamic durVal) {
    final sec = parseDurationSeconds(durVal);
    if (sec <= 0) return 'Just Now';
    final m = (sec ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$m:$s Mins';
  }

  /// Persist newly uploaded video locally to guarantee immediate UI display
  static Future<void> saveUploadedVideo(Map<String, dynamic> video) async {
    try {
      final session = await AuthService.restoreSession();
      final currentUserId = session?['id'] ?? '';
      final cacheKey = currentUserId.isNotEmpty ? 'candidate_local_uploads_$currentUserId' : 'candidate_local_uploads';

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(cacheKey);
      List<dynamic> list = [];
      if (raw != null) {
        try {
          list = jsonDecode(raw);
        } catch (_) {}
      }

      final id = video['id']?.toString() ??
          video['video_id']?.toString() ??
          'VID-${DateTime.now().millisecondsSinceEpoch}';

      // Prevent duplicate entries
      list.removeWhere((item) => (item['id']?.toString() ?? '') == id);

      final durSec = parseDurationSeconds(video['durationSeconds'] ?? video['duration']);

      list.insert(0, {
        'id': id,
        'title': video['title'] ?? '${video['env'] ?? 'Kitchen'} Video Recording',
        'env': video['environment_tag'] ?? video['env'] ?? 'Kitchen',
        'status': video['status'] ?? 'Pending QC',
        'date': video['date'] ?? 'Today, Just Now',
        'size': video['size'] ?? 'N/A',
        'duration': formatDurationString(durSec),
        'durationSeconds': durSec,
        'candidateId': currentUserId.isNotEmpty ? currentUserId : (video['candidate_id'] ?? video['candidateId'] ?? ''),
      });

      await prefs.setString(cacheKey, jsonEncode(list));

      if (kIsWeb) {
        try {
          final bc = web.BroadcastChannelStub('platform_realtime_channel');
          bc.postMessage(jsonEncode({'type': 'VIDEO_UPLOADED', 'payload': list}));
          bc.close();
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('Error saving local candidate video: $e');
    }
  }

  /// Unified loader for candidate uploaded videos with fallback mechanisms
  static Future<List<Map<String, dynamic>>> getUploadedVideos() async {
    final List<Map<String, dynamic>> allVideos = [];
    final Set<String> processedVideoIds = {};

    try {
      final headers = await AuthService.getAuthHeaders();
      final session = await AuthService.restoreSession();
      final currentUserId = session?['id'] ?? '';
      final cacheKey = currentUserId.isNotEmpty ? 'candidate_local_uploads_$currentUserId' : 'candidate_local_uploads';

      // 1. Fetch from PostgreSQL REST API strictly scoped to authenticated candidate
      final queryParam = currentUserId.isNotEmpty ? '?candidate_id=$currentUserId' : '';
      final url = Uri.parse('${ApiConstants.baseUrl}${ApiConstants.apiVersion}/videos$queryParam');
      final res = await http.get(url, headers: headers).timeout(const Duration(seconds: 8));

      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        final List items = body['data'] is List ? body['data'] : (body['data']?['items'] ?? []);
        debugPrint('[CandidateVideoStore] ✅ Backend API fetch success for Candidate: "$currentUserId". Received ${items.length} videos.');

        for (var vid in items) {
          final id = vid['id']?.toString() ?? '';
          if (id.isNotEmpty && processedVideoIds.contains(id)) continue;
          if (id.isNotEmpty) processedVideoIds.add(id);

          final st = (vid['status'] ?? 'QC_PENDING').toString().toUpperCase().replaceAll(' ', '_');
          String statusText = 'Waiting for QC';
          if (st == 'QC_PENDING' || st == 'PENDING_QC' || st == 'PENDING' || st == 'UPLOADED' || st == 'ASSIGNED_QC' || st == 'IN_REVIEW') {
            statusText = 'Waiting for QC';
          } else if (st == 'QC_REJECTED') {
            statusText = 'QC Rejected';
          } else if (st == 'ADMIN_PENDING' || st == 'QC_APPROVED' || st == 'PENDING_ADMIN_REVIEW') {
            statusText = 'Waiting for Admin';
          } else if (st == 'ADMIN_REJECTED' || st == 'REJECTED') {
            statusText = 'Admin Rejected';
          } else if (st == 'FINAL_APPROVED' || st == 'APPROVED') {
            statusText = 'Final Approved';
          } else if (st.contains('REJECT')) {
            statusText = 'QC Rejected';
          }

          final durSec = parseDurationSeconds(vid['duration']);

          allVideos.add({
            'id': id.isNotEmpty ? id : 'VID-${allVideos.length + 1}',
            'title': vid['title'] ?? 'Dataset Video Recording',
            'env': vid['environment_tag'] ?? 'Kitchen',
            'status': statusText,
            'date': vid['recording_date'] != null ? 'Uploaded' : 'Today, Just Now',
            'size': 'N/A',
            'duration': formatDurationString(durSec),
            'durationSeconds': durSec,
            'reason': vid['rejection_reason'] ?? '',
            'candidateId': currentUserId,
          });
        }

        // Update local device account-specific cache with authenticated server data
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(cacheKey, jsonEncode(allVideos));
        } catch (e) {
          debugPrint('[CandidateVideoStore] ⚠️ Failed to update account cache: $e');
        }
        return allVideos;
      } else if (res.statusCode == 401 || res.statusCode == 403) {
        debugPrint('[CandidateVideoStore] 🔒 Auth Error (HTTP ${res.statusCode}): Invalid/Expired JWT Token. ${res.body}');
      } else {
        debugPrint('[CandidateVideoStore] ❌ Server/DB Error (HTTP ${res.statusCode}): ${res.body}');
      }
    } catch (e) {
      debugPrint('[CandidateVideoStore] 🚨 API Network Exception: $e');
    }

    // 2. Load from SharedPreferences candidate-account-specific local cache ONLY as offline fallback
    try {
      final session = await AuthService.restoreSession();
      final currentUserId = session?['id'] ?? '';
      final cacheKey = currentUserId.isNotEmpty ? 'candidate_local_uploads_$currentUserId' : 'candidate_local_uploads';

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(cacheKey);
      if (raw != null) {
        final List<dynamic> list = jsonDecode(raw);
        for (var item in list) {
          final candId = (item['candidateId'] ?? item['candidate_id'] ?? '').toString();
          if (currentUserId.isNotEmpty && candId.isNotEmpty && candId != currentUserId) {
            continue; // Prevent videos from another candidate account appearing
          }

          final id = item['id']?.toString() ?? '';
          if (id.isNotEmpty && processedVideoIds.contains(id)) continue;
          if (id.isNotEmpty) processedVideoIds.add(id);

          final durSec = parseDurationSeconds(item['durationSeconds'] ?? item['duration']);

          allVideos.add({
            'id': id.isNotEmpty ? id : 'VID-${allVideos.length + 1}',
            'title': item['title'] ?? 'Uploaded Video Recording',
            'env': item['env'] ?? 'Kitchen',
            'status': item['status'] ?? 'Pending QC',
            'date': item['date'] ?? 'Today, Just Now',
            'size': item['size'] ?? 'N/A',
            'duration': formatDurationString(durSec),
            'durationSeconds': durSec,
            'reason': item['reason'] ?? '',
            'candidateId': currentUserId,
          });
        }
      }
    } catch (_) {}

    // 3. Fetch from Web localStorage platform_qc_submissions
    if (kIsWeb) {
      try {
        final raw = web.localStorageGet('platform_qc_submissions');
        if (raw != null) {
          final List<dynamic> list = jsonDecode(raw);
          for (var item in list) {
            final id = item['id']?.toString() ?? '';
            if (id.isNotEmpty && processedVideoIds.contains(id)) continue;
            if (id.isNotEmpty) processedVideoIds.add(id);

            final durSec = parseDurationSeconds(item['durationSeconds'] ?? item['duration']);

            allVideos.add({
              'id': id.isNotEmpty ? id : 'VID-${allVideos.length + 1}',
              'title': item['title'] ?? 'Uploaded Video',
              'env': item['env'] ?? 'Kitchen',
              'status': item['status'] == 'Pending' ? 'Pending QC' : (item['status'] ?? 'Approved'),
              'date': item['time'] ?? 'Just Now',
              'size': item['size'] ?? 'N/A',
              'duration': formatDurationString(durSec),
              'durationSeconds': durSec,
              'reason': item['rejectionReason'] ?? '',
            });
          }
        }
      } catch (_) {}
    }

    return allVideos;
  }
}

