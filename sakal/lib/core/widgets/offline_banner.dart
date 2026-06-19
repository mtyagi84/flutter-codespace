import 'package:flutter/material.dart';

class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFFE65100),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: const Row(
        children: [
          Icon(Icons.wifi_off_rounded, size: 13, color: Colors.white),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Offline Mode — Changes will sync on your next online login',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}
