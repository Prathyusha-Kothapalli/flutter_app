import 'dart:async';
import 'dart:convert';
import '../../utils/web_helper.dart' as web;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../core/theme/app_colors.dart';
import '../../services/auth_service.dart';
import '../../services/device_service.dart';
import '../../services/upload_service.dart';
import '../../services/candidate_video_store.dart';
import '../../widgets/powered_by_footer.dart';

class VideoUploadScreen extends StatefulWidget {
  final String videoPath;
  final String? environmentTag;

  const VideoUploadScreen({
    super.key,
    this.videoPath = '',
    this.environmentTag,
  });

  @override
  State<VideoUploadScreen> createState() => _VideoUploadScreenState();
}

class _VideoUploadScreenState extends State<VideoUploadScreen> {
  bool _isUploading = false;
  double _uploadProgress = 0.0;
  UploadResult? _uploadResult;
  String _activeVideoPath = '';
  String? _activeEnvTag;
  int _fileSize = 10485760; // 10 MB default
  String? _candidateName;
  String? _candidateId;
  String? _candidatePhone;

  // History of Uploads
  List<Map<String, dynamic>> _uploadsHistory = [];
  bool _isLoadingHistory = true;

  @override
  void initState() {
    super.initState();
    _activeVideoPath = widget.videoPath;
    _activeEnvTag = widget.environmentTag ?? 'Kitchen';
    _loadCandidateInfo();
    _loadStoredHistory();
    _subscribeRealtime();
  }

  Future<void> _loadCandidateInfo() async {
    try {
      final session = await AuthService.restoreSession();
      if (session != null && mounted) {
        setState(() {
          _candidateName = session['name'];
          _candidateId = session['id'];
          _candidatePhone = session['phone'];
        });
      }
    } catch (_) {}
  }

  void _subscribeRealtime() {
    if (kIsWeb) {
      try {
        final bc = web.BroadcastChannelStub('platform_realtime_channel');
        bc.onMessage.listen((event) {
          _loadStoredHistory();
        });
      } catch (_) {}
    }
  }

  Future<void> _loadStoredHistory() async {
    if (mounted) setState(() => _isLoadingHistory = true);
    try {
      final videos = await CandidateVideoStore.getUploadedVideos();
      if (mounted) {
        setState(() {
          _uploadsHistory = videos;
          _isLoadingHistory = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading uploads history: $e');
      if (mounted) setState(() => _isLoadingHistory = false);
    }
  }

  Future<void> _pickAndSelectFile() async {
    final mockName = 'gallery_recording_${DateTime.now().millisecondsSinceEpoch}.mp4';
    setState(() {
      _activeVideoPath = mockName;
      _activeEnvTag = _activeEnvTag ?? 'Kitchen';
      _uploadResult = null;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Selected video file: $mockName'),
        backgroundColor: AppColors.primary,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _getRealtimeUploadTimestamp() {
    final now = DateTime.now();
    final hour = now.hour > 12 ? now.hour - 12 : (now.hour == 0 ? 12 : now.hour);
    final minute = now.minute.toString().padLeft(2, '0');
    final ampm = now.hour >= 12 ? 'PM' : 'AM';
    return 'Today, $hour:$minute $ampm';
  }

  Future<void> _startUpload() async {
    if (_isUploading) return;

    setState(() {
      _isUploading = true;
      _uploadProgress = 0.05;
      _uploadResult = null;
    });

    final deviceId = await DeviceService.instance.getDeviceId();

    final result = await UploadService.instance.uploadVideo(
      filePath: _activeVideoPath.isEmpty ? 'recorded_sample.mp4' : _activeVideoPath,
      environmentTag: _activeEnvTag,
      deviceId: deviceId,
      onProgress: (p) {
        if (mounted) {
          setState(() {
            _uploadProgress = p;
          });
        }
      },
    );

    if (mounted) {
      final uploadTimestamp = _getRealtimeUploadTimestamp();

      setState(() {
        _isUploading = false;
        _uploadProgress = result.isSuccess ? 1.0 : 0.0;
        _uploadResult = result;
      });

      if (result.isSuccess) {
        final newVideoId = result.videoId ?? 'VID-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}';

        final sizeStr = _fileSize > 0
            ? '${(_fileSize / (1024 * 1024)).toStringAsFixed(1)} MB'
            : 'N/A';

        // Add to history
        final newHistoryItem = {
          'id': newVideoId,
          'title': '${_activeEnvTag ?? "Recorded"} Dataset Sample',
          'env': _activeEnvTag ?? 'Kitchen',
          'status': 'Pending QC',
          'date': uploadTimestamp,
          'size': sizeStr,
          'duration': 'Just Now',
        };

        setState(() {
          _uploadsHistory.insert(0, newHistoryItem);
        });

        // Persist to CandidateVideoStore local storage
        CandidateVideoStore.saveUploadedVideo(newHistoryItem);

        // Sync to Admin QC Review queue
        if (kIsWeb) {
          try {
            final raw = web.localStorageGet('platform_qc_submissions');
            List<dynamic> list = [];
            if (raw != null) {
              list = jsonDecode(raw);
            }
            final newSub = {
              'id': newVideoId,
              'title': '${_activeEnvTag ?? "Recorded"} Dataset Sample',
              'candidateId': _candidateId ?? 'N/A',
              'candidateName': _candidateName ?? 'N/A',
              'candidatePhone': _candidatePhone ?? 'N/A',
              'vendor': 'N/A',
              'duration': 'Just Now',
              'status': 'Pending',
              'env': _activeEnvTag ?? 'Kitchen',
              'time': uploadTimestamp,
              'size': sizeStr,
              'videoUrl': result.filePath ?? '',
              'rejectionReason': '',
            };
            list.insert(0, newSub);
            web.localStorageSet('platform_qc_submissions', jsonEncode(list));

            // Broadcast to all open tabs in real-time
            try {
              final bc = web.BroadcastChannelStub('platform_realtime_channel');
              bc.postMessage(jsonEncode({'type': 'QC_STORE_UPDATED', 'payload': list}));
              bc.close();
            } catch (_) {}
          } catch (e) {
            debugPrint('Error syncing QC submission: $e');
          }
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Upload Complete! Video ID: $newVideoId (Sent to Admin QC)'),
            backgroundColor: AppColors.success,
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.message ?? 'Upload failed'),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _saveAsDraft() async {
    final draftId = 'DRAFT-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}';
    final draftItem = {
      'id': draftId,
      'title': '${_activeEnvTag ?? "Recorded"} Draft Recording',
      'env': _activeEnvTag ?? 'Kitchen',
      'status': 'Draft',
      'time': 'Saved to Drafts',
      'date': 'Today',
      'size': '10.0 MB',
      'duration': '00:45',
      'videoPath': _activeVideoPath,
    };

    if (kIsWeb) {
      try {
        final raw = web.localStorageGet('platform_candidate_drafts');
        List<dynamic> draftsList = [];
        if (raw != null) {
          draftsList = jsonDecode(raw);
        }
        draftsList.insert(0, draftItem);
        web.localStorageSet('platform_candidate_drafts', jsonEncode(draftsList));
      } catch (e) {
        debugPrint('Draft save error: $e');
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Video saved to Drafts! 📂 View in "Draft Videos" card on Home screen.'),
          backgroundColor: Color(0xFF2563EB),
          behavior: SnackBarBehavior.floating,
        ),
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text(
          'My Uploads & Video Dispatch',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Color(0xFF0F172A),
            fontSize: 18,
          ),
        ),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF0F172A),
        iconTheme: const IconThemeData(color: Color(0xFF0F172A)),
        elevation: 0.5,
        scrolledUnderElevation: 0.5,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF2563EB)),
            onPressed: () {
              _loadStoredHistory();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Uploads list updated ✓'), duration: Duration(seconds: 1)),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // New Recording Dispatch / Save Draft Action Card (Only shown when a new unuploaded recorded clip is pending)
              if (_activeVideoPath.isNotEmpty && _uploadResult == null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, 3)),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: const BoxDecoration(color: Color(0xFFEFF6FF), shape: BoxShape.circle),
                            child: const Icon(Icons.videocam_rounded, color: Color(0xFF2563EB), size: 22),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _activeVideoPath,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF0F172A)),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text('Tag: ${_activeEnvTag ?? "General"}', style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _saveAsDraft,
                              icon: const Icon(Icons.folder_special_rounded, color: Color(0xFF2563EB), size: 18),
                              label: const Text('Save to Draft', style: TextStyle(color: Color(0xFF2563EB), fontWeight: FontWeight.bold)),
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: Color(0xFF2563EB)),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _isUploading ? null : _startUpload,
                              icon: _isUploading
                                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                                  : const Icon(Icons.cloud_upload_rounded, color: Colors.white, size: 18),
                              label: Text(_isUploading ? 'Uploading...' : 'Upload Now', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF2563EB),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

              // Top Summary Stats Banner
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF2563EB), Color(0xFF1D4ED8)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(color: const Color(0xFF2563EB).withAlpha(60), blurRadius: 14, offset: const Offset(0, 4)),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('DATASET UPLOADS SUMMARY', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 0.8)),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Total Videos', style: TextStyle(color: Colors.white70, fontSize: 12)),
                            const SizedBox(height: 2),
                            Text('${_uploadsHistory.length}', style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold)),
                          ],
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('QC Approved', style: TextStyle(color: Colors.white70, fontSize: 12)),
                            const SizedBox(height: 2),
                            Text(
                              '${_uploadsHistory.where((i) {
                                final st = (i['status'] ?? '').toString().toLowerCase();
                                return st.contains('approve');
                              }).length}',
                              style: const TextStyle(color: Color(0xFF34D399), fontSize: 26, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Pending QC', style: TextStyle(color: Colors.white70, fontSize: 12)),
                            const SizedBox(height: 2),
                            Text(
                              '${_uploadsHistory.where((i) {
                                final st = (i['status'] ?? '').toString().toLowerCase();
                                return !st.contains('approve') && !st.contains('reject');
                              }).length}',
                              style: const TextStyle(color: Color(0xFFFBBF24), fontSize: 26, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // All Uploads Section Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'All Uploaded Videos',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.textPrimaryLight),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withAlpha(20),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${_uploadsHistory.length} Total',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.primary),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // All Uploads List Cards
              if (_isLoadingHistory)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: const Center(
                    child: CircularProgressIndicator(color: Color(0xFF2563EB)),
                  ),
                )
              else if (_uploadsHistory.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  child: const Column(
                    children: [
                      Icon(Icons.cloud_upload_outlined, size: 54, color: Color(0xFF94A3B8)),
                      SizedBox(height: 12),
                      Text(
                        'No Uploaded Videos Yet',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF0F172A)),
                      ),
                      SizedBox(height: 6),
                      Text(
                        'Record new dataset video clips using your camera and upload them here.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                      ),
                    ],
                  ),
                )
              else
                ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _uploadsHistory.length,
                itemBuilder: (ctx, idx) {
                  final item = _uploadsHistory[idx];
                  final status = item['status']?.toString() ?? '';

                  Color statusColor = AppColors.success;
                  if (status == 'Pending QC' || status == 'Pending') {
                    statusColor = const Color(0xFFF59E0B);
                  } else if (status == 'Rejected') {
                    statusColor = AppColors.error;
                  }

                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withAlpha(5), blurRadius: 8, offset: const Offset(0, 2)),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                CircleAvatar(
                                  radius: 18,
                                  backgroundColor: statusColor.withAlpha(20),
                                  child: Icon(
                                    status == 'Approved'
                                        ? Icons.check_circle_rounded
                                        : (status == 'Rejected' ? Icons.cancel_rounded : Icons.hourglass_top_rounded),
                                    color: statusColor,
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item['title']?.toString() ?? '',
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppColors.textPrimaryLight),
                                    ),
                                    Text(
                                      'ID: ${item['id']}',
                                      style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: AppColors.textSecondaryLight),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: statusColor.withAlpha(20),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                status,
                                style: TextStyle(color: statusColor, fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                        const Divider(height: 20),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.calendar_today_rounded, size: 14, color: Colors.grey),
                                const SizedBox(width: 4),
                                Text(item['date']?.toString() ?? '', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                              ],
                            ),
                            Row(
                              children: [
                                const Icon(Icons.timer_rounded, size: 14, color: Colors.grey),
                                const SizedBox(width: 4),
                                Text(item['duration']?.toString() ?? '', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                const SizedBox(width: 12),
                                const Icon(Icons.sd_card_rounded, size: 14, color: Colors.grey),
                                const SizedBox(width: 4),
                                Text(item['size']?.toString() ?? '', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ],
                        ),
                        if (status == 'Rejected' && (item['reason']?.toString() ?? '').isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppColors.error.withAlpha(15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.info_outline_rounded, size: 16, color: AppColors.error),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Rejection Reason: ${item['reason']}',
                                    style: const TextStyle(fontSize: 12, color: AppColors.error, fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              const PoweredByFooter(),
            ],
          ),
        ),
      ),
    );
  }
}
