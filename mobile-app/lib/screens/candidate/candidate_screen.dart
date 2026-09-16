import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../config/routes/app_routes.dart';
import '../../core/constants/api_constants.dart';
import '../../services/auth_service.dart';
import '../../services/candidate_video_store.dart';
import '../../utils/web_helper.dart' as web;
import '../notifications/notifications_screen.dart';
import '../profile/profile_screen.dart';
import '../upload/video_upload_screen.dart';

class CandidateScreen extends StatefulWidget {
  const CandidateScreen({super.key});

  @override
  State<CandidateScreen> createState() => _CandidateScreenState();
}

class _CandidateScreenState extends State<CandidateScreen> {
  int _currentTab = 0;

  Future<void> _navigateToEnvironmentThenCamera() async {
    await Navigator.pushNamed(context, AppRoutes.environmentTag);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: IndexedStack(
        index: _currentTab,
        children: [
          const CandidateDashboardTab(),
          const Placeholder(), // Record tab triggers camera
          const VideoUploadScreen(), // Uploads tab
          const NotificationsScreen(),
          ProfileScreen(
            onBackPressed: () {
              setState(() => _currentTab = 0);
            },
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentTab,
        onTap: (idx) {
          if (idx == 1) {
            _navigateToEnvironmentThenCamera();
          } else if (idx == 2) {
            Navigator.pushNamed(context, AppRoutes.uploadVideo);
          } else {
            setState(() => _currentTab = idx);
          }
        },
        selectedItemColor: const Color(0xFF2563EB),
        unselectedItemColor: const Color(0xFF94A3B8),
        type: BottomNavigationBarType.fixed,
        backgroundColor: Colors.white,
        elevation: 8,
        selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
        unselectedLabelStyle: const TextStyle(fontSize: 12),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.videocam_rounded),
            label: 'Record',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.cloud_upload_rounded),
            label: 'Uploads',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.notifications_rounded),
            label: 'Alerts',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person_rounded),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}

class CandidateDashboardTab extends StatefulWidget {
  const CandidateDashboardTab({super.key});

  @override
  State<CandidateDashboardTab> createState() => _CandidateDashboardTabState();
}

class _CandidateDashboardTabState extends State<CandidateDashboardTab> {
  String _candidateName = 'Candidate';
  String _candidateId = '';
  int _totalUploaded = 0;
  String _hoursCollectedStr = '00:00';
  int _pendingQcCount = 0;
  int _approvedCount = 0;
  int _rejectedCount = 0;
  List<Map<String, dynamic>> _myUploads = [];
  bool _isLoading = true;

  Future<void> _navigateToEnvironmentThenCamera() async {
    await Navigator.pushNamed(context, AppRoutes.environmentTag);
  }

  @override
  void initState() {
    super.initState();
    _loadDynamicCandidateData();
    _subscribeRealtime();
  }

  void _subscribeRealtime() {
    if (kIsWeb) {
      try {
        final bc = web.BroadcastChannelStub('platform_realtime_channel');
        bc.onMessage.listen((event) {
          if (mounted) _loadDynamicCandidateData();
        });
      } catch (_) {}
    }
  }

  Future<void> _loadDynamicCandidateData() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final session = await AuthService.restoreSession();
      if (session != null) {
        _candidateName = session['name'] ?? session['username'] ?? 'Candidate';
        _candidateId = session['id'] ?? '';
      }

      // Fetch uploaded videos list dynamically
      final videos = await CandidateVideoStore.getUploadedVideos();
      _myUploads = List<Map<String, dynamic>>.from(videos);

      // Fetch live candidate dashboard stats from API
      try {
        final headers = await AuthService.getAuthHeaders();
        final url = Uri.parse('${ApiConstants.baseUrl}${ApiConstants.apiVersion}/videos/candidate-stats?candidate_id=$_candidateId');
        final res = await http.get(url, headers: headers).timeout(const Duration(seconds: 8));

        if (res.statusCode == 200) {
          final body = jsonDecode(res.body);
          final data = body['data'] ?? {};
          _totalUploaded = data['total_uploaded'] ?? _myUploads.length;
          _pendingQcCount = data['pending_qc'] ?? 0;
          _approvedCount = (data['qc_approved'] ?? 0) + (data['approved'] ?? 0);
          _rejectedCount = (data['qc_rejected'] ?? 0) + (data['rejected'] ?? 0);

          final totalSec = (data['total_duration_seconds'] is int)
              ? data['total_duration_seconds'] as int
              : _myUploads.fold<int>(0, (sum, item) => sum + CandidateVideoStore.parseDurationSeconds(item['durationSeconds'] ?? item['duration']));
          final hrs = (totalSec ~/ 3600).toString().padLeft(2, '0');
          final mins = ((totalSec % 3600) ~/ 60).toString().padLeft(2, '0');
          _hoursCollectedStr = '$hrs:$mins';
        } else {
          _computeFallbackStats();
        }
      } catch (_) {
        _computeFallbackStats();
      }
    } catch (e) {
      debugPrint('Dynamic candidate data error: $e');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _computeFallbackStats() {
    _totalUploaded = _myUploads.length;
    int pending = 0;
    int approved = 0;
    int rejected = 0;
    int totalSec = 0;
    for (var u in _myUploads) {
      final st = (u['status'] ?? '').toString().toLowerCase();
      if (st.contains('reject')) {
        rejected++;
      } else if (st.contains('approve')) {
        approved++;
      } else {
        pending++;
      }
      totalSec += CandidateVideoStore.parseDurationSeconds(u['durationSeconds'] ?? u['duration']);
    }
    _pendingQcCount = pending;
    _approvedCount = approved;
    _rejectedCount = rejected;

    final hrs = (totalSec ~/ 3600).toString().padLeft(2, '0');
    final mins = ((totalSec % 3600) ~/ 60).toString().padLeft(2, '0');
    _hoursCollectedStr = '$hrs:$mins';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF2563EB), // Blue Header Top
      body: SafeArea(
        child: Column(
          children: [
            // Top Blue Header Section
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Good Morning,',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.white70,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            '$_candidateName',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          Text('👋', style: TextStyle(fontSize: 20)),
                        ],
                      ),
                    ],
                  ),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: IconButton(
                      icon: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          const Icon(Icons.notifications_outlined, color: Colors.white, size: 26),
                          Positioned(
                            top: 0,
                            right: 0,
                            child: Container(
                              width: 9,
                              height: 9,
                              decoration: BoxDecoration(
                                color: const Color(0xFFEF4444),
                                shape: BoxShape.circle,
                                border: Border.all(color: const Color(0xFF2563EB), width: 1.5),
                              ),
                            ),
                          ),
                        ],
                      ),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (ctx) => const NotificationsScreen()),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),

            // White Scrollable Main Body Area
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: const BoxDecoration(
                  color: Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(28),
                    topRight: Radius.circular(28),
                  ),
                ),
                child: RefreshIndicator(
                  onRefresh: _loadDynamicCandidateData,
                  color: const Color(0xFF2563EB),
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
                    padding: const EdgeInsets.all(20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 1. Today's Progress Card
                      _buildTodaysProgressCard(),
                      const SizedBox(height: 24),

                      // 2. Quick Actions Header & Grid
                      const Text(
                        'Quick Actions',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 14),
                      _buildQuickActionsGrid(context),
                      const SizedBox(height: 24),

                      // 3. Recent Activity Header & Card
                      const Text(
                        'Recent Activity',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildRecentActivityCard(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildTodaysProgressCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                "Today's Progress",
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF0F172A),
                ),
              ),
              if (_isLoading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF2563EB)),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              // Stat 1: Videos Uploaded
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFF1F5F9)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Videos Uploaded',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF64748B),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '$_totalUploaded',
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),

              // Stat 2: Hours Collected
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFF1F5F9)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Hours Collected',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF64748B),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _hoursCollectedStr,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Mini Status Breakdown Bar
          Row(
            children: [
              _buildMiniStatusChip('🟡 Pending: $_pendingQcCount', const Color(0xFFFEF3C7), const Color(0xFFD97706)),
              const SizedBox(width: 6),
              _buildMiniStatusChip('🟢 Approved: $_approvedCount', const Color(0xFFDCFCE7), const Color(0xFF166534)),
              const SizedBox(width: 6),
              _buildMiniStatusChip('🔴 Rejected: $_rejectedCount', const Color(0xFFFEE2E2), const Color(0xFF991B1B)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMiniStatusChip(String label, Color bg, Color text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: text)),
    );
  }

  Widget _buildRecentActivityCard() {
    if (_myUploads.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFF1F5F9)),
        ),
        child: const Column(
          children: [
            Icon(Icons.video_library_outlined, size: 36, color: Color(0xFF94A3B8)),
            SizedBox(height: 8),
            Text('No Recordings Yet', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF0F172A))),
            SizedBox(height: 4),
            Text('Tap "Start Recording" to capture candidate video clips.', style: TextStyle(fontSize: 11, color: Color(0xFF64748B))),
          ],
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _myUploads.length > 3 ? 3 : _myUploads.length,
      itemBuilder: (ctx, i) {
        final item = _myUploads[i];
        final title = item['title'] ?? item['video_title'] ?? 'Video Recording';
        final timeStr = item['date'] ?? item['time'] ?? 'Just now';
        final statusStr = item['status']?.toString() ?? 'Pending QC';
        final isApproved = statusStr.toLowerCase().contains('approve');
        final isRejected = statusStr.toLowerCase().contains('reject');

        Color statusBg = const Color(0xFFFEF3C7);
        Color statusColor = const Color(0xFFD97706);

        if (isApproved) {
          statusBg = const Color(0xFFDCFCE7);
          statusColor = const Color(0xFF166534);
        } else if (isRejected) {
          statusBg = const Color(0xFFFEE2E2);
          statusColor = const Color(0xFF991B1B);
        }

        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFF1F5F9)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.02),
                blurRadius: 10,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  width: 48,
                  height: 48,
                  color: const Color(0xFFEFF6FF),
                  child: const Icon(
                    Icons.videocam_rounded,
                    color: Color(0xFF2563EB),
                    size: 24,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      timeStr,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: statusBg,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  statusStr,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: statusColor,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showHelpModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Candidate Help Center',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            const Text('• Tap "Start Recording" to launch camera & select environment tag.'),
            const SizedBox(height: 8),
            const Text('• Upload logs are synchronized automatically once connected to Wi-Fi.'),
            const SizedBox(height: 8),
            const Text('• Payout settlements are credited based on approved hours.'),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Got it', style: TextStyle(color: Colors.white)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
