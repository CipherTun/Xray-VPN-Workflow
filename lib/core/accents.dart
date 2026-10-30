import 'package:flutter/material.dart';

class Accent {
  const Accent(this.name, this.color);
  final String name;
  final Color color;
}

class Accents {
  /// Index 0 is the default: a calm, slightly desaturated turquoise.
  static const presets = <Accent>[
    Accent('Lagoon', Color(0xFF5BB8AE)),
    Accent('Blue', Color(0xFF5B8DEF)),
    Accent('Black', Color(0xFF1B222C)),
    Accent('Green', Color(0xFF63C58A)),
    Accent('Pink', Color(0xFFE7799F)),
    Accent('Teal', Color(0xFF1FA3A0)),
  ];
  static const customIndex = 6;
}
