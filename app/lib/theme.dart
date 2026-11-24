// 前端设计规范定稿色板与排版常量，纯 Dart，Flutter 侧用 Color(0xFFxxxxxx) 取值

class AppPalette {
  static const int orange1 = 0xFFFEFCFB;
  static const int orange2 = 0xFFFFF7ED;
  static const int orange3 = 0xFFFFEFD6;
  static const int orange5 = 0xFFFFD19A;
  static const int orange6 = 0xFFFFC182;
  static const int orange9 = 0xFFF76B15;
  static const int orange10 = 0xFFEF5F00;
  static const int orange11 = 0xFFCC4E00;
  static const int teal9 = 0xFF12A594;
  static const int slate1 = 0xFFFCFCFD;
  static const int slate6 = 0xFFD9D9E0;
  static const int slate7 = 0xFFCDCED6;
  static const int slate11 = 0xFF60646C;
  static const int slate12 = 0xFF1C2024;
}

/// 字号比例。今日与跑中用大字号强化核心操作与结果，记录页用小字号承载密度。
class AppType {
  static const double tiny = 12;
  static const double small = 14;
  static const double body = 16;
  static const double title = 24;
  static const double hero = 44;
  static const double display = 76;
  static const int weightRegular = 400;
  static const int weightMedium = 500;
  static const int weightSemibold = 600;
  static const int weightBold = 700;
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

  // 玻璃拟态
  static const double glassRadius = 28;
  static const double glassBlur = 18;
  static const double glassAlpha = 0.55;
  static const double glassEdgeAlpha = 0.75;
  static const double auraAlpha = 0.22;
}
