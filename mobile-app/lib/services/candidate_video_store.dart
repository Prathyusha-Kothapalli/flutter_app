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
      if (cacheKey != 'candidate_local_uploads') {
        final globalRaw = prefs.getString('candidate_local_uploads');
        List<dynamic> globalList = [];
        if (globalRaw != null) {
          try {
            globalList = jsonDecode(globalRaw);
          } catch (_) {}
        }
        globalList.removeWhere((item) => (item['id']?.toString() ?? '') == id);
        globalList.insert(0, list.first);
        await prefs.setString('candidate_local_uploads', jsonEncode(globalList));
      }

      if (kIsWeb) {
        try {
          final rawQc = web.localStorageGet('platform_qc_submissions');
          List<dynamic> qcList = [];
          if (rawQc != null) {
            try {
              qcList = jsonDecode(rawQc);
            } catch (_) {}
          }
          qcList.removeWhere((item) => (item['id']?.toString() ?? item['raw_id']?.toString() ?? '') == id);
          qcList.insert(0, {
            'id': id,
            'ticket_code': 'TKT-${id.length > 8 ? id.substring(0, 8) : id}',
            'title': list.first['title'],
            'candidateName': 'Candidate',
            'vendor': 'Vendor',
            'duration': formatDurationString(durSec),
            'durationSeconds': durSec,
            'env': list.first['env'],
            'status': 'Pending',
            'assignedTo': 'QC Specialist',
          });
          web.localStorageSet('platform_qc_submissions', jsonEncode(qcList));

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

      // 1. Fetch from PostgreSQL REST API
      try {
        final queryParam = currentUserId.isNotEmpty ? '?candidate_id=$currentUserId' : '';
        final url = Uri.parse('${ApiConstants.baseUrl}${ApiConstants.apiVersion}/videos$queryParam');
        final res = await http.get(url, headers: headers).timeout(const Duration(seconds: 6));

        if (res.statusCode == 200) {
          final body = jsonDecode(res.body);
          final List items = body['data'] is List ? body['data'] : (body['data']?['items'] ?? []);
          debugPrint('[CandidateVideoStore] ✅ Backend API returned ${items.length} videos.');

          for (var vid in items) {
            final id = vid['id']?.toString() ?? '';
            if (id.isNotEmpty && processedVideoIds.contains(id)) continue;
            if (id.isNotEmpty) processedVideoIds.add(id);

            final st = (vid['status'] ?? 'QC_PENDING').toString().toUpperCase().replaceAll(' ', '_');
            String statusText = 'Pending QC';
            if (st == 'FINAL_APPROVED' || st == 'APPROVED') {
              statusText = 'Approved';
            } else if (st.contains('REJECT')) {
              statusText = 'Rejected';
            } else {
              statusText = 'Pending QC';
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
        }
      } catch (e) {
        debugPrint('[CandidateVideoStore] API fetch notice: $e');
      }

      // 2. ALWAYS merge with SharedPreferences local storage (both account-specific and generic keys)
      try {
        final prefs = await SharedPreferences.getInstance();
        final keysToCheck = [cacheKey, 'candidate_local_uploads', 'candidate_videos'];
        for (var key in keysToCheck) {
          final raw = prefs.getString(key);
          if (raw != null) {
            final List<dynamic> list = jsonDecode(raw);
            for (var item in list) {
              final id = item['id']?.toString() ?? '';
              if (id.isNotEmpty && processedVideoIds.contains(id)) continue;
              if (id.isNotEmpty) processedVideoIds.add(id);

              final durSec = parseDurationSeconds(item['durationSeconds'] ?? item['duration']);
              final rawSt = (item['status'] ?? 'Pending QC').toString();
              String statusText = 'Pending QC';
              if (rawSt.toLowerCase().contains('approve')) {
                statusText = 'Approved';
              } else if (rawSt.toLowerCase().contains('reject')) {
                statusText = 'Rejected';
              } else {
                statusText = 'Pending QC';
              }

              allVideos.add({
                'id': id.isNotEmpty ? id : 'VID-${allVideos.length + 1}',
                'title': item['title'] ?? 'Uploaded Video Recording',
                'env': item['env'] ?? 'Kitchen',
                'status': statusText,
                'date': item['date'] ?? 'Today, Just Now',
                'size': item['size'] ?? 'N/A',
                'duration': formatDurationString(durSec),
                'durationSeconds': durSec,
                'reason': item['reason'] ?? '',
                'candidateId': currentUserId,
              });
            }
          }
        }

        // Cache unified list to prevent blank screens
        if (allVideos.isNotEmpty) {
          await prefs.setString(cacheKey, jsonEncode(allVideos));
        }
      } catch (e) {
        debugPrint('[CandidateVideoStore] Local cache parse error: $e');
      }

      // 3. Merge Web localStorage if on Web platform
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
    } catch (e) {
      debugPrint('[CandidateVideoStore] Unexpected error: $e');
    }

    return allVideos;
  }
}

