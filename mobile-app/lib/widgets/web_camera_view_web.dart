import 'package:flutter/material.dart';

class WebLiveCameraView extends StatelessWidget {
  final bool isRecording;
  final String? environmentTag;

  const WebLiveCameraView({
    super.key,
    required this.isRecording,
    this.environmentTag,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0F172A),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isRecording ? Icons.videocam_rounded : Icons.videocam_outlined,
              size: 64,
              color: isRecording ? Colors.redAccent : Colors.white54,
            ),
            const SizedBox(height: 12),
            Text(
              isRecording ? 'Recording in progress...' : 'Web Camera Ready',
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
