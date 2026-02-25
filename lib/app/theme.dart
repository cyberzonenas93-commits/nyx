import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Centralized theme system for Media Privacy Vault
/// Dark-first design that communicates privacy and security
class AppTheme {
  // Color System
  static const Color primary = Color(0xFF0E0E11); // Deep charcoal / near-black
  static const Color surface = Color(0xFF17171C); // Dark slate
  static const Color accent = Color(0xFF2EE6A6); // Emerald / Teal
  static const Color warning = Color(0xFFFF6B6B); // Soft red
  static const Color text = Color(0xFFF5F5F7); // Off-white
  
  // Additional colors
  static const Color surfaceVariant = Color(0xFF1E1E24);
  static const Color accentVariant = Color(0xFF1FCB8A);
  static const Color divider = Color(0xFF2A2A30);
  static const Color error = Color(0xFFFF4444);
  
  // Border radius
  static const double radius = 12.0;
  static const double radiusLarge = 16.0;
  static const double radiusSmall = 8.0;
  
  // Elevation
  static const double elevationLow = 2.0;
  static const double elevationMedium = 4.0;
  static const double elevationHigh = 6.0;
  
  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      primaryColor: primary,
      scaffoldBackgroundColor: primary,
      colorScheme: const ColorScheme.dark(
        primary: accent,
        secondary: accentVariant,
        surface: surface,
        error: error,
        onPrimary: primary,
        onSecondary: primary,
        onSurface: text,
        onError: text,
      ),
      
      // AppBar
      appBarTheme: const AppBarTheme(
        backgroundColor: surface,
        elevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: text),
        titleTextStyle: TextStyle(
          color: text,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          fontFamily: 'Inter',
        ),
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      
      // Card
      cardTheme: CardThemeData(
        color: surface,
        elevation: elevationLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        margin: const EdgeInsets.all(8),
      ),
      
      // Input Decoration
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceVariant,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: const BorderSide(color: divider, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: const BorderSide(color: divider, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: const BorderSide(color: accent, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: const BorderSide(color: error, width: 1),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        labelStyle: const TextStyle(color: text, fontSize: 14),
        hintStyle: TextStyle(color: text.withOpacity(0.5), fontSize: 14),
      ),
      
      // Button
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: primary,
          elevation: elevationMedium,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            fontFamily: 'Inter',
          ),
        ),
      ),
      
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            fontFamily: 'Inter',
          ),
        ),
      ),
      
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          side: const BorderSide(color: divider, width: 1),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            fontFamily: 'Inter',
          ),
        ),
      ),
      
      // Dialog
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        elevation: elevationHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
        ),
        titleTextStyle: const TextStyle(
          color: text,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          fontFamily: 'Inter',
        ),
        contentTextStyle: const TextStyle(
          color: text,
          fontSize: 14,
          fontFamily: 'Inter',
        ),
      ),
      
      // Text Theme
      textTheme: const TextTheme(
        displayLarge: TextStyle(
          color: text,
          fontSize: 32,
          fontWeight: FontWeight.w700,
          fontFamily: 'Inter',
          letterSpacing: -0.5,
        ),
        displayMedium: TextStyle(
          color: text,
          fontSize: 28,
          fontWeight: FontWeight.w600,
          fontFamily: 'Inter',
        ),
        displaySmall: TextStyle(
          color: text,
          fontSize: 24,
          fontWeight: FontWeight.w600,
          fontFamily: 'Inter',
        ),
        headlineMedium: TextStyle(
          color: text,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          fontFamily: 'Inter',
        ),
        titleLarge: TextStyle(
          color: text,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          fontFamily: 'Inter',
        ),
        titleMedium: TextStyle(
          color: text,
          fontSize: 16,
          fontWeight: FontWeight.w500,
          fontFamily: 'Inter',
        ),
        bodyLarge: TextStyle(
          color: text,
          fontSize: 16,
          fontWeight: FontWeight.w400,
          fontFamily: 'Inter',
        ),
        bodyMedium: TextStyle(
          color: text,
          fontSize: 14,
          fontWeight: FontWeight.w400,
          fontFamily: 'Inter',
        ),
        bodySmall: TextStyle(
          color: text,
          fontSize: 12,
          fontWeight: FontWeight.w400,
          fontFamily: 'Inter',
        ),
      ),
      
      // Icon Theme
      iconTheme: const IconThemeData(
        color: text,
        size: 24,
      ),
      
      // Divider
      dividerTheme: const DividerThemeData(
        color: divider,
        thickness: 1,
        space: 1,
      ),
    );
  }
}
