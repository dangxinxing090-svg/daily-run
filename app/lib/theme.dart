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

  // 色块地形版：Radix sand 灰阶做纸面与文字，sage 做地形色块，橙只给轨迹与主按钮。
  static const int sand1 = 0xFFFDFDFC;
  static const int sand2 = 0xFFF9F9F8;
  static const int sand3 = 0xFFF1F0EF;
  static const int sand4 = 0xFFE9E8E6;
  static const int sand5 = 0xFFE2E0DE;
  static const int sand6 = 0xFFDBD8D5;
  static const int sand11 = 0xFF6F6A62;
  static const int sand12 = 0xFF1F211F;
  static const int sage3 = 0xFFEEF2EA;
  static const int sage4 = 0xFFE4EBDF;
  static const int sage5 = 0xFFD9E4D1;
  static const int sage6 = 0xFFCDDBC0;
  static const int sage7 = 0xFFBDCEAB;
  static const int sage8 = 0xFFA7BD90;
  static const int teal3 = 0xFFE0F8F3;
  static const int teal6 = 0xFFA1DED2;
  static const int teal12 = 0xFF0D3D38;
  static const int red3 = 0xFFFEEBEC;
  static const int red6 = 0xFFFDBDBE;
  static const int red9 = 0xFFE5484D;
  static const int red11 = 0xFFCE2C31;
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

  // 色块地形：卡片要特别圆，圆角随容器层级递减。
  static const double cardRadius = 24;
  static const double mapRadius = 22;
  static const double thumbRadius = 16;
  static const double cellRadius = 10;
  static const double dialogRadius = 28;
  static const double fieldRadius = 16;

  // 只有「开跑」两个字用的展示字体，子集化后约 2 KB。
  static const String displayFont = 'RunDisplay';

  // 玻璃拟态
  static const double glassRadius = 28;
  static const double glassBlur = 18;
  static const double glassAlpha = 0.55;
  static const double glassEdgeAlpha = 0.75;
  static const double auraAlpha = 0.22;
}
