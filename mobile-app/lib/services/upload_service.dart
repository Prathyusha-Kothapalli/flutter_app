import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../core/constants/api_constants.dart';
import 'auth_service.dart';
import 'candidate_video_store.dart';

class UploadResult {
  final bool isSuccess;
  final String? videoId;
  final String? filePath;
  final String? message;
  final Map<String, dynamic>? rawData;

  UploadResult({
    required this.isSuccess,
    this.videoId,
    this.filePath,
    this.message,
    this.rawData,
  });
}

/// Custom MultipartRequest that tracks actual uploaded bytes in real-time
class MultipartRequestWithProgress extends http.MultipartRequest {
  final void Function(int bytes, int totalBytes)? onProgress;

  MultipartRequestWithProgress(super.method, super.url, {this.onProgress});

  @override
  http.ByteStream finalize() {
    final byteStream = super.finalize();
    if (onProgress == null) return byteStream;

    final total = contentLength;
    int bytes = 0;

    return http.ByteStream(
      byteStream.transform(
        StreamTransformer.fromHandlers(
          handleData: (data, sink) {
            bytes += data.length;
            onProgress?.call(bytes, total);
            sink.add(data);
          },
        ),
      ),
    );
  }
}

class UploadService {
  UploadService._();

  static final UploadService instance = UploadService._();

  /// Uploads a video to the backend API via POST JSON (web) or multipart (mobile).
  /// Always sends the real candidate_id and vendor_id from the logged-in session.
  Future<UploadResult> uploadVideo({
    required String filePath,
    String? candidateId,
    String? vendorId,
    String? environmentTag,
    String? deviceId,
    String? recordingDate,
    int? durationSeconds,
    void Function(double progress)? onProgress,
  }) async {
    // Get real candidate_id and vendor_id from session
    final session = await AuthService.restoreSession();
    final realUserId    = candidateId ?? session?['id'] ?? session?['userId'] ?? '';
    final realVendorId  = vendorId    ?? session?['vendorId'] ?? session?['vendor_id'] ?? '';

    if (kIsWeb) {
      // Web: POST JSON to /api/v1/videos to create a real DB record
      try {
        onProgress?.call(0.3);
        final headers = await AuthService.getAuthHeaders();
        final videoTitle = '${environmentTag ?? "Recorded"} Dataset Video';

        final res = await http.post(
          Uri.parse('${ApiConstants.baseUrl}${ApiConstants.apiVersion}/videos'),
          headers: headers,
          body: jsonEncode({
            'candidate_id': realUserId.isNotEmpty ? realUserId : null,
            'vendor_id':    realVendorId.isNotEmpty ? realVendorId : null,
            'title':         videoTitle,
            'environment_tag': environmentTag ?? 'Kitchen',
            if (durationSeconds != null) 'duration': durationSeconds,
            'status':        'PENDING_QC',
            'device_id':     deviceId,
            if (recordingDate != null) 'recording_date': recordingDate,
          }),
        ).timeout(const Duration(seconds: 10));

        onProgress?.call(0.9);

        final data = jsonDecode(res.body);
        final video = data['data'] ?? {};
        final videoId = video['id']?.toString() ??
                        video['video_id']?.toString() ??
                        'WEB-VID-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}';

        // Persist locally
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('last_uploaded_video_id', videoId);
        final history = prefs.getStringList('uploaded_video_ids') ?? [];
        if (!history.contains(videoId)) {
          history.add(videoId);
          await prefs.setStringList('uploaded_video_ids', history);
        }

        CandidateVideoStore.saveUploadedVideo({
          'id': videoId,
          'title': videoTitle,
          'env': environmentTag ?? 'Kitchen',
          'status': 'Pending QC',
          'candidate_id': realUserId,
        });

        onProgress?.call(1.0);

        return UploadResult(
          isSuccess: true,
          videoId: videoId,
          filePath: filePath,
          message: 'Video uploaded successfully — Pending QC',
          rawData: data,
        );
      } catch (e) {
        onProgress?.call(0.0);
        return UploadResult(
          isSuccess: false,
          message: 'Upload failed: ${e.toString()}',
        );
      }
    }

    // Native mobile: multipart upload
    final file = File(filePath);
    if (!await file.exists()) {
      return UploadResult(
        isSuccess: false,
        message: 'Local video file does not exist at path: $filePath',
      );
    }

    try {
      final uploadUri = Uri.parse('${ApiConstants.baseUrl}${ApiConstants.videoUploadEndpoint}');
      final headers = await AuthService.getAuthHeaders();

      final request = MultipartRequestWithProgress(
        'POST',
        uploadUri,
        onProgress: (bytes, total) {
          if (total > 0) {
            final p = (bytes / total).clamp(0.0, 0.98);
            onProgress?.call(p);
          }
        },
      );

      // Add auth headers
      headers.forEach((k, v) {
        if (k != 'Content-Type') request.headers[k] = v;
      });

      // Attach file
      final multipartFile = await http.MultipartFile.fromPath('video', filePath);
      request.files.add(multipartFile);

      // Attach metadata
      if (realUserId.isNotEmpty)  request.fields['candidate_id']   = realUserId;
      if (realVendorId.isNotEmpty) request.fields['vendor_id']     = realVendorId;
      if (environmentTag != null) request.fields['environment_tag'] = environmentTag;
      if (deviceId != null)       request.fields['device_id']       = deviceId;
      if (recordingDate != null)  request.fields['recording_date']  = recordingDate;
      if (durationSeconds != null) request.fields['duration']       = durationSeconds.toString();

      onProgress?.call(0.05);
      final streamedResponse = await request.send().timeout(const Duration(seconds: 120));
      onProgress?.call(0.99);

      final response = await http.Response.fromStream(streamedResponse);
      final responseBody = jsonDecode(response.body);

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = responseBody['data'] ?? responseBody;
        final videoId = data['id'] ?? data['video_id'];

        if (videoId != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('last_uploaded_video_id', videoId.toString());
          final history = prefs.getStringList('uploaded_video_ids') ?? [];
          if (!history.contains(videoId.toString())) {
            history.add(videoId.toString());
            await prefs.setStringList('uploaded_video_ids', history);
          }

          CandidateVideoStore.saveUploadedVideo({
            'id': videoId.toString(),
            'title': '${environmentTag ?? "Recorded"} Dataset Sample',
            'env': environmentTag ?? 'Kitchen',
            'status': 'Pending QC',
            'candidate_id': realUserId,
          });
        }

        onProgress?.call(1.0);
        return UploadResult(
          isSuccess: true,
          videoId: videoId?.toString(),
          filePath: data['local_path'] ?? filePath,
          message: responseBody['message'] ?? 'Video uploaded successfully',
          rawData: responseBody,
        );
      } else {
        return UploadResult(
          isSuccess: false,
          message: responseBody['message'] ?? 'Server error ${response.statusCode}',
          rawData: responseBody,
        );
      }
    } catch (e) {
      return UploadResult(
        isSuccess: false,
        message: 'Upload failed: ${e.toString()}',
      );
    }
  }
}
