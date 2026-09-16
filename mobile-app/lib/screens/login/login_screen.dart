import 'package:flutter/material.dart';
import '../../config/routes/app_routes.dart';
import '../../core/constants/api_constants.dart';
import '../../core/theme/app_colors.dart';
import '../../services/auth_service.dart';
import '../../widgets/powered_by_footer.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _identifierController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _isLoading = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _identifierController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleLogin([String? customIdentifier, String? customPassword]) async {
    final identifier = customIdentifier ?? _identifierController.text;
    final password = customPassword ?? _passwordController.text;

    if (customIdentifier == null && !_formKey.currentState!.validate()) return;

    FocusScope.of(context).unfocus();
    setState(() => _isLoading = true);

    final res = await AuthService.login(identifier, password);

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (res['success'] == true) {
      final role = (res['role'] ?? 'candidate').toString().toLowerCase();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Authenticated as ${role.toUpperCase()}! Opening app...'),
          backgroundColor: AppColors.primary,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );

      if (role == 'admin' || role.contains('admin')) {
        Navigator.pushReplacementNamed(context, AppRoutes.adminDashboard);
      } else if (role == 'qc_team' || role == 'qc' || role == 'qc_reviewer' || role.contains('qc')) {
        Navigator.pushReplacementNamed(context, AppRoutes.qcDashboard);
      } else if (role == 'vendor') {
        Navigator.pushReplacementNamed(context, AppRoutes.vendorDashboard);
      } else {
        Navigator.pushReplacementNamed(context, AppRoutes.home);
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(res['message'] ?? 'Authentication failed. Please check credentials.'),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showForgotPasswordDialog() {
    final resetController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Reset Password', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Color(0xFF0F172A))),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Enter your registered email address or username to receive password reset instructions.', style: TextStyle(fontSize: 13, color: Color(0xFF64748B))),
            const SizedBox(height: 16),
            TextField(
              controller: resetController,
              decoration: InputDecoration(
                hintText: 'Enter Email / Username',
                prefixIcon: const Icon(Icons.email_outlined, color: Color(0xFF3B82F6)),
                filled: true,
                fillColor: const Color(0xFFF8FAFC),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF94A3B8))),
          ),
          ElevatedButton(
            onPressed: () {
              final text = resetController.text.trim();
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(text.isNotEmpty
                      ? 'Password reset link sent to $text!'
                      : 'Password reset link sent to your registered email address!'),
                  backgroundColor: const Color(0xFF16A34A),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2563EB), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            child: const Text('Send Reset Link', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showServerSettingsDialog() {
    final serverController = TextEditingController(text: ApiConstants.baseUrl);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: const [
            Icon(Icons.dns_rounded, color: Color(0xFF3B82F6)),
            SizedBox(width: 8),
            Text('Server Settings', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Specify backend REST API URL connected to your PostgreSQL database:',
              style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: serverController,
              decoration: InputDecoration(
                labelText: 'Backend URL',
                hintText: 'http://192.168.1.87:5000',
                filled: true,
                fillColor: const Color(0xFFF8FAFC),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                ActionChip(
                  label: const Text('Local PC (Wi-Fi)', style: TextStyle(fontSize: 12)),
                  onPressed: () => serverController.text = 'http://192.168.1.87:5000',
                ),
                ActionChip(
                  label: const Text('Cloud VPS', style: TextStyle(fontSize: 12)),
                  onPressed: () => serverController.text = 'https://elevateiq-softtech.com/video-platform-api',
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Color(0xFF94A3B8))),
          ),
          ElevatedButton(
            onPressed: () {
              final newUrl = serverController.text.trim();
              if (newUrl.isNotEmpty) {
                setState(() {
                  ApiConstants.customServerUrl = newUrl;
                });
              }
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Server endpoint set to: ${ApiConstants.baseUrl}'),
                  backgroundColor: const Color(0xFF16A34A),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Save Server', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Server Config Icon Button
                Align(
                  alignment: Alignment.topRight,
                  child: IconButton(
                    icon: const Icon(Icons.settings_outlined, color: Color(0xFF94A3B8), size: 22),
                    tooltip: 'Backend Server Settings',
                    onPressed: _showServerSettingsDialog,
                  ),
                ),

                // Blue Video Camera Icon Badge
                Center(
                  child: Container(
                    width: 68,
                    height: 68,
                    margin: const EdgeInsets.only(bottom: 20),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF3B82F6), Color(0xFF1D4ED8)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF3B82F6).withOpacity(0.35),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: const Icon(Icons.videocam_rounded, color: Colors.white, size: 36),
                  ),
                ),

                const Center(
                  child: Text(
                    'Welcome Back!',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: AppColors.textPrimaryLight,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                const Center(
                  child: Text(
                    'Sign in to continue to your account',
                    style: TextStyle(
                      fontSize: 14,
                      color: AppColors.textSecondaryLight,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(height: 28),

                // Email Input Label & Field
                Row(
                  children: const [
                    Icon(Icons.email_outlined, size: 18, color: Color(0xFF3B82F6)),
                    SizedBox(width: 6),
                    Text(
                      'Email',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _identifierController,
                  keyboardType: TextInputType.emailAddress,
                  style: const TextStyle(color: Color(0xFF0F172A), fontSize: 14, fontWeight: FontWeight.w600),
                  decoration: InputDecoration(
                    hintText: 'Enter your Email',
                    hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                    prefixIcon: const Icon(Icons.email_outlined, color: Color(0xFF94A3B8)),
                    filled: true,
                    fillColor: const Color(0xFFF8FAFC),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: Color(0xFFDBEAFE)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: Color(0xFFDBEAFE)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: Color(0xFF3B82F6), width: 1.5),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  ),
                  validator: (val) {
                    if (val == null || val.trim().isEmpty) {
                      return 'Please enter email address or username';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 18),

                // Password Input Label & Field
                Row(
                  children: const [
                    Icon(Icons.lock_outline_rounded, size: 18, color: Color(0xFF3B82F6)),
                    SizedBox(width: 6),
                    Text(
                      'Password',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF1E293B)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  style: const TextStyle(color: Color(0xFF0F172A), fontSize: 14, fontWeight: FontWeight.w600),
                  decoration: InputDecoration(
                    hintText: 'Enter your Password',
                    hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                    prefixIcon: const Icon(Icons.lock_outline_rounded, color: Color(0xFF94A3B8)),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                        color: const Color(0xFF94A3B8),
                      ),
                      onPressed: () {
                        setState(() => _obscurePassword = !_obscurePassword);
                      },
                    ),
                    filled: true,
                    fillColor: const Color(0xFFF8FAFC),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: Color(0xFFDBEAFE)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: Color(0xFFDBEAFE)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: const BorderSide(color: Color(0xFF3B82F6), width: 1.5),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                  ),
                  validator: (val) {
                    if (val == null || val.trim().isEmpty) {
                      return 'Please enter password';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                // Login Button
                ElevatedButton(
                  onPressed: _isLoading ? null : () => _handleLogin(),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 3,
                    shadowColor: const Color(0xFF2563EB).withOpacity(0.4),
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        )
                      : const Text(
                          'Login',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                ),
                const SizedBox(height: 24),

                // Don't Have An Account? Candidate Sign Up Redirect Link
                Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        "Don't have an account? ",
                        style: TextStyle(fontSize: 14, color: Color(0xFF64748B), fontWeight: FontWeight.w500),
                      ),
                      GestureDetector(
                        onTap: () => Navigator.pushNamed(context, AppRoutes.candidateSignup),
                        child: const Text(
                          'Sign Up',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF10B981),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                const PoweredByFooter(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
