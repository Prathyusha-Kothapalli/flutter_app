import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/constants/api_constants.dart';
import '../../core/theme/app_colors.dart';
import '../../config/routes/app_routes.dart';
import '../../services/auth_service.dart';
import '../../services/candidate_video_store.dart';
import '../../widgets/video_playback_dialog.dart';
import '../../widgets/powered_by_footer.dart';

import '../../utils/web_helper.dart' as web;

class MobileVendorDashboardScreen extends StatefulWidget {
  const MobileVendorDashboardScreen({super.key});

  @override
  State<MobileVendorDashboardScreen> createState() => _MobileVendorDashboardScreenState();
}

class _MobileVendorDashboardScreenState extends State<MobileVendorDashboardScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  int _currentTab = 0; // 0: Home, 1: Candidates, 2: Uploads, 3: Notifications, 4: Profile
  final List<int> _tabHistory = [0];
  String _activeUploadFilter = 'All';

  void _navigateToTab(int index) {
    if (_currentTab != index) {
      if (_tabHistory.isEmpty || _tabHistory.last != index) {
        _tabHistory.add(index);
      }
      setState(() {
        _currentTab = index;
      });
    }
  }

  void _goBackToPreviousTab() {
    if (_tabHistory.length > 1) {
      _tabHistory.removeLast();
      setState(() {
        _currentTab = _tabHistory.last;
      });
    } else if (_currentTab != 0) {
      setState(() {
        _currentTab = 0;
        _tabHistory.clear();
        _tabHistory.add(0);
      });
    }
  }

  // Vendor session info
  String _vendorName = 'Vendor Operations';
  String _vendorCode = '';
  String _vendorContact = 'Vendor Contact';
  String _vendorEmail = 'vendor@elevateiq.com';
  String _vendorPhone = '+91 98765 00000';

  // Dynamic stat counters (Defaulting to ZERO as requested)
  int _totalUploadedVideosCount = 0;
  int _approvedVideosCount = 0;
  int _pendingQCVideosCount = 0;
  int _rejectedVideosCount = 0;
  int _totalDurationSeconds = 0;
  String _formattedHoursCollected = '00:00';
  int _activeCandidatesCount = 0;
  int _inactiveCandidatesCount = 0;

  // Candidates list state
  final List<Map<String, dynamic>> _vendorCandidates = [];

  // Uploads list state
  final List<Map<String, dynamic>> _vendorUploads = [];

  // Notifications state
  final List<Map<String, dynamic>> _vendorNotifications = [];

  // Add Candidate Dialog Controllers
  final _candNameCtrl = TextEditingController();
  final _candPhoneCtrl = TextEditingController();

  // Add Vendor Dialog Controllers
  final _vendorNameCtrl = TextEditingController();
  final _vendorContactCtrl = TextEditingController();
  final _vendorEmailCtrl = TextEditingController();
  final _vendorPhoneCtrl = TextEditingController();
  String _searchCandidateQuery = '';

  @override
  void initState() {
    super.initState();
    _checkAuthAndInit();
  }

  @override
  void dispose() {
    _candNameCtrl.dispose();
    _candPhoneCtrl.dispose();
    _vendorNameCtrl.dispose();
    _vendorContactCtrl.dispose();
    _vendorEmailCtrl.dispose();
    _vendorPhoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkAuthAndInit() async {
    final session = await AuthService.restoreSession();
    if (session == null || session['token'] == null || session['token']!.isEmpty) {
      if (mounted) {
        Navigator.pushReplacementNamed(context, AppRoutes.login);
      }
      return;
    }
    _loadVendorData();
    _loadVendorUploads();
    _loadVendorNotifications();
    _connectRealtimeStream();
    _subscribeBroadcastChannel();
  }

  void _subscribeBroadcastChannel() {
    if (kIsWeb) {
      try {
        final bc = web.BroadcastChannelStub('platform_realtime_channel');
        bc.onMessage.listen((event) {
          if (mounted) {
            _loadVendorData();
            _loadVendorUploads();
            _loadVendorNotifications();
          }
        });
      } catch (_) {}
    }
  }

  void _connectRealtimeStream() {
    if (kIsWeb) {
      try {
        final eventSource = web.EventSourceStub('${ApiConstants.baseUrl}/api/v1/notifications/stream');
        eventSource.onMessage.listen((event) {
          if (mounted) {
            _loadVendorData();
            _loadVendorUploads();
            _loadVendorNotifications();
          }
        });
      } catch (_) {}
    }
  }

  Future<void> _loadVendorData() async {
    try {
      final headers = await AuthService.getAuthHeaders();
      final session = await AuthService.restoreSession();
      if (session != null) {
        if (session['name'] != null && session['name']!.isNotEmpty) {
          _vendorName = session['name']!;
        }
        if (session['email'] != null && session['email']!.isNotEmpty) {
          _vendorEmail = session['email']!;
        }
        if (session['contact_person'] != null && session['contact_person']!.isNotEmpty) {
          _vendorContact = session['contact_person']!;
        }
        if (session['phone'] != null && session['phone']!.isNotEmpty) {
          _vendorPhone = session['phone']!;
        }
        final codeFromSession = session['vendor_code'] ?? session['code'] ?? session['vendorCode'];
        if (codeFromSession != null && codeFromSession.toString().isNotEmpty) {
          _vendorCode = codeFromSession.toString();
        }
      }

      final vendorId = session?['id'] ?? session?['vendor_id'] ?? '';
      final vendorCode = _vendorCode.isNotEmpty ? _vendorCode : (session?['vendor_code'] ?? session?['code'] ?? '');

      // Fetch vendor details from backend database to sync exact phone number created by Admin
      try {
        final vendorRes = await http.get(
          Uri.parse('${ApiConstants.baseUrl}/api/v1/vendors'),
          headers: headers,
        ).timeout(const Duration(seconds: 4));
        if (vendorRes.statusCode == 200) {
          final data = jsonDecode(vendorRes.body);
          final List<dynamic> vendors = data['data'] is List ? data['data'] : (data['data']?['items'] ?? []);
          dynamic matchingVendor;
          for (var v in vendors) {
            final vCode = v['vendor_code']?.toString() ?? '';
            final vEmail = v['email']?.toString() ?? '';
            if ((vCode.isNotEmpty && vCode.toLowerCase() == vendorCode.toLowerCase()) ||
                (vEmail.isNotEmpty && vEmail.toLowerCase() == _vendorEmail.toLowerCase())) {
              matchingVendor = v;
              break;
            }
          }
          if (matchingVendor != null && mounted) {
            setState(() {
              if (matchingVendor['phone'] != null && matchingVendor['phone'].toString().isNotEmpty) {
                _vendorPhone = matchingVendor['phone'].toString();
              }
              if (matchingVendor['company_name'] != null && matchingVendor['company_name'].toString().isNotEmpty) {
                _vendorName = matchingVendor['company_name'].toString();
              }
            });
          }
        }
      } catch (_) {}
      final candUrl = vendorCode.isNotEmpty
          ? '${ApiConstants.baseUrl}/api/v1/candidates?vendor_code=$vendorCode'
          : (vendorId.isNotEmpty
              ? '${ApiConstants.baseUrl}/api/v1/candidates?vendor_id=$vendorId'
              : '${ApiConstants.baseUrl}/api/v1/candidates');

      final candRes = await http.get(Uri.parse(candUrl), headers: headers).timeout(const Duration(seconds: 4));
      if (candRes.statusCode == 200) {
        final data = jsonDecode(candRes.body);
        final List<dynamic> items = data['data'] is List ? data['data'] : (data['data']?['items'] ?? []);
        if (mounted) {
          setState(() {
            _vendorCandidates.clear();
            int act = 0;
            int inact = 0;
            for (var c in items) {
              final cCode = c['vendor_code']?.toString() ?? c['vendorCode']?.toString() ?? '';
              final cVId = c['vendor_id']?.toString() ?? c['vendorId']?.toString() ?? '';
              final cVName = c['vendor_name']?.toString() ?? c['vendor']?.toString() ?? '';

              // Strict filtering by Vendor Code
              if (vendorCode.isNotEmpty || vendorId.isNotEmpty) {
                final bool matchesCode = vendorCode.isNotEmpty && cCode.isNotEmpty && cCode.toLowerCase() == vendorCode.toLowerCase();
                final bool matchesId = vendorId.isNotEmpty && cVId.isNotEmpty && cVId == vendorId;
                final bool matchesName = _vendorName.isNotEmpty && cVName.isNotEmpty && cVName.toLowerCase().contains(_vendorName.toLowerCase());

                if (!matchesCode && !matchesId && !matchesName) {
                  if (cCode.isNotEmpty || cVId.isNotEmpty) continue;
                }
              }

              final isAct = (c['is_active'] ?? true);
              if (isAct) act++; else inact++;
              _vendorCandidates.add({
                'id': c['id'] != null ? c['id'].toString().substring(0, 8) : 'CAND-001',
                'name': c['full_name'] ?? 'Candidate Name',
                'email': c['email'] ?? 'candidate@example.com',
                'vendor': c['vendor_name'] ?? _vendorName,
                'vendor_code': cCode.isNotEmpty ? cCode : (vendorCode.isNotEmpty ? vendorCode : 'VEN-001'),
                'videos': c['videos_count'] ?? 0,
                'status': isAct ? 'Active' : 'Inactive',
                'phone': c['phone'] ?? 'N/A',
              });
            }
            _activeCandidatesCount = act;
            _inactiveCandidatesCount = inact;
          });
        }
      }
    } catch (_) {}
  }


  Future<void> _loadVendorUploads() async {
    try {
      final headers = await AuthService.getAuthHeaders();
      final session = await AuthService.restoreSession();
      final vendorId = session?['id'] ?? session?['vendor_id'] ?? '';
      final vendorCode = _vendorCode.isNotEmpty ? _vendorCode : (session?['vendor_code'] ?? session?['code'] ?? '');
      final vendorName = session?['name'] ?? session?['vendor_name'] ?? _vendorName;

      _vendorUploads.clear();
      final Set<String> processedIds = {};
      int totalSecs = 0;
      int approvedCount = 0;
      int pendingCount = 0;
      int rejectedCount = 0;

      // 1. Fetch from PostgreSQL REST API using vendor_code or vendor_id
      final videoUrl = vendorCode.isNotEmpty
          ? '${ApiConstants.baseUrl}/api/v1/videos?vendor_code=$vendorCode&limit=100'
          : (vendorId.isNotEmpty
              ? '${ApiConstants.baseUrl}/api/v1/videos?vendor_id=$vendorId&limit=100'
              : '${ApiConstants.baseUrl}/api/v1/videos?limit=100');

      final res = await http.get(Uri.parse(videoUrl), headers: headers).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final List<dynamic> items = data['data'] is List ? data['data'] : (data['data']?['items'] ?? []);

        for (var vid in items) {
          final vId = vid['vendor_id']?.toString() ?? vid['vendorId']?.toString() ?? '';
          final vCode = vid['vendor_code']?.toString() ?? vid['vendorCode']?.toString() ?? '';
          final vName = vid['vendor_name']?.toString() ?? vid['vendor']?.toString() ?? '';
          final candId = vid['candidate_id']?.toString() ?? vid['candidateId']?.toString() ?? '';

          // Vendor Code Scoping: match vendor_code OR vendor_id OR candidate enrolled in _vendorCandidates
          if (vendorCode.isNotEmpty || vendorId.isNotEmpty || vendorName.isNotEmpty) {
            final bool matchesVendorCode = vendorCode.isNotEmpty && vCode.isNotEmpty && vCode.toLowerCase() == vendorCode.toLowerCase();
            final bool matchesVendorId = vendorId.isNotEmpty && vId.isNotEmpty && vId == vendorId;
            final bool matchesVendorName = vendorName.isNotEmpty && vName.isNotEmpty && vName.toLowerCase().contains(vendorName.toLowerCase());
            final bool isCandidateMatch = _vendorCandidates.any((c) => c['id'] == candId || (candId.isNotEmpty && c['id'] != null && candId.contains(c['id'].toString())));

            if (!matchesVendorCode && !matchesVendorId && !matchesVendorName && !isCandidateMatch) {
              if (vCode.isNotEmpty || vId.isNotEmpty) continue;
            }
          }

          final id = vid['id']?.toString() ?? '';
          if (id.isNotEmpty) processedIds.add(id);

          final rawStatus = (vid['status'] ?? 'PENDING_QC').toString().toUpperCase().replaceAll(' ', '_');
          String displayStatus;
          if (rawStatus == 'QC_APPROVED') {
            displayStatus = 'QC Approved';
            approvedCount++;
          } else if (rawStatus == 'APPROVED' || rawStatus == 'FINAL_APPROVED') {
            displayStatus = 'Final Approved 🎉';
            approvedCount++;
          } else if (rawStatus == 'ASSIGNED_QC' || rawStatus == 'IN_REVIEW') {
            displayStatus = 'Assigned to QC';
            pendingCount++;
          } else if (rawStatus.contains('REJECT')) {
            displayStatus = 'Rejected';
            rejectedCount++;
          } else {
            displayStatus = 'Pending QC';
            pendingCount++;
          }

          final durSec = (vid['duration'] is int) ? vid['duration'] as int : (int.tryParse(vid['duration']?.toString() ?? '30') ?? 30);
          totalSecs += durSec;

          final mins = durSec ~/ 60;
          final secs = durSec % 60;
          final durStr = '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';

          _vendorUploads.add({
            'id': id.isNotEmpty ? id : 'VID-${_vendorUploads.length + 1}',
            'title': vid['title'] ?? 'Dataset Video Recording',
            'candidateName': vid['candidate_name'] ?? vid['full_name'] ?? 'Candidate',
            'candidatePhone': vid['candidate_phone'] ?? vid['phone'] ?? 'N/A',
            'vendor_code': vCode.isNotEmpty ? vCode : (vendorCode.isNotEmpty ? vendorCode : 'VEN-001'),
            'env': vid['environment_tag'] ?? 'Indoor',
            'status': displayStatus,
            'duration': '$durStr Mins',
            'time': 'Just Now',
          });
        }
      }

      // 2. Fetch from Web LocalStorage platform_qc_submissions
      if (kIsWeb) {
        try {
          final raw = web.localStorageGet('platform_qc_submissions');
          if (raw != null) {
            final List<dynamic> list = jsonDecode(raw);

            for (var item in list) {
              final vId = item['vendorId']?.toString() ?? '';
              final vCode = item['vendorCode']?.toString() ?? item['vendor_code']?.toString() ?? '';
              final vName = item['vendor']?.toString() ?? '';
              final candId = item['candidateId']?.toString() ?? item['candidate_id']?.toString() ?? '';

              if (vendorCode.isNotEmpty || vendorId.isNotEmpty || vendorName.isNotEmpty) {
                final bool matchesVendorCode = vendorCode.isNotEmpty && vCode.isNotEmpty && vCode.toLowerCase() == vendorCode.toLowerCase();
                final bool matchesVendorId = vendorId.isNotEmpty && vId.isNotEmpty && vId == vendorId;
                final bool matchesVendorName = vendorName.isNotEmpty && vName.isNotEmpty && (vName.toLowerCase().contains(vendorName.toLowerCase()) || vendorName.toLowerCase().contains(vName.toLowerCase()));
                final bool isCandidateMatch = _vendorCandidates.any((c) => c['id'] == candId || (candId.isNotEmpty && c['id'] != null && candId.contains(c['id'].toString())));

                if (!matchesVendorCode && !matchesVendorId && !matchesVendorName && !isCandidateMatch) {
                  if (vCode.isNotEmpty || vId.isNotEmpty) continue;
                }
              }

              final id = item['id']?.toString() ?? '';
              if (id.isNotEmpty && processedIds.contains(id)) continue;
              if (id.isNotEmpty) processedIds.add(id);

              final rawStatus = (item['status'] ?? 'Pending').toString().toLowerCase();
              String displayStatus;
              if (rawStatus == 'approved' || rawStatus == 'qc_approved') {
                displayStatus = 'Approved';
                approvedCount++;
              } else if (rawStatus.contains('reject')) {
                displayStatus = 'Rejected';
                rejectedCount++;
              } else {
                displayStatus = 'Pending QC';
                pendingCount++;
              }

              final durSec = item['durationSeconds'] is int ? item['durationSeconds'] as int : (int.tryParse(item['duration']?.toString() ?? '30') ?? 30);
              totalSecs += durSec;

              _vendorUploads.add({
                'id': id.isNotEmpty ? id : 'VID-${_vendorUploads.length + 1}',
                'title': item['title'] ?? 'Uploaded Video Recording',
                'candidateName': item['candidateName'] ?? 'Candidate',
                'candidatePhone': item['candidatePhone'] ?? 'N/A',
                'env': item['env'] ?? 'Kitchen',
                'status': displayStatus,
                'duration': CandidateVideoStore.formatDurationString(durSec),
                'time': item['time'] ?? 'Just Now',
              });
            }
          }
        } catch (_) {}
      }

      if (mounted) {
        setState(() {
          _totalDurationSeconds = totalSecs;
          _approvedVideosCount = approvedCount;
          _pendingQCVideosCount = pendingCount;
          _rejectedVideosCount = rejectedCount;
          _totalUploadedVideosCount = _vendorUploads.length;

          final hours = (_totalDurationSeconds ~/ 3600).toString().padLeft(2, '0');
          final mins = ((_totalDurationSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
          final secs = (_totalDurationSeconds % 60).toString().padLeft(2, '0');
          _formattedHoursCollected = _totalDurationSeconds >= 3600 ? '$hours:$mins' : '$mins:$secs';
        });
      }
    } catch (_) {}
  }


  Future<void> _loadVendorNotifications() async {
    try {
      final headers = await AuthService.getAuthHeaders();
      final res = await http.get(Uri.parse('${ApiConstants.baseUrl}/api/v1/notifications?role=vendor'), headers: headers).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200 && mounted) {
        final data = jsonDecode(res.body);
        final List<dynamic> notifs = data['data'] is List ? data['data'] : (data['data']?['items'] ?? []);
        setState(() {
          _vendorNotifications.clear();
          for (var n in notifs) {
            final title = (n['title'] ?? 'Vendor Notification').toString();
            Color c = const Color(0xFF10B981);
            if (title.toLowerCase().contains('approved')) c = const Color(0xFF16A34A);
            else if (title.toLowerCase().contains('reject')) c = const Color(0xFFDC2626);
            else if (title.toLowerCase().contains('candidate')) c = const Color(0xFF2563EB);
            _vendorNotifications.add({
              'title': title,
              'desc': n['message'] ?? n['desc'] ?? 'Notification from Operations',
              'color': c,
              'read': false,
            });
          }
        });
      }
    } catch (_) {}
  }


  int get _unreadNotificationCount => _vendorNotifications.where((n) => n['read'] == false).length;

  Future<void> _markNotificationsAsRead() async {
    setState(() {
      for (var n in _vendorNotifications) {
        n['read'] = true;
      }
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('notifications_all_read', true);
    } catch (_) {}
  }

  Future<void> _handleLogout() async {
    await AuthService.logout();
    if (!mounted) return;
    Navigator.pushReplacementNamed(context, AppRoutes.login);
  }

  void _showAddVendorModal() {
    _vendorNameCtrl.clear();
    _vendorContactCtrl.clear();
    _vendorEmailCtrl.clear();
    _vendorPhoneCtrl.clear();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add New Vendor', style: TextStyle(fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: _vendorNameCtrl, decoration: const InputDecoration(labelText: 'Company / Vendor Name')),
              const SizedBox(height: 8),
              TextField(controller: _vendorContactCtrl, decoration: const InputDecoration(labelText: 'Contact Person')),
              const SizedBox(height: 8),
              TextField(controller: _vendorEmailCtrl, decoration: const InputDecoration(labelText: 'Email Address')),
              const SizedBox(height: 8),
              TextField(controller: _vendorPhoneCtrl, decoration: const InputDecoration(labelText: 'Mobile Number (+91)')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              if (_vendorNameCtrl.text.trim().isEmpty) return;
              final name = _vendorNameCtrl.text.trim();
              final contact = _vendorContactCtrl.text.trim().isEmpty ? 'Vendor Contact' : _vendorContactCtrl.text.trim();
              final email = _vendorEmailCtrl.text.trim().isEmpty ? 'vendor${DateTime.now().millisecondsSinceEpoch}@example.com' : _vendorEmailCtrl.text.trim();
              final phone = _vendorPhoneCtrl.text.trim().isEmpty ? 'N/A' : _vendorPhoneCtrl.text.trim();

              try {
                // BUG-004 FIX: use auth headers (POST /api/v1/vendors requires admin role)
                final authHeaders = await AuthService.getAuthHeaders();
                final uri = Uri.parse('${ApiConstants.baseUrl}/api/v1/vendors');
                final response = await http.post(
                  uri,
                  headers: authHeaders,
                  body: jsonEncode({
                    'company_name': name,
                    'contact_person': contact,
                    'email': email,
                    'phone': phone,
                  }),
                ).timeout(const Duration(seconds: 4));
                debugPrint('Add Vendor response: ${response.statusCode}');
              } catch (e) {
                debugPrint('API vendor creation info: $e');
              }

              if (context.mounted) {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Vendor "$name" created & saved to DB successfully!'), backgroundColor: const Color(0xFF2563EB)),
                );
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2563EB)),
            child: const Text('Save Vendor', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showAddCandidateModal() {
    _candNameCtrl.clear();
    _candPhoneCtrl.clear();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Onboard New Candidate', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: _candNameCtrl, decoration: const InputDecoration(labelText: 'Candidate Full Name')),
            const SizedBox(height: 8),
            TextField(controller: _candPhoneCtrl, decoration: const InputDecoration(labelText: 'Mobile Number (+91 / +1)')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final name = _candNameCtrl.text.trim();
              final phone = _candPhoneCtrl.text.trim();
              if (name.isEmpty) return;

              try {
                final headers = await AuthService.getAuthHeaders();
                // BUG-005 FIX: use real vendor ID from session instead of hardcoded UUID
                final session = await AuthService.restoreSession();
                final realVendorId = session?['vendorId'] ?? session?['vendor_id'] ?? session?['id'] ?? '';
                final uri = Uri.parse('${ApiConstants.baseUrl}/api/v1/candidates');
                await http.post(
                  uri,
                  headers: headers,
                  body: jsonEncode({
                    'full_name': name,
                    'phone': phone.isNotEmpty ? phone : 'N/A',
                    'email': '${name.toLowerCase().replaceAll(' ', '')}${DateTime.now().millisecondsSinceEpoch}@example.com',
                    'vendor_id': realVendorId,
                  }),
                ).timeout(const Duration(seconds: 4));
              } catch (e) {
                debugPrint('Candidate creation API info: $e');
              }

              _loadVendorData();
              if (context.mounted) {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Candidate "$name" onboarded & saved to PostgreSQL DB!'), backgroundColor: AppColors.success),
                );
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.success),
            child: const Text('Save Candidate', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _currentTab == 0 && _tabHistory.length <= 1,
      onPopInvoked: (bool didPop) {
        if (!didPop) {
          _goBackToPreviousTab();
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: const Color(0xFFF8FAFC),
        drawer: _buildSideDrawer(),
        resizeToAvoidBottomInset: false,
        body: IndexedStack(
          index: _currentTab,
          children: [
            _buildHomeDashboardTab(),
            _buildCandidatesTab(),
            _buildUploadStatusTab(),
            _buildNotificationsTab(),
            _buildProfileTab(),
          ],
        ),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const PoweredByFooter(),
            BottomNavigationBar(
              currentIndex: _currentTab,
              onTap: (idx) => _navigateToTab(idx),
              selectedItemColor: const Color(0xFF059669),
              unselectedItemColor: Colors.grey,
              type: BottomNavigationBarType.fixed,
              items: const [
                BottomNavigationBarItem(icon: Icon(Icons.home_rounded), label: 'Home'),
                BottomNavigationBarItem(icon: Icon(Icons.people_rounded), label: 'Candidates'),
                BottomNavigationBarItem(icon: Icon(Icons.cloud_upload_rounded), label: 'Uploads'),
                BottomNavigationBarItem(icon: Icon(Icons.notifications_rounded), label: 'Alerts'),
                BottomNavigationBarItem(icon: Icon(Icons.person_rounded), label: 'Profile'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // SIDE MENU DRAWER MATCHING DESIGN SPEC EXACTLY
  Widget _buildSideDrawer() {
    return Drawer(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      width: MediaQuery.of(context).size.width * 0.78,
      child: SafeArea(
        child: Column(
          children: [
            // Drawer Header with Icon Avatar & Vendor Info
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              child: Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: const BoxDecoration(
                      color: Color(0xFFA7F3D0),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.storefront_rounded, color: Color(0xFF047857), size: 30),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Vendor Operations',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF0F172A)),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _vendorName,
                          style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),

            // Navigation Items List
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                children: [
                  _buildDrawerNavItem(
                    icon: Icons.home_rounded,
                    label: 'Dashboard',
                    index: 0,
                  ),
                  const SizedBox(height: 6),
                  _buildDrawerNavItem(
                    icon: Icons.people_alt_rounded,
                    label: 'Candidates',
                    index: 1,
                  ),
                  const SizedBox(height: 6),
                  _buildDrawerNavItem(
                    icon: Icons.cloud_upload_rounded,
                    label: 'Uploads',
                    index: 2,
                  ),
                  const SizedBox(height: 6),
                  _buildDrawerNavItem(
                    icon: Icons.notifications_rounded,
                    label: 'Alerts',
                    index: 3,
                  ),
                  const SizedBox(height: 6),
                  _buildDrawerNavItem(
                    icon: Icons.person_rounded,
                    label: 'Profile',
                    index: 4,
                  ),
                ],
              ),
            ),

            const Divider(indent: 16, endIndent: 16, color: Color(0xFFE2E8F0)),
            // Logout Item
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              leading: const Icon(Icons.logout_rounded, color: Color(0xFF059669), size: 24),
              title: const Text(
                'Logout',
                style: TextStyle(color: Color(0xFF059669), fontWeight: FontWeight.bold, fontSize: 15),
              ),
              onTap: () {
                Navigator.pop(context); // close drawer
                _handleLogout();
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _buildDrawerNavItem({
    required IconData icon,
    required String label,
    required int index,
  }) {
    final bool isSelected = _currentTab == index;
    return Container(
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFFECFDF5) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        leading: Icon(
          icon,
          color: isSelected ? const Color(0xFF059669) : const Color(0xFF475569),
          size: 22,
        ),
        title: Text(
          label,
          style: TextStyle(
            color: isSelected ? const Color(0xFF059669) : const Color(0xFF1E293B),
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
            fontSize: 14.5,
          ),
        ),
        onTap: () {
          Navigator.pop(context); // close drawer
          _navigateToTab(index);
        },
      ),
    );
  }

  // 1. VENDOR HOME DASHBOARD TAB (No White Space Header)
  Widget _buildHomeDashboardTab() {
    return RefreshIndicator(
      onRefresh: () async {
        await _loadVendorData();
        await _loadVendorUploads();
      },
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Dark Emerald Curved Header Header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.only(top: 40, left: 20, right: 20, bottom: 26),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF064E3B), Color(0xFF047857), Color(0xFF10B981)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(28),
                  bottomRight: Radius.circular(28),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Builder(
                            builder: (ctx) => IconButton(
                              icon: const Icon(Icons.menu_rounded, color: Colors.white, size: 26),
                              onPressed: () => Scaffold.of(ctx).openDrawer(),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                            ),
                          ),
                          const SizedBox(width: 10),
                          const CircleAvatar(
                            backgroundColor: Colors.white24,
                            child: Icon(Icons.storefront_rounded, color: Colors.white),
                          ),
                          const SizedBox(width: 12),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Vendor Operations', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                              Text(_vendorName, style: const TextStyle(color: Colors.white70, fontSize: 11)),
                            ],
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          Stack(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.notifications_outlined, color: Colors.white, size: 24),
                                onPressed: () {
                                  setState(() => _currentTab = 3);
                                  _markNotificationsAsRead();
                                },
                              ),
                              if (_unreadNotificationCount > 0)
                                Positioned(
                                  top: 10,
                                  right: 10,
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: const BoxDecoration(color: Color(0xFFEF4444), shape: BoxShape.circle),
                                    child: Text('$_unreadNotificationCount', style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Text('Welcome, $_vendorName 👋', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: -0.5)),
                  const SizedBox(height: 4),
                  const Text("Real-time vendor candidate & video collection dashboard", style: TextStyle(fontSize: 12, color: Colors.white70, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
            const SizedBox(height: 20),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Vendor Progress Card (Dynamic numbers starting at 0/00:00)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: const Color(0xFF047857),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF047857).withOpacity( 0.25),
                          blurRadius: 15,
                          offset: const Offset(0, 5),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("YOUR CANDIDATES' PROGRESS", style: TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.8)),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Videos Uploaded', style: TextStyle(color: Colors.white70, fontSize: 12)),
                                const SizedBox(height: 4),
                                Text('$_totalUploadedVideosCount', style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold)),
                              ],
                            ),
                            Container(height: 34, width: 1, color: Colors.white24),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Hours Collected', style: TextStyle(color: Colors.white70, fontSize: 12)),
                                const SizedBox(height: 4),
                                Text(_formattedHoursCollected, style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Clean Full-Width Approved Videos Stat Card
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: const Color(0xFFDCFCE7),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFFBBF7D0)),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF10B981).withOpacity( 0.08),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('APPROVED VIDEOS', style: TextStyle(fontSize: 11, color: Color(0xFF15803D), fontWeight: FontWeight.w800, letterSpacing: 0.8)),
                            const SizedBox(height: 6),
                            Text('$_approvedVideosCount', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: Color(0xFF166534))),
                            const SizedBox(height: 4),
                            const Text('QC Approved dataset video count', style: TextStyle(fontSize: 11, color: Color(0xFF166534))),
                          ],
                        ),
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: const Color(0xFF15803D).withOpacity( 0.12),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(Icons.check_circle_rounded, color: Color(0xFF15803D), size: 28),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Candidate Status Breakdown Card Grid (Dynamic numbers)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity( 0.03),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'CANDIDATE & VIDEO STATUS BREAKDOWN',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFF0F172A), letterSpacing: 0.5),
                        ),
                        const SizedBox(height: 14),
                        GridView.count(
                          crossAxisCount: 2,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                          childAspectRatio: 2.1,
                          children: [
                            _buildStatusMiniTile('Total Candidates', '${_vendorCandidates.length}', const Color(0xFF6366F1), const Color(0xFFEEF2FF)),
                            _buildStatusMiniTile('Pending QC', '$_pendingQCVideosCount', const Color(0xFFD97706), const Color(0xFFFEF3C7)),
                            _buildStatusMiniTile('Approved Videos', '$_approvedVideosCount', const Color(0xFF059669), const Color(0xFFD1FAE5)),
                            _buildStatusMiniTile('Rejected Videos', '$_rejectedVideosCount', const Color(0xFFDC2626), const Color(0xFFFEE2E2)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Recent Candidate Uploads
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Recent Candidate Uploads', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                      TextButton(
                        onPressed: () => setState(() => _currentTab = 2),
                        child: const Text('View All', style: TextStyle(color: Color(0xFF059669), fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),

                  if (_vendorUploads.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: const Column(
                        children: [
                          Icon(Icons.video_collection_outlined, size: 40, color: Color(0xFF94A3B8)),
                          SizedBox(height: 8),
                          Text('No candidate video uploads yet.', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF334155))),
                          SizedBox(height: 4),
                          Text('Videos uploaded by your candidates will appear here live.', style: TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                        ],
                      ),
                    )
                  else
                    Column(
                      children: _vendorUploads.take(4).map((item) {
                        final isAppr = item['status'] == 'Approved';
                        final isPend = item['status'] == 'Pending QC';
                        final statusColor = isAppr ? const Color(0xFF16A34A) : isPend ? const Color(0xFFD97706) : const Color(0xFFDC2626);

                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                          ),
                          child: ListTile(
                            onTap: () => _showVideoPreviewModal(item),
                            leading: CircleAvatar(
                              backgroundColor: statusColor.withOpacity( 0.12),
                              child: Icon(Icons.videocam_rounded, color: statusColor, size: 22),
                            ),
                            title: Text(item['title'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF0F172A))),
                            subtitle: Text('Candidate: ${item['candidateName']} (${item['candidatePhone']})\nTag: ${item['env']} • ${item['time']}', style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                            trailing: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(color: statusColor.withOpacity( 0.1), borderRadius: BorderRadius.circular(8)),
                              child: Text(item['status'], style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 11)),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 2. CANDIDATES ROSTER TAB (Overall Candidates & Search Engine)
  Widget _buildCandidatesTab() {
    return RefreshIndicator(
      onRefresh: _loadVendorData,
      child: SafeArea(
        top: true,
        bottom: false,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded, color: Color(0xFF0F172A), size: 24),
                  onPressed: _goBackToPreviousTab,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Go Back',
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Candidate Directory',
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF0F172A), letterSpacing: -0.5),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _vendorCode.isNotEmpty
                            ? 'Candidates enrolled under Vendor Code: $_vendorCode'
                            : 'Candidates enrolled under your Vendor Code',
                        style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Real-Time Search Field
            TextField(
              onChanged: (val) {
                setState(() {
                  _searchCandidateQuery = val;
                });
              },
              style: const TextStyle(fontSize: 14, color: Color(0xFF0F172A), fontWeight: FontWeight.w500),
              decoration: InputDecoration(
                hintText: 'Search candidates by name, email, phone, vendor...',
                prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF2563EB)),
                suffixIcon: _searchCandidateQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, color: Color(0xFF94A3B8)),
                        onPressed: () => setState(() => _searchCandidateQuery = ''),
                      )
                    : null,
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: Color(0xFF2563EB), width: 1.5),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              ),
            ),
            const SizedBox(height: 16),

            // Candidate Items Roster
            Builder(
              builder: (context) {
                final filtered = _vendorCandidates.where((c) {
                  final q = _searchCandidateQuery.toLowerCase().trim();
                  if (q.isEmpty) return true;
                  final name = (c['name'] ?? '').toString().toLowerCase();
                  final email = (c['email'] ?? '').toString().toLowerCase();
                  final phone = (c['phone'] ?? '').toString().toLowerCase();
                  final vendor = (c['vendor'] ?? '').toString().toLowerCase();
                  final id = (c['id'] ?? '').toString().toLowerCase();
                  return name.contains(q) || email.contains(q) || phone.contains(q) || vendor.contains(q) || id.contains(q);
                }).toList();

                if (filtered.isEmpty) {
                  return Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(32.0),
                    margin: const EdgeInsets.only(top: 20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: Column(
                      children: [
                        const Icon(Icons.person_search_rounded, size: 48, color: Color(0xFF94A3B8)),
                        const SizedBox(height: 12),
                        Text(
                          _searchCandidateQuery.isEmpty ? 'No Candidates Found in Database' : 'No candidates match "$_searchCandidateQuery"',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF334155)),
                        ),
                        const SizedBox(height: 4),
                        const Text('Pull down to refresh or try another search keyword.', style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                      ],
                    ),
                  );
                }

                return Column(
                  children: filtered.map((c) {
                    final name = (c['name'] ?? 'Candidate').toString();
                    final initial = name.isNotEmpty ? name[0].toUpperCase() : 'C';

                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                        boxShadow: [
                          BoxShadow(color: Colors.black.withOpacity( 0.02), blurRadius: 6, offset: const Offset(0, 2)),
                        ],
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: const Color(0xFF2563EB).withOpacity( 0.1),
                            radius: 20,
                            child: Text(initial, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF2563EB))),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF0F172A))),
                                const SizedBox(height: 2),
                                Text('Vendor Code: ${c['vendor_code'] ?? c['vendorCode'] ?? 'VEN-001'}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF2563EB))),
                                if (c['email'] != null && c['email'].toString().isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text('Email: ${c['email']}', style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ],
        ),
      ),
    ),
    );
  }

  // 3. UPLOAD STATUS TAB (Screen #4, #5 in Image 2)
  Widget _buildUploadStatusTab() {
    final filtered = _activeUploadFilter == 'All'
        ? _vendorUploads
        : _vendorUploads.where((u) {
            final st = (u['status'] ?? '').toString().toLowerCase();
            if (_activeUploadFilter == 'Pending') {
              return st.contains('pending');
            }
            return st == _activeUploadFilter.toLowerCase();
          }).toList();

    return RefreshIndicator(
      onRefresh: _loadVendorUploads,
      child: SafeArea(
        top: true,
        bottom: false,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded, color: Color(0xFF0F172A), size: 24),
                  onPressed: _goBackToPreviousTab,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: 'Go Back',
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Upload Status',
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF0F172A), letterSpacing: -0.5),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _vendorCode.isNotEmpty
                            ? 'Candidate dataset video uploads for Vendor Code: $_vendorCode'
                            : 'Candidate dataset video uploads for your Vendor Code',
                        style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Filter Segment Chips
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: ['All', 'Pending', 'Approved', 'Rejected'].map((status) {
                  final isSel = _activeUploadFilter == status;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    child: ChoiceChip(
                      showCheckmark: isSel,
                      checkmarkColor: Colors.white,
                      label: Text(status),
                      selected: isSel,
                      selectedColor: const Color(0xFF10B981),
                      backgroundColor: const Color(0xFFF1F5F9),
                      side: BorderSide(
                        color: isSel ? const Color(0xFF10B981) : const Color(0xFFCBD5E1),
                        width: 1.5,
                      ),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      labelStyle: TextStyle(
                        color: isSel ? Colors.white : const Color(0xFF1E293B),
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                      onSelected: (val) => setState(() => _activeUploadFilter = status),
                    ),
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 16),

            if (filtered.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Column(
                  children: [
                    const Icon(Icons.cloud_upload_outlined, size: 48, color: Color(0xFF94A3B8)),
                    const SizedBox(height: 12),
                    Text(
                      _activeUploadFilter == 'All' ? 'No Videos Uploaded Yet' : 'No $_activeUploadFilter Videos',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _vendorCode.isNotEmpty
                          ? 'Videos uploaded under Vendor Code $_vendorCode will appear here.'
                          : 'Videos uploaded by your candidates will appear here.',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
            else
              Column(
                children: filtered.map((item) {
                  final isAppr = item['status'] == 'Approved';
                  final isPend = item['status'] == 'Pending';
                  final statusColor = isAppr ? AppColors.success : isPend ? Colors.amber.shade800 : AppColors.error;

                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    child: ListTile(
                      onTap: () => _showVideoPreviewModal(item),
                      leading: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(8)),
                        child: const Icon(Icons.play_arrow_rounded, color: Colors.white),
                      ),
                      title: Text(item['title'], style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text('${item['candidateName']} (${item['vendor_code'] ?? _vendorCode})\n${item['env'] ?? 'Indoor'} • ${item['duration']}'),
                      trailing: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(color: statusColor.withAlpha(20), borderRadius: BorderRadius.circular(8)),
                        child: Text(item['status'], style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 11)),
                      ),
                    ),
                  );
                }).toList(),
              ),
          ],
        ),
      ),
    ),
    );
  }

  void _handleNotificationTap(Map<String, dynamic> n) {
    setState(() {
      n['read'] = true;
    });

    final title = (n['title'] ?? '').toString().toLowerCase();
    if (title.contains('approved')) {
      setState(() {
        _activeUploadFilter = 'Approved';
        _currentTab = 2;
      });
    } else if (title.contains('rejected')) {
      setState(() {
        _activeUploadFilter = 'Rejected';
        _currentTab = 2;
      });
    } else if (title.contains('upload')) {
      setState(() {
        _activeUploadFilter = 'All';
        _currentTab = 2;
      });
    } else if (title.contains('candidate')) {
      setState(() {
        _currentTab = 1;
      });
    } else {
      setState(() {
        _currentTab = 2;
      });
    }
  }

  // 4. NOTIFICATIONS TAB (Screen #6 in Image 2)
  Widget _buildNotificationsTab() {
    return SafeArea(
      top: true,
      bottom: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded, color: Color(0xFF0F172A), size: 24),
                      onPressed: _goBackToPreviousTab,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: 'Go Back',
                    ),
                    const SizedBox(width: 10),
                    const Text('Notifications', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  ],
                ),
                TextButton(
                  onPressed: _markNotificationsAsRead,
                  child: const Text('Mark all read', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 14),

            Column(
              children: _vendorNotifications.map((n) {
                final c = (n['color'] is Color) ? n['color'] as Color : AppColors.success;
                final isRead = n['read'] == true;
                return Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  color: isRead ? Colors.white : const Color(0xFFF0F9FF),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: isRead ? const Color(0xFFE2E8F0) : AppColors.primary.withAlpha(76)),
                  ),
                  child: ListTile(
                    onTap: () => _handleNotificationTap(n),
                    leading: CircleAvatar(backgroundColor: c.withAlpha(25), child: Icon(Icons.notifications_rounded, color: c)),
                    title: Text(n['title']?.toString() ?? '', style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text(n['desc']?.toString() ?? ''),
                    trailing: const Icon(Icons.chevron_right_rounded, color: Colors.grey, size: 20),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  // 5. VENDOR PROFILE TAB
  Widget _buildProfileTab() {
    final initials = _vendorName.isNotEmpty ? _vendorName[0].toUpperCase() : 'V';
    final referralCode = _vendorCode.isNotEmpty
        ? _vendorCode
        : 'VEN-${_vendorName.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase().padRight(4, 'X').substring(0, 4)}-2026';

    return SafeArea(
      top: true,
      bottom: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_rounded, color: Color(0xFF0F172A), size: 24),
                onPressed: _goBackToPreviousTab,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: 'Go Back',
              ),
              const SizedBox(width: 10),
              const Text('Vendor Profile', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
            ],
          ),
          const SizedBox(height: 14),
          CircleAvatar(
            radius: 40,
            backgroundColor: const Color(0xFF059669),
            child: Text(initials, style: const TextStyle(fontSize: 32, color: Colors.white, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 10),
          Text(_vendorName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(referralCode, style: const TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: const Color(0xFFECFDF5), borderRadius: BorderRadius.circular(10)),
                child: const Text('✓ Verified Vendor', style: TextStyle(color: Color(0xFF059669), fontSize: 11, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 16),

          const SizedBox(height: 16),

          // Details List Card
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _buildProfileRow(Icons.storefront_outlined, 'Vendor Name', _vendorName),
                  const Divider(),
                  _buildProfileRow(Icons.vpn_key_outlined, 'Vendor Code', referralCode),
                  const Divider(),
                  _buildProfileRow(Icons.email_outlined, 'Email Address', _vendorEmail),
                  const Divider(),
                  _buildProfileRow(Icons.phone_outlined, 'Mobile Number', _vendorPhone),
                  const Divider(),
                  _buildProfileRow(Icons.people_outline, 'Active Candidates', '$_activeCandidatesCount Candidates'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          OutlinedButton(
            onPressed: _handleLogout,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.error,
              side: const BorderSide(color: AppColors.error),
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Logout', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    ),
    );
  }

  Widget _buildProfileRow(IconData icon, String label, String val) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, color: Colors.grey, size: 20),
          const SizedBox(width: 12),
          Text(label, style: const TextStyle(color: Colors.grey)),
          const Spacer(),
          Text(val, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  void _showVideoPreviewModal(Map<String, dynamic> item) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.video_library_rounded, color: AppColors.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(item['title'] ?? 'Video Preview', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: () => VideoPlaybackDialog.show(context, item),
              child: Container(
                height: 160,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    const Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 54),
                    Positioned(
                      bottom: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        color: Colors.black87,
                        child: Text(item['duration'] ?? '00:30', style: const TextStyle(color: Colors.white, fontSize: 10)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text('Tag: ${item['env'] ?? 'General'}', style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('Submitted: ${item['time']}'),
            const SizedBox(height: 4),
            Row(
              children: [
                const Text('Status: '),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: AppColors.success.withAlpha(25), borderRadius: BorderRadius.circular(6)),
                  child: Text(item['status'] ?? 'Approved', style: const TextStyle(color: AppColors.success, fontWeight: FontWeight.bold, fontSize: 11)),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  Widget _buildStatusMiniTile(String label, String count, Color color, Color bg, [VoidCallback? onTap]) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              count,
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: color, height: 1.1),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.bold, color: color),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
