// 前端设计规范定稿色板与排版常量，纯 Dart，Flutter 侧用 Color(0xFFxxxxxx) 取值

class AppPalette {
  static const int orange1 = 0xFFFEFCFB;
  static const int orange2 = 0xFFFFF7ED;
  static const int orange3 = 0xFFFFEFD6;
  static const int orange5 = 0xFFFFD19A;
  static const int orange9 = 0xFFF76B15;
  static const int orange10 = 0xFFEF5F00;
  static const int orange11 = 0xFFCC4E00;
  static const int teal9 = 0xFF12A594;
  static const int slate1 = 0xFFFCFCFD;
  static const int slate6 = 0xFFD9D9E0;
  static const int slate11 = 0xFF60646C;
  static const int slate12 = 0xFF1C2024;
}

class AppType {
  static const double xsmall = 12;
  static const double body = 14;
  static const double headline = 24;
  static const double giant = 72;
  static const int weightRegular = 400;
  static const int weightMedium = 500;
  static const int weightSemibold = 600;
}

/// 12 到 15 度斜切，落地时对应 ClipPath 加 CustomClipper
class AppCut {
  static const String trapezoid = '8%,0 100%,0 92%,100% 0,100%';
  static const String band = '0,0 100%,0 100%,56% 0,100%';
  static const double skewX = -0.194;
}

class AppRules {
  static const double hairline = 0.5;
  static const double iconStroke = 1.5;
  static const int motionMs = 250;
}
