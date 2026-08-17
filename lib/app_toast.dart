import 'package:flutter/material.dart';
import 'package:toastification/toastification.dart';

class AppToast {
  // Base commune pour éviter la répétition des paramètres de style
  static void _show({
    required BuildContext context,
    required ToastificationType type,
    required String title,
    required String description,
    required IconData icon,
    required Color primaryColor,
    required Color backgroundColor,
    required Color foregroundColor,
  }) {
    toastification.show(
      context: context,
      type: type,
      style: ToastificationStyle.flat,
      borderSide: BorderSide.none,
      autoCloseDuration: const Duration(seconds: 4),
      title: Text(
        title,
        style: const TextStyle(
          fontFamily: 'Poppins',
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
      description: Text(
        description,
        style: const TextStyle(
          fontFamily: 'Poppins',
          fontWeight: FontWeight.w400,
          fontSize: 13,
        ),
      ),
      alignment: Alignment.topCenter,
      direction: TextDirection.ltr,
      animationDuration: const Duration(milliseconds: 300),
      icon: Icon(icon, size: 24),
      primaryColor: primaryColor,
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      borderRadius: BorderRadius.circular(12),
      boxShadow: const [
        BoxShadow(
          color: Color(0x07000000),
          blurRadius: 16,
          offset: Offset(0, 16),
        ),
      ],
      showProgressBar: true,
      closeOnClick: false,
      pauseOnHover: true,
      dragToClose: true,
    );
  }

  // Toast Erreur
  static void showError(
    BuildContext context, {
    required String title,
    required String description,
  }) {
    _show(
      context: context,
      type: ToastificationType.error,
      title: title,
      description: description,
      icon: Icons.error_outline_rounded,
      primaryColor: const Color(0xFFDC2626),
      backgroundColor: const Color(0xFFFEF2F2),
      foregroundColor: const Color(0xFF991B1B),
    );
  }

  // Toast Succès
  static void showSuccess(
    BuildContext context, {
    required String title,
    required String description,
  }) {
    _show(
      context: context,
      type: ToastificationType.success,
      title: title,
      description: description,
      icon: Icons.check_circle_outline_rounded,
      primaryColor: const Color(0xFF16A34A),
      backgroundColor: const Color(0xFFF0FDF4),
      foregroundColor: const Color(0xFF166534),
    );
  }

  // Toast Information
  static void showInfo(
    BuildContext context, {
    required String title,
    required String description,
  }) {
    _show(
      context: context,
      type: ToastificationType.info,
      title: title,
      description: description,
      icon: Icons.info_outline_rounded,
      primaryColor: const Color(0xFF2563EB),
      backgroundColor: const Color(0xFFF0F9FF),
      foregroundColor: const Color(0xFF1D4ED8),
    );
  }
}
