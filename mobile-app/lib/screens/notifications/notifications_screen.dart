import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../utils/web_helper.dart' as web;
import '../../core/constants/api_constants.dart';
import '../../core/theme/app_colors.dart';
import '../../services/auth_service.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  bool _isLoading = false;
  List<Map<String, dynamic>> _notifications = [];

  @override
  void initState() {
    super.initState();
    _fetchRealNotifications();
    _subscribeBroadcastChannel();
  }

  void _subscribeBroadcastChannel() {
    if (kIsWeb) {
      try {
        final bc = web.BroadcastChannelStub('platform_realtime_channel');
        bc.onMessage.listen((event) {
          if (mounted) {
            _fetchRealNotifications();
          }
        });
      } catch (_) {}
    }
  }

  Future<void> _fetchRealNotifications() async {
    setState(() => _isLoading = true);
    try {
      final headers = await AuthService.getAuthHeaders();
      final url = Uri.parse('${ApiConstants.baseUrl}${ApiConstants.apiVersion}/notifications');
      final res = await http.get(url, headers: headers).timeout(const Duration(seconds: 3));

      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        final List items = body['data']?['notifications'] ?? [];
        if (items.isNotEmpty) {
          setState(() {
            _notifications = items.map((item) {
              final type = (item['type'] ?? '').toString();
              Color notifColor = const Color(0xFF10B981);
              IconData notifIcon = Icons.notifications_rounded;

              if (type.contains('qc_approved')) {
                notifColor = const Color(0xFF8B5CF6);
                notifIcon = Icons.verified_rounded;
              } else if (type.contains('qc_rejected')) {
                notifColor = const Color(0xFFEF4444);
                notifIcon = Icons.cancel_rounded;
              } else if (type.contains('admin_approved')) {
                notifColor = const Color(0xFF10B981);
                notifIcon = Icons.check_circle_rounded;
              } else if (type.contains('admin_rejected')) {
                notifColor = const Color(0xFFEF4444);
                notifIcon = Icons.error_rounded;
              } else if (type.contains('uploaded')) {
                notifColor = const Color(0xFFF59E0B);
                notifIcon = Icons.hourglass_top_rounded;
              }

              return {
                'id': item['id'],
                'title': item['title'] ?? 'Notification',
                'desc': item['desc'] ?? item['message'] ?? '',
                'time': item['time'] ?? 'Just now',
                'icon': notifIcon,
                'color': notifColor,
                'read': item['read'] ?? false,
              };
            }).toList();
          });
        }
      }
    } catch (_) {
    }

    if (kIsWeb) {
      try {
        final raw = web.localStorageGet('platform_candidate_notifications');
        if (raw != null) {
          final List<dynamic> localNotifs = jsonDecode(raw);
          if (localNotifs.isNotEmpty) {
            final List<Map<String, dynamic>> parsedList = [];
            for (var item in localNotifs) {
              final type = (item['type'] ?? '').toString();
              Color notifColor = const Color(0xFF10B981);
              IconData notifIcon = Icons.notifications_rounded;

              if (type.contains('qc_approved')) {
                notifColor = const Color(0xFF8B5CF6);
                notifIcon = Icons.verified_rounded;
              } else if (type.contains('qc_rejected')) {
                notifColor = const Color(0xFFEF4444);
                notifIcon = Icons.cancel_rounded;
              } else if (type.contains('admin_approved')) {
                notifColor = const Color(0xFF10B981);
                notifIcon = Icons.check_circle_rounded;
              } else if (type.contains('admin_rejected')) {
                notifColor = const Color(0xFFEF4444);
                notifIcon = Icons.error_rounded;
              }

              parsedList.add({
                'id': item['id'] ?? 'notif-${DateTime.now().millisecondsSinceEpoch}',
                'title': item['title'] ?? 'Notification',
                'desc': item['desc'] ?? item['message'] ?? '',
                'time': item['time'] ?? 'Just now',
                'icon': notifIcon,
                'color': notifColor,
                'read': item['read'] ?? false,
              });
            }
            if (mounted) {
              setState(() {
                _notifications = parsedList;
              });
            }
          }
        }
      } catch (_) {}
    }

    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _markAllRead() async {
    try {
      final headers = await AuthService.getAuthHeaders();
      final url = Uri.parse('${ApiConstants.baseUrl}${ApiConstants.apiVersion}/notifications/mark-all-read');
      await http.put(url, headers: headers);
    } catch (_) {}

    setState(() {
      for (var n in _notifications) {
        n['read'] = true;
      }
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('All notifications marked as read ✓'),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _clearAll() {
    setState(() {
      _notifications.clear();
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Notifications cleared'),
          backgroundColor: Color(0xFF64748B),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text('Notifications', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
        backgroundColor: Colors.white,
        elevation: 0.5,
        actions: [
          IconButton(
            onPressed: _fetchRealNotifications,
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF2563EB)),
          ),
          TextButton(
            onPressed: _markAllRead,
            child: const Text('Mark All Read', style: TextStyle(color: Color(0xFF2563EB), fontWeight: FontWeight.bold, fontSize: 12)),
          ),
          TextButton(
            onPressed: _clearAll,
            child: const Text('Clear All', style: TextStyle(color: Color(0xFFEF4444), fontWeight: FontWeight.bold, fontSize: 12)),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _notifications.isEmpty
              ? Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(40),
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.notifications_none_rounded, size: 54, color: Color(0xFF94A3B8)),
                      SizedBox(height: 12),
                      Text('No Notifications Yet', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF0F172A))),
                      SizedBox(height: 6),
                      Text('Real-time system and QC approval alerts will appear here.', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Color(0xFF64748B))),
                    ],
                  ),
                )
              : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _notifications.length,
              itemBuilder: (ctx, idx) {
                final item = _notifications[idx];
                final color = item['color'] as Color;
                final isRead = item['read'] as bool? ?? false;

                return Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  elevation: 0,
                  color: isRead ? Colors.white : color.withOpacity(0.04),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(color: isRead ? const Color(0xFFE2E8F0) : color.withOpacity(0.3)),
                  ),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: color.withOpacity(0.12),
                      child: Icon(item['icon'] as IconData, color: color, size: 22),
                    ),
                    title: Text(
                      item['title']?.toString() ?? '',
                      style: TextStyle(
                        fontWeight: isRead ? FontWeight.w600 : FontWeight.bold,
                        color: const Color(0xFF0F172A),
                      ),
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 4.0),
                      child: Text(
                        item['desc']?.toString() ?? '',
                        style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                      ),
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          item['time']?.toString() ?? '',
                          style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8)),
                        ),
                        if (!isRead) ...[
                          const SizedBox(height: 4),
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
