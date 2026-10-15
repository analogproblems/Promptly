import 'package:flutter/material.dart';

/// The eight named host colours, tuned per theme so a chip reads well on
/// both backgrounds.
Color hostColor(String? name, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return switch (name) {
    'red' => dark ? const Color(0xFFFF7B72) : const Color(0xFFCF222E),
    'orange' => dark ? const Color(0xFFF0883E) : const Color(0xFFBC4C00),
    'yellow' => dark ? const Color(0xFFE3B341) : const Color(0xFF9A6700),
    'green' => dark ? const Color(0xFF7CE38B) : const Color(0xFF1A7F37),
    'teal' => dark ? const Color(0xFF76E3EA) : const Color(0xFF1B7C83),
    'blue' => dark ? const Color(0xFF79C0FF) : const Color(0xFF0969DA),
    'purple' => dark ? const Color(0xFFD2A8FF) : const Color(0xFF8250DF),
    _ => dark ? const Color(0xFF8B949E) : const Color(0xFF656D76),
  };
}
