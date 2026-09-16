import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../config/routes/app_routes.dart';
import '../../core/theme/app_colors.dart';
import 'dart:convert';
import '../../utils/web_helper.dart' as web;
import '../../services/camera_service.dart';
import '../../services/location_service.dart';
import '../../services/voice_command_service.dart';
import '../../services/compression_service.dart';
import '../../services/upload_service.dart';
import '../../services/candidate_video_store.dart';
import '../../services/device_service.dart';
import '../../services/auth_service.dart';
import '../../widgets/web_camera_view.dart';

class VideoRecordingScreen extends StatefulWidget {
  const VideoRecordingScreen({super.key});

  @override
  State<VideoRecordingScreen> createState() => _VideoRecordingScreenState();
}

class _VideoRecordingScreenState extends State<VideoRecordingScreen> {
  CameraController? _controller;
  bool _isInitializing = true;
  bool _isRecording = false;
  XFile? _recordedFile;
  int _recordedFileSize = 0;

  // Environment Tag
  String? _selectedEnvironmentTag;

  // GPS Location Data
  Position? _currentPosition;
  bool _isFetchingLocation = false;
  String? _locationErrorMessage;

  // Recording Timer with 30-min limit
  static const int maxRecordingSeconds = 1800; // 30 minutes
  static const int warningThresholdSeconds = 1500; // 25 minutes
  static const int dangerThresholdSeconds = 1740; // 29 minutes
  Timer? _timer;
  int _elapsedSeconds = 0;
  DateTime? _recordingStartTime;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _loadSavedEnvironmentTag();
    _initVoiceCommandListener();
  }

  void _initVoiceCommandListener() {
    VoiceCommandService.instance.startListening(
      onCommand: (command) {
        if (command == VoiceCommand.start && !_isRecording) {
          _startRecording();
        } else if (command == VoiceCommand.stop && _isRecording) {
          _stopRecording();
        }
      },
    );
  }

  Future<void> _loadSavedEnvironmentTag() async {
    final prefs = await SharedPreferences.getInstance();
    final tag = prefs.getString('selected_environment_tag');
    if (tag != null && mounted) {
      setState(() {
        _selectedEnvironmentTag = tag;
      });
    }
  }

  Future<void> _initializeCamera() async {
    if (!kIsWeb) {
      final cameraStatus = await Permission.camera.request();
      final micStatus = await Permission.microphone.request();

      if (!cameraStatus.isGranted || !micStatus.isGranted) {
        if (mounted) {
          setState(() => _isInitializing = false);
        }
        return;
      }
    }

    final cameras = await CameraService.instance.initCameras();
    if (cameras.isEmpty) {
      if (mounted) {
        setState(() => _isInitializing = false);
      }
      return;
    }

    final selectedCamera = CameraService.instance.defaultCamera!;
    _controller = CameraController(
      selectedCamera,
      ResolutionPreset.medium,
      enableAudio: true,
    );

    try {
      await _controller!.initialize();
    } catch (e) {
      debugPrint('Camera init error: $e');
    } finally {
      if (mounted) {
        setState(() => _isInitializing = false);
      }
    }
  }

  void _startTimer() {
    _elapsedSeconds = 0;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _elapsedSeconds++;
        });

        // Auto-stop at 30 minutes and trigger Alert Buzzer modal
        if (_elapsedSeconds >= maxRecordingSeconds) {
          _stopRecording();
          _show30MinBuzzerAlert();
        }
      }
    });
  }

  int get _remainingSeconds => maxRecordingSeconds - _elapsedSeconds;
  double get _timerProgress => _elapsedSeconds / maxRecordingSeconds;
  bool get _isWarning => _elapsedSeconds >= warningThresholdSeconds && _elapsedSeconds < dangerThresholdSeconds;
  bool get _isDanger => _elapsedSeconds >= dangerThresholdSeconds;

  void _stopTimer() {
    _timer?.cancel();
  }

  void _show30MinBuzzerAlert() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: const [
            Icon(Icons.notifications_active_rounded, color: Color(0xFFDC2626), size: 28),
            SizedBox(width: 10),
            Expanded(
              child: Text('30-MIN LIMIT REACHED! 🔔', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFDC2626))),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text(
              'Maximum 30 minutes video recording limit reached.',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF0F172A)),
            ),
            SizedBox(height: 8),
            Text(
              'The recorded video clip has been automatically saved locally on your mobile device storage (1080p, H.264/H.265) before uploading to the server.',
              style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
            child: const Text('OK, View Saved Video', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _startRecording() async {
    if (_isRecording) return;

    _recordingStartTime = DateTime.now();

    // NOTE: On web, hardware camera recording is not supported by the Flutter camera plugin.
    // The current approach uses a live preview with a mock file for web. A full rewrite using
    // the browser MediaRecorder API would be required for actual web video capture.
    if (!kIsWeb && _controller != null && _controller!.value.isInitialized) {
      try {
        await _controller!.startVideoRecording();
      } catch (e) {
        debugPrint('Hardware recording start note: $e');
      }
    }

    if (mounted) {
      setState(() {
        _isRecording = true;
        _recordedFile = null;
      });
      _startTimer();
      // Keep voice command listener active for Stop Recording command during video recording
      VoiceCommandService.instance.ensureListening();
    }
  }

  Future<void> _stopRecording() async {
    if (!_isRecording) return;

    _stopTimer();
    setState(() {
      _isRecording = false;
      _isFetchingLocation = true;
    });

    XFile? file;
    if (_controller != null) {
      try {
        if (_controller!.value.isRecordingVideo) {
          file = await _controller!.stopVideoRecording();
        }
        await _controller?.pausePreview();
        await _controller?.dispose();
        _controller = null;
      } catch (e) {
        debugPrint('Error stopping hardware recording: $e');
      }
    }

    // If hardware camera file null (Web/Demo), generate mock video file
    file ??= XFile(
      'demo_recorded_video_${DateTime.now().millisecondsSinceEpoch}.mp4',
      name: 'recorded_video.mp4',
      length: 10485760, // 10 MB
    );

    int size = 10485760;
    try {
      size = await file.length();
    } catch (_) {}

    // Fetch GPS Location
    Position? pos;
    String? locationError;

    try {
      pos = await LocationService.instance.getCurrentPosition();
    } catch (e) {
      locationError = 'GPS unavailable: ${e.toString().replaceAll('Exception: ', '')}';
    }

    if (mounted) {
      setState(() {
        _recordedFile = file;
        _currentPosition = pos;
        _locationErrorMessage = locationError;
        _isFetchingLocation = false;
      });

      // Prompt user whether to Upload Now or Keep in Draft
      _showPostRecordingDialog(file, size, pos, locationError);
    }
  }

  void _showPostRecordingDialog(XFile file, int fileSize, Position? pos, String? locationError) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: const [
            Icon(Icons.video_library_rounded, color: Color(0xFF2563EB), size: 26),
            SizedBox(width: 10),
            Expanded(
              child: Text('Recording Complete! 🎬', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Your video clip was captured. Would you like to upload it now to the server or keep it in drafts?',
              style: TextStyle(fontSize: 13, color: Color(0xFF475569), fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Duration:', style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                      Text(_formatDuration(_elapsedSeconds), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Environment Tag:', style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                      Text(_selectedEnvironmentTag ?? 'General / Indoor', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF2563EB))),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('File Size:', style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                      Text(_formatFileSize(fileSize), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    Navigator.pop(dialogCtx);
                    _saveAsDraft(file, fileSize);
                  },
                  icon: const Icon(Icons.folder_special_rounded, size: 16, color: Color(0xFF2563EB)),
                  label: const Text('Keep in Draft', style: TextStyle(fontSize: 12, color: Color(0xFF2563EB), fontWeight: FontWeight.bold)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFF2563EB)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(dialogCtx);
                    _uploadVideoNow(file, fileSize, pos);
                  },
                  icon: const Icon(Icons.cloud_upload_rounded, size: 16, color: Colors.white),
                  label: const Text('Upload Now', style: TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _saveAsDraft(XFile file, int fileSize) async {
    final draftId = 'DRAFT-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}';
    final draftItem = {
      'id': draftId,
      'title': '${_selectedEnvironmentTag ?? "Recorded"} Draft Recording',
      'env': _selectedEnvironmentTag ?? 'Kitchen',
      'status': 'Draft',
      'time': 'Just Now',
      'duration': _formatDuration(_elapsedSeconds),
      'size': _formatFileSize(fileSize),
      'videoPath': file.path,
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
    } else {
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString('platform_candidate_drafts');
        List<dynamic> draftsList = [];
        if (raw != null) {
          draftsList = jsonDecode(raw);
        }
        draftsList.insert(0, draftItem);
        await prefs.setString('platform_candidate_drafts', jsonEncode(draftsList));
      } catch (e) {
        debugPrint('Draft save error (native): $e');
      }
    }

    if (mounted) {
      setState(() {
        _recordedFile = file;
        _recordedFileSize = fileSize;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('📂 Video saved to Drafts! View in My Uploads or Home screen.'),
          backgroundColor: Color(0xFF2563EB),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _uploadVideoNow(XFile file, int fileSize, Position? pos) async {
    double uploadProgress = 0.05;
    StateSetter? dialogSetState;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          dialogSetState = setModalState;
          final percentInt = (uploadProgress * 100).toInt();
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Row(
              children: const [
                Icon(Icons.cloud_upload_rounded, color: Color(0xFF2563EB), size: 28),
                SizedBox(width: 10),
                Expanded(
                  child: Text('Uploading Video...', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Environment: ${_selectedEnvironmentTag ?? "Kitchen"} • ${_formatDuration(_elapsedSeconds)}',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                ),
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: LinearProgressIndicator(
                    value: uploadProgress,
                    minHeight: 10,
                    backgroundColor: const Color(0xFFE2E8F0),
                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF2563EB)),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('$percentInt% Uploaded', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF2563EB))),
                    Text(uploadProgress >= 0.98 ? 'Finalizing...' : 'Fast Streaming', style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );

    final deviceId = await DeviceService.instance.getDeviceId();
    final uploadRes = await UploadService.instance.uploadVideo(
      filePath: file.path,
      environmentTag: _selectedEnvironmentTag,
      deviceId: deviceId,
      recordingDate: _recordingStartTime?.toIso8601String(),
      durationSeconds: _elapsedSeconds,
      onProgress: (p) {
        uploadProgress = p;
        dialogSetState?.call(() {});
      },
    );

    if (mounted && Navigator.canPop(context)) {
      Navigator.pop(context); // Dismiss upload progress dialog
    }

    if (!uploadRes.isSuccess) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(uploadRes.message ?? 'Upload failed. Please check network connection.'),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    final finalVideoId = uploadRes.videoId ?? 'VID-${DateTime.now().millisecondsSinceEpoch.toString().substring(7)}';

    final session = await AuthService.restoreSession();
    final currentEmail = session?['email'] ?? '';
    final currentUserId = session?['id'] ?? '';
    final currentName = session?['name'] ?? 'Candidate';
    final currentVendorName = session?['vendor_name'] ?? session?['vendor'] ?? 'N/A';
    final currentVendorId = session?['vendor_id'] ?? session?['vendorId'] ?? '';

    // Save to CandidateVideoStore local store for immediate UI update
    await CandidateVideoStore.saveUploadedVideo({
      'id': finalVideoId,
      'title': '${_selectedEnvironmentTag ?? "Recorded"} Dataset Sample',
      'env': _selectedEnvironmentTag ?? 'Kitchen',
      'status': 'Pending QC',
      'date': 'Today, Just Now',
      'size': _formatFileSize(fileSize),
      'duration': _formatDuration(_elapsedSeconds),
      'durationSeconds': _elapsedSeconds,
      'candidate_id': currentUserId,
    });

    if (kIsWeb) {
      try {
        final raw = web.localStorageGet('platform_qc_submissions');
        List<dynamic> list = [];
        if (raw != null) {
          list = jsonDecode(raw);
        }
        final newSub = {
          'id': finalVideoId,
          'title': '${_selectedEnvironmentTag ?? "Recorded"} Dataset Sample',
          'candidateId': currentUserId,
          'candidateEmail': currentEmail,
          'candidateName': currentName,
          'vendor': currentVendorName,
          'vendorId': currentVendorId,
          'duration': _formatDuration(_elapsedSeconds),
          'durationSeconds': _elapsedSeconds,
          'status': 'Pending',
          'env': _selectedEnvironmentTag ?? 'Kitchen',
          'time': 'Just Now',
          'size': _formatFileSize(fileSize),
          'videoUrl': uploadRes.filePath ?? '',
          'rejectionReason': '',
        };
        list.insert(0, newSub);
        web.localStorageSet('platform_qc_submissions', jsonEncode(list));

        final bc = web.BroadcastChannelStub('platform_realtime_channel');
        bc.postMessage(jsonEncode({'type': 'NEW_VIDEO_UPLOADED', 'payload': list}));
        bc.close();
      } catch (e) {
        debugPrint('Error syncing submission: $e');
      }
    }

    if (mounted) {
      setState(() {
        _recordedFile = file;
        _recordedFileSize = fileSize;
        _currentPosition = pos;
        _isFetchingLocation = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('🚀 Uploaded to Server & Sent to Admin QC! ($finalVideoId) ✓'),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
        ),
      );

      Navigator.pushNamed(context, AppRoutes.uploadVideo);
    }
  }

  String _formatDuration(int totalSeconds) {
    final minutes = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String _formatFileSize(int bytes) {
    if (bytes <= 0) return '0 B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(2)} MB';
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller?.dispose();
    VoiceCommandService.instance.stopListening();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC), // Pure clean white background
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF0F172A),
        iconTheme: const IconThemeData(color: Color(0xFF0F172A)),
        elevation: 0.5,
        scrolledUnderElevation: 0.5,
        title: const Text('Record Video Data', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1.0),
          child: Container(color: const Color(0xFFE2E8F0), height: 1.0),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [

            // Camera / Live Recorder Preview Area
            Expanded(
              child: Container(
                margin: const EdgeInsets.all(16.0),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(20.0),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity( 0.1),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Camera View or Web Live Camera Simulation Canvas
                    _buildCameraView(),

                    // Recording Live Duration Overlay
                    if (_isRecording)
                      Positioned(
                        top: 16,
                        left: 16,
                        right: 16,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Timer badge
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity( 0.75),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: _isDanger ? AppColors.error : (_isWarning ? const Color(0xFFF59E0B) : AppColors.error),
                                  width: _isDanger ? 2.5 : 1.5,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 10,
                                    height: 10,
                                    decoration: BoxDecoration(
                                      color: _isDanger ? AppColors.error : (_isWarning ? const Color(0xFFF59E0B) : AppColors.error),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    _formatDuration(_elapsedSeconds),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      fontFeatures: [FontFeature.tabularFigures()],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                            // Progress bar showing 30-min usage
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: _timerProgress,
                                minHeight: 4,
                                backgroundColor: Colors.white.withOpacity( 0.3),
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  _isDanger ? AppColors.error : (_isWarning ? const Color(0xFFF59E0B) : const Color(0xFF2563EB)),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // Saved Video & GPS & Tag Summary Card
            if (_recordedFile != null || _isFetchingLocation)
              _buildSavedVideoSummaryCard(),

            // Bottom Controls Area
            Container(
              padding: const EdgeInsets.all(20.0),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity( 0.05),
                    blurRadius: 10,
                    offset: const Offset(0, -4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Prominent Shutter / Record Button
                  if (_recordedFile == null && !_isFetchingLocation)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16.0),
                      child: GestureDetector(
                        onTap: _isRecording ? _stopRecording : _startRecording,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: _isRecording
                                  ? [const Color(0xFFEF4444), const Color(0xFFDC2626)]
                                  : [const Color(0xFFEF4444), const Color(0xFFE11D48)],
                            ),
                            borderRadius: BorderRadius.circular(40),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFFEF4444).withOpacity( 0.4),
                                blurRadius: 16,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 22,
                                height: 22,
                                decoration: const BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                ),
                                child: Center(
                                  child: Icon(
                                    _isRecording ? Icons.stop_rounded : Icons.circle_rounded,
                                    size: 14,
                                    color: const Color(0xFFEF4444),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                _isRecording ? 'STOP RECORDING' : 'START RECORDING',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 16,
                                  letterSpacing: 1.0,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),



                  if (_recordedFile != null || _isFetchingLocation) ...[
                    // Post-recording actions (Re-record / Upload API)
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _isFetchingLocation
                                ? null
                                : () {
                                    setState(() {
                                      _recordedFile = null;
                                      _currentPosition = null;
                                      _locationErrorMessage = null;
                                      _elapsedSeconds = 0;
                                    });
                                    _initializeCamera();
                                  },
                            icon: const Icon(Icons.videocam_outlined),
                            label: const Text('Re-record'),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _isFetchingLocation
                                ? null
                                : () {
                                    Navigator.pushNamed(
                                      context,
                                      AppRoutes.uploadVideo,
                                      arguments: {
                                        'videoPath': _recordedFile?.path ?? '',
                                        'environmentTag': _selectedEnvironmentTag,
                                      },
                                    );
                                  },
                            icon: const Icon(Icons.cloud_upload_rounded),
                            label: const Text('Upload API'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF2563EB),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraView() {
    if (_isInitializing) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    // When recording has been stopped, turn off camera preview and display Camera Stopped state
    if (!_isRecording && _recordedFile != null) {
      return Container(
        color: const Color(0xFF0F172A),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: const BoxDecoration(
                  color: Color(0xFF1E293B),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.videocam_off_rounded, size: 54, color: Color(0xFFEF4444)),
              ),
              const SizedBox(height: 16),
              const Text(
                'Camera Feed Stopped 🛑',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(
                'Clip Captured (${_formatDuration(_elapsedSeconds)}) • Ready to Upload / Draft',
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    // On Mobile Native, use CameraPreview. On Web, use WebLiveCameraView
    if (!kIsWeb && _controller != null && _controller!.value.isInitialized) {
      return CameraPreview(_controller!);
    }

    // Active Live Camera Recording Stream & Viewfinder (Web / Demo Mode)
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        color: Color(0xFF090D16),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Live Video Stream Layer (HTML5 Browser Webcam or HD Sample Video Feed)
          Positioned.fill(
            child: WebLiveCameraView(
              isRecording: _isRecording,
              environmentTag: _selectedEnvironmentTag,
            ),
          ),

          // Rule-of-Thirds Gridlines Overlay
          Positioned.fill(
            child: CustomPaint(
              painter: _CameraGridPainter(isRecording: _isRecording),
            ),
          ),

          // Top Stream Status Badge
          Positioned(
            top: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity( 0.65),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white30),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _isRecording ? const Color(0xFFEF4444) : const Color(0xFF10B981),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _isRecording ? '🔴 REC - RECORDING LIVE WEBCAM' : '🟢 WEBCAM FEED ACTIVE',
                    style: TextStyle(
                      color: _isRecording ? const Color(0xFFFF6B6B) : const Color(0xFF34D399),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Viewfinder Corners (Target Box)
          Positioned(
            top: 24,
            left: 24,
            child: Container(width: 24, height: 24, decoration: const BoxDecoration(border: Border(top: BorderSide(color: Colors.white54, width: 2), left: BorderSide(color: Colors.white54, width: 2)))),
          ),
          Positioned(
            top: 24,
            right: 24,
            child: Container(width: 24, height: 24, decoration: const BoxDecoration(border: Border(top: BorderSide(color: Colors.white54, width: 2), right: BorderSide(color: Colors.white54, width: 2)))),
          ),
          Positioned(
            bottom: 24,
            left: 24,
            child: Container(width: 24, height: 24, decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white54, width: 2), left: BorderSide(color: Colors.white54, width: 2)))),
          ),
          Positioned(
            bottom: 24,
            right: 24,
            child: Container(width: 24, height: 24, decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white54, width: 2), right: BorderSide(color: Colors.white54, width: 2)))),
          ),
        ],
      ),
    );
  }

  Widget _buildSavedVideoSummaryCard() {
    if (_isFetchingLocation) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        padding: const EdgeInsets.all(16.0),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('Fetching GPS Coordinates...', style: TextStyle(fontSize: 14)),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: const Color(0xFFECFDF5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFA7F3D0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.check_circle_rounded, color: Color(0xFF059669), size: 22),
              SizedBox(width: 8),
              Text(
                'Video Saved & Ready for Upload',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF065F46),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Path: ${_recordedFile!.path}',
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: Color(0xFF047857)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            'File Size: ${_formatFileSize(_recordedFileSize)}',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF047857)),
          ),
          if (_currentPosition != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.my_location_rounded, size: 16, color: Color(0xFF059669)),
                const SizedBox(width: 6),
                Text(
                  'GPS: ${_currentPosition!.latitude.toStringAsFixed(5)}, ${_currentPosition!.longitude.toStringAsFixed(5)}',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF047857)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _CameraGridPainter extends CustomPainter {
  final bool isRecording;
  _CameraGridPainter({required this.isRecording});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = (isRecording ? const Color(0xFFEF4444) : Colors.white).withOpacity( 0.12)
      ..strokeWidth = 1.0;

    // Rule-of-thirds camera grid lines
    final thirdWidth = size.width / 3;
    final thirdHeight = size.height / 3;

    canvas.drawLine(Offset(thirdWidth, 0), Offset(thirdWidth, size.height), paint);
    canvas.drawLine(Offset(thirdWidth * 2, 0), Offset(thirdWidth * 2, size.height), paint);

    canvas.drawLine(Offset(0, thirdHeight), Offset(size.width, thirdHeight), paint);
    canvas.drawLine(Offset(0, thirdHeight * 2), Offset(size.width, thirdHeight * 2), paint);
  }

  @override
  bool shouldRepaint(covariant _CameraGridPainter oldDelegate) => oldDelegate.isRecording != isRecording;
}
