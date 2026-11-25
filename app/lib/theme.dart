// 前端设计规范定稿色板与排版常量，纯 Dart，Flutter 侧用 Color(0xFFxxxxxx) 取值

class AppPalette {
  static const int teal9 = 0xFF12A594;
  static const int slate1 = 0xFFFCFCFD;
  static const int slate6 = 0xFFD9D9E0;
  static const int slate7 = 0xFFCDCED6;
  static const int slate11 = 0xFF60646C;
  static const int slate12 = 0xFF1C2024;

  // 主色：湖蓝。换配色只改这四行：实色填充、轨迹强调、浅底、描边。
  static const int accent = 0xFF0D74CE;
  static const int accentStrong = 0xFF0090FF;
  static const int accentSoft = 0xFFE6F4FE;
  static const int accentEdge = 0xFFACD8FC;

  // 第二色：青瓷。只给「成绩类」信息用，配速曲线、分段柱、打卡与连续天数，
  // 和主色的路线/按钮分开，界面才有层次，不会一片蓝。
  static const int perform = 0xFF008573;
  static const int performStrong = 0xFF12A594;
  static const int performSoft = 0xFFE0F8F3;
  static const int performEdge = 0xFFA1DED2;

  // 色块地形版：Radix sand 灰阶做纸面与文字，sage 做地形色块，主色只给轨迹与主按钮。
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

  // 玻璃拟态
  static const double glassRadius = 28;
  static const double glassBlur = 18;
  static const double glassAlpha = 0.55;
  static const double glassEdgeAlpha = 0.75;
  static const double auraAlpha = 0.22;
}
