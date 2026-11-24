import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'data/persistence_store.dart';
import 'domain/checkin.dart';
import 'domain/models.dart';
import 'domain/repository.dart';
import 'domain/tracking.dart';
import 'platform/gallery.dart';
import 'platform/location_source.dart';
import 'theme.dart';
import 'widgets/run_share_card.dart';
import 'widgets/terrain.dart';

Color _c(int v) => Color(v);

const List<String> _weekCn = ['一', '二', '三', '四', '五', '六', '日'];

String _clock(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

String _paceLabel(double secPerKm) {
  if (secPerKm <= 0) return '--\'--"';
  final s = secPerKm.round();
  return '${s ~/ 60}\'${(s % 60).toString().padLeft(2, '0')}"';
}

String _dateCn(DateTime d) => '${d.month}月${d.day}日 周${_weekCn[d.weekday - 1]}';

int _daysInMonth(DateTime d) => DateTime(d.year, d.month + 1, 0).day;

void runAppMain() => runApp(const RunApp());

class RunApp extends StatelessWidget {
  const RunApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '每日跑步',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: _c(AppPalette.sand2),
        colorScheme: ColorScheme.light(primary: _c(AppPalette.orange11)),
      ),
      home: const AppShell(),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  final PersistentRepository _repo =
      PersistentRepository(createPersistenceStore());
  final GallerySaver _gallery = createGallerySaver();
  final CheckInService _checkIn = CheckInService();
  final LocationSource _location = createLocationSource();
  StreamSubscription<TrackFix>? _fixSub;

  final DateTime _today = DateTime(
    DateTime.now().year,
    DateTime.now().month,
    DateTime.now().day,
  );

  bool _ready = false;
  late Plan _plan;
  TrackingManager? _tracker;
  Timer? _timer;
  Duration _elapsed = Duration.zero;
  double _pace = 0;
  int _heartRate = 0;
  int _tick = 0;
  DateTime _simulated = DateTime.now().subtract(const Duration(minutes: 31));
  WorkoutSession? _finished;
  CheckIn? _todayCheckIn;
  bool _paused = false;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await _repo.init();
    } catch (_) {
      // 存储不可用时退回内存，界面仍可操作，只是不跨重启。
    }
    final empty = _repo.plans.isEmpty &&
        _repo.sessions.isEmpty &&
        _repo.checkIns.isEmpty;
    if (empty) await _seedDemo();
    _plan = _repo.planFor(_today) ??
        Plan(
          id: 'p-${_today.year}${_today.month}${_today.day}',
          date: _today,
          startMinutes: 19 * 60 + 30,
          type: '轻松跑',
          targetMeters: 5000,
          reminderOffsetMinutes: 15,
        );
    if (_repo.planFor(_today) == null) await _repo.savePlan(_plan);
    if (!mounted) return;
    setState(() => _ready = true);
  }

  Future<void> _seedDemo() async {
    await _repo.savePlan(Plan(
      id: 'p-${_today.year}${_today.month}${_today.day}',
      date: _today,
      startMinutes: 19 * 60 + 30,
      type: '轻松跑',
      targetMeters: 5000,
      reminderOffsetMinutes: 15,
    ));
    for (int i = 1; i <= 5; i++) {
      await _repo.saveCheckIn(
          _checkIn.manual(_today.subtract(Duration(days: i))));
    }
    await _repo.saveSession(WorkoutSession(
      id: 's-demo-1',
      startTime: _today.subtract(const Duration(days: 3, hours: 1)),
      elapsed: const Duration(minutes: 37, seconds: 12),
      distanceMeters: 6300,
      calories: 410,
    ));
    await _repo.saveSession(WorkoutSession(
      id: 's-demo-2',
      startTime: _today.subtract(const Duration(days: 6, hours: 1)),
      elapsed: const Duration(minutes: 30, seconds: 8),
      distanceMeters: 5020,
      calories: 326,
    ));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _fixSub?.cancel();
    _location.stop();
    super.dispose();
  }

  int get _streak => _checkIn.streak(_repo.checkIns, _today);
  double get _monthKm =>
      _checkIn.monthDistance(_repo.sessions, _today.year, _today.month) / 1000;
  int get _monthCount =>
      _checkIn.monthCheckInCount(_repo.checkIns, _today.year, _today.month);

  WorkoutSession? get _latestSession {
    final list = List<WorkoutSession>.from(_repo.sessions)
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
    return list.isEmpty ? null : list.first;
  }

  void _addSimulatedPoint() {
    _tick++;
    _simulated = _simulated.add(const Duration(seconds: 60));
    _tracker!.addPoint(
      lat: 39.9 + _tick * 0.0018,
      lng: 116.3 + math.sin(_tick * 0.55) * 0.0016,
      ts: _simulated,
      accuracyMeters: 6,
    );
  }

  DateTime get _trackerNow =>
      _location.isSimulated ? _simulated : DateTime.now();

  void _applyFix(TrackFix fix) {
    if (_tracker == null || _finished != null) return;
    _simulated = fix.ts;
    _tracker!.addPoint(
      lat: fix.lat,
      lng: fix.lng,
      ts: fix.ts,
      accuracyMeters: fix.accuracyMeters,
      speedMps: fix.speedMps,
      heartRateBpm: fix.heartRateBpm,
    );
    if (fix.heartRateBpm != null) _heartRate = fix.heartRateBpm!;
    _elapsed = _tracker!.elapsed(fix.ts);
    _pace = _tracker!.currentPaceSecPerKm();
  }

  void _attachStreams() {
    _timer?.cancel();
    _fixSub?.cancel();
    if (_location.isSimulated) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _tracker == null) return;
        setState(() {
          _addSimulatedPoint();
          _elapsed = _tracker!.elapsed(_trackerNow);
          _pace = _tracker!.currentPaceSecPerKm();
        });
      });
    } else {
      _fixSub = _location.start().listen(
        (fix) {
          if (!mounted || _finished != null) return;
          setState(() => _applyFix(fix));
        },
        onError: (_) {},
      );
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _tracker == null) return;
        setState(() => _elapsed = _tracker!.elapsed(_trackerNow));
      });
    }
  }

  void _start() {
    final messenger = ScaffoldMessenger.of(context);
    _location.ensurePermission().then((ok) {
      if (!mounted) return;
      if (!ok) {
        messenger.showSnackBar(const SnackBar(
          content: Text('需要定位权限才能记录轨迹', style: TextStyle(fontSize: 14)),
        ));
        return;
      }
      _beginTracking();
    });
  }

  void _beginTracking() {
    _tracker = TrackingManager(
      sessionId: 's-${DateTime.now().millisecondsSinceEpoch}',
      planId: _plan.id,
    );
    _tracker!.start(_trackerNow);
    _finished = null;
    _todayCheckIn = null;
    _paused = false;
    _heartRate = 0;
    _tick = 0;
    if (_location.isSimulated) {
      _simulated = DateTime.now().subtract(const Duration(minutes: 31));
      _addSimulatedPoint();
    }
    _attachStreams();
    setState(() {
      _elapsed = Duration.zero;
      _pace = 0;
      _tab = 1;
    });
  }

  void _togglePause() {
    if (_tracker == null || _finished != null) return;
    if (_paused) {
      _tracker!.resume(_trackerNow);
      _attachStreams();
      setState(() => _paused = false);
    } else {
      _timer?.cancel();
      _fixSub?.cancel();
      _location.stop();
      _tracker!.pause(_trackerNow);
      setState(() => _paused = true);
    }
  }

  Future<void> _finish() async {
    _timer?.cancel();
    _fixSub?.cancel();
    _location.stop();
    if (_tracker == null || _tracker!.status == SessionStatus.finished) return;
    if (_paused) {
      _tracker!.resume(_trackerNow);
      _paused = false;
    }
    if (_location.isSimulated) {
      while (_tracker!.distanceMeters < 5210) {
        _addSimulatedPoint();
      }
      _simulated = _simulated.add(const Duration(seconds: 24));
    }
    final end = _trackerNow;
    final session = _tracker!.finish(end);
    await _repo.saveSession(session);
    if (_checkIn.shouldAutoCheckIn(session, _plan)) {
      _todayCheckIn = _checkIn.auto(session, end);
      await _repo.saveCheckIn(_todayCheckIn!);
    }
    if (!mounted) return;
    // 结束后留在跑中页原地展示结果，不跳转。
    setState(() {
      _finished = session;
      _elapsed = session.elapsed;
      _pace = session.averagePaceSecPerKm;
    });
  }

  Future<void> _manualCheckIn() async {
    if (_finished == null) return;
    final ci = _checkIn.manual(_trackerNow);
    await _repo.saveCheckIn(ci);
    _todayCheckIn = ci;
    if (!mounted) return;
    setState(() {});
  }

  void _showResult(BuildContext context) {
    final s = _finished;
    if (s == null) return;
    showDialog<void>(
      context: context,
      barrierColor: _c(AppPalette.sand12).withValues(alpha: 0.28),
      builder: (dialogContext) => _ResultDialog(
        session: s,
        autoCheckedIn: _todayCheckIn != null,
        onSave: () {
          Navigator.pop(dialogContext);
          _openCard(context, s);
        },
        onManualCheckIn: _todayCheckIn == null
            ? () {
                Navigator.pop(dialogContext);
                _manualCheckIn();
              }
            : null,
      ),
    );
  }

  void _openCard(BuildContext context, WorkoutSession s) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _CardScreen(
        session: s,
        dateLabel: _dateCn(s.startTime),
        autoCheckedIn: s.id == _finished?.id && _todayCheckIn != null,
        gallery: _gallery,
      ),
    ));
  }

  void _showSession(BuildContext context, WorkoutSession s) {
    showDialog<void>(
      context: context,
      barrierColor: _c(AppPalette.sand12).withValues(alpha: 0.28),
      builder: (dialogContext) => _SessionDialog(
        session: s,
        onCard: () {
          Navigator.pop(dialogContext);
          _openCard(context, s);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final pages = <Widget>[
      _TodayPage(
        today: _today,
        streak: _streak,
        monthKm: _monthKm,
        monthCount: _monthCount,
        targetKm: _plan.targetMeters / 1000,
        planType: _plan.type,
        planLabel: _plan.startLabel,
        lastSession: _latestSession,
        onRun: _start,
        onLastSession: (s) => _showSession(context, s),
      ),
      _RunningPage(
        session: _finished,
        tracker: _tracker,
        points: _tracker?.points ?? const <TrackPoint>[],
        elapsed: _elapsed,
        distance: (_tracker?.distanceMeters ?? 0) / 1000,
        pace: _paceLabel(_pace),
        heartRate: _heartRate > 0 ? _heartRate : null,
        kcal: ((_tracker?.distanceMeters ?? 0) / 1000 * 65).round(),
        paused: _paused,
        autoCheckedIn: _todayCheckIn != null,
        today: _today,
        planType: _plan.type,
        targetKm: _plan.targetMeters / 1000,
        onStart: _start,
        onPause: _togglePause,
        onFinish: _finish,
        onResult: () => _showResult(context),
      ),
      _HistoryPage(
        repo: _repo,
        today: _today,
        monthKm: _monthKm,
        monthCount: _monthCount,
        onSession: (s) => _showSession(context, s),
      ),
    ];

    return Scaffold(
      body: SafeArea(child: pages[_tab]),
      bottomNavigationBar: _TabBar(selected: _tab, onChanged: (i) => setState(() => _tab = i)),
    );
  }
}

/* ---------------- 色块地形页面骨架 ---------------- */

const double _gap = 10;
const double _pagePad = 14;

const List<String> _monthCn = [
  '一月', '二月', '三月', '四月', '五月', '六月',
  '七月', '八月', '九月', '十月', '十一月', '十二月',
];

TextStyle _txt(double size, int weight, Color color) => TextStyle(
      fontSize: size,
      fontWeight: FontWeight.values[weight ~/ 100],
      color: color,
      height: 1.2,
    );

/// 数字统一等宽，字号大到 28 以上才收紧字距，避免小字挤在一起。
TextStyle _num(double size, int weight, int color) => TextStyle(
      fontSize: size,
      fontWeight: FontWeight.values[weight ~/ 100],
      color: _c(color),
      height: 1.05,
      letterSpacing: size >= 28 ? -size * 0.02 : 0,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

String _dateShort(DateTime d) => '${d.month}月${d.day}日';

Widget _page(List<Widget> children) => Container(
      color: _c(AppPalette.sand2),
      padding: const EdgeInsets.all(_pagePad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );

Widget _header(Widget left, Widget right) => SizedBox(
      height: 28,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [left, right],
      ),
    );

Widget _pageTitle(String text) => Text(
      text,
      style: _txt(20, 600, _c(AppPalette.sand12)).copyWith(letterSpacing: -0.2),
    );

Widget _pageMeta(String text) => Text(text, style: _txt(12, 500, _c(AppPalette.sand11)));

Widget _card({
  required Widget child,
  EdgeInsetsGeometry padding = EdgeInsets.zero,
  EdgeInsetsGeometry? margin,
  bool shadow = false,
}) =>
    Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: _c(AppPalette.sand1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(width: AppRules.hairline, color: _c(AppPalette.sand6)),
        boxShadow: shadow
            ? [
                BoxShadow(
                  color: _c(AppPalette.sand12).withValues(alpha: 0.08),
                  blurRadius: 28,
                  offset: const Offset(0, 10),
                ),
              ]
            : null,
      ),
      child: child,
    );

Widget _iconLabel(
  IconData icon,
  String text, {
  int color = AppPalette.sand11,
  double size = 12,
  int weight = 500,
  double gap = 6,
}) =>
    Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: _c(color)),
        SizedBox(width: gap),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _txt(size, weight, _c(color)),
          ),
        ),
      ],
    );

/// 三格数据条：竖分隔线高度由容器固定高度约束，避免用 1px 描边。
class _StatBar extends StatelessWidget {
  final List<Widget> cells;
  final double height;
  final bool card;

  const _StatBar({required this.cells, this.height = 64, this.card = true});

  @override
  Widget build(BuildContext context) {
    final row = SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (int i = 0; i < cells.length; i++) ...[
            Expanded(child: cells[i]),
            if (i < cells.length - 1)
              Container(width: AppRules.hairline, color: _c(AppPalette.sand6)),
          ],
        ],
      ),
    );
    if (!card) {
      return Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(width: AppRules.hairline, color: _c(AppPalette.sand6)),
            bottom: BorderSide(width: AppRules.hairline, color: _c(AppPalette.sand6)),
          ),
        ),
        child: row,
      );
    }
    return _card(child: row);
  }
}

class _StatCell extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatCell({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _iconLabel(icon, label),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value, style: _num(20, 600, AppPalette.sand12)),
            ),
          ],
        ),
      );
}

class _Pill extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool filled;
  final VoidCallback? onTap;
  final double fontSize;

  const _Pill({
    required this.label,
    required this.icon,
    required this.filled,
    required this.onTap,
    this.fontSize = 14,
  });

  @override
  Widget build(BuildContext context) {
    final fg = filled ? _c(AppPalette.sand1) : _c(AppPalette.sand12);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: filled ? _c(AppPalette.orange11) : _c(AppPalette.sand1),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            width: AppRules.hairline,
            color: filled ? _c(AppPalette.orange11) : _c(AppPalette.sand6),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: fg),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _txt(fontSize, 600, fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 地形上的开跑钮：104 实心圆套一圈 0.5px 光环，落在地图中央偏上。
class _StartButton extends StatelessWidget {
  final VoidCallback onTap;

  const _StartButton({required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 132,
          height: 132,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              width: AppRules.hairline,
              color: _c(AppPalette.sand1).withValues(alpha: 0.9),
            ),
          ),
          child: Center(
            child: Container(
              width: 104,
              height: 104,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _c(AppPalette.orange11),
                border: Border.all(
                    width: AppRules.hairline, color: _c(AppPalette.orange11)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.play_arrow, size: 22, color: _c(AppPalette.sand1)),
                  const SizedBox(height: 3),
                  Text('开跑', style: _txt(12, 600, _c(AppPalette.sand1))),
                ],
              ),
            ),
          ),
        ),
      );
}

class _Tag extends StatelessWidget {
  final IconData icon;
  final String label;

  const _Tag({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(
          color: _c(AppPalette.teal3),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(width: AppRules.hairline, color: _c(AppPalette.teal6)),
        ),
        child: _iconLabel(icon, label,
            color: AppPalette.teal12, weight: 600, gap: 5),
      );
}

/// 贴在地图角上的小胶囊，浅底细边，不抢地形。
Widget _mapChip(Widget child, {bool accent = false}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: _c(AppPalette.sand1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          width: AppRules.hairline,
          color: _c(accent ? AppPalette.orange6 : AppPalette.sand6),
        ),
      ),
      child: child,
    );

Widget _liveDot(double size, int color) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: _c(color)),
    );

class _TabBar extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onChanged;

  const _TabBar({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: _c(AppPalette.sand1),
          border: Border(
            top: BorderSide(width: AppRules.hairline, color: _c(AppPalette.sand6)),
          ),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 52,
            child: Row(
              children: [
                _item(0, Icons.calendar_today_outlined, '今日'),
                _item(1, Icons.route_outlined, '跑中'),
                _item(2, Icons.list_outlined, '记录'),
              ],
            ),
          ),
        ),
      );

  Widget _item(int index, IconData icon, String label) {
    final on = selected == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => onChanged(index),
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 20,
                color: _c(on ? AppPalette.orange11 : AppPalette.sand11)),
            const SizedBox(height: 3),
            Text(label,
                style: _txt(
                    12, on ? 600 : 400, _c(on ? AppPalette.orange11 : AppPalette.sand11))),
          ],
        ),
      ),
    );
  }
}

/* ---------------- 今日 ---------------- */

class _TodayPage extends StatelessWidget {
  final DateTime today;
  final int streak;
  final double monthKm;
  final int monthCount;
  final double targetKm;
  final String planType;
  final String planLabel;
  final WorkoutSession? lastSession;
  final VoidCallback onRun;
  final ValueChanged<WorkoutSession>? onLastSession;

  const _TodayPage({
    required this.today,
    required this.streak,
    required this.monthKm,
    required this.monthCount,
    required this.targetKm,
    required this.planType,
    required this.planLabel,
    required this.lastSession,
    required this.onRun,
    required this.onLastSession,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) {
          final mapH = (box.maxHeight - 300).clamp(200.0, 560.0);
          return _page([
            _header(
              _pageTitle('今日'),
              _pageMeta('${today.month}月${today.day}日 周${_weekCn[today.weekday - 1]}'),
            ),
            const SizedBox(height: _gap),
            SizedBox(
              height: mapH + 40,
              child: Stack(
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: mapH,
                    child: TerrainMap(track: false),
                  ),
                  Positioned(
                    left: 12,
                    top: 12,
                    child: _mapChip(
                      _iconLabel(Icons.schedule, '$planType $planLabel',
                          color: AppPalette.sand12, weight: 600, gap: 5),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: mapH * 0.46 - 66,
                    height: 132,
                    child: Center(child: _StartButton(onTap: onRun)),
                  ),
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 0,
                    child: _StatBar(
                      height: 64,
                      cells: [
                        _StatCell(
                            icon: Icons.check_circle_outline,
                            label: '连续',
                            value: '$streak 天'),
                        _StatCell(
                            icon: Icons.straighten,
                            label: '本月',
                            value: '${monthKm.toStringAsFixed(1)} km'),
                        _StatCell(
                            icon: Icons.calendar_month_outlined,
                            label: '打卡',
                            value: '$monthCount 次'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: _gap),
            _card(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  _iconLabel(Icons.track_changes, '今日目标'),
                  const Spacer(),
                  Text('${targetKm.toStringAsFixed(2)} km',
                      style: _num(20, 600, AppPalette.sand12)),
                ],
              ),
            ),
            const SizedBox(height: _gap),
            _lastRun(),
          ]);
        },
      );

  Widget _lastRun() {
    final last = lastSession;
    return GestureDetector(
      onTap: last != null && onLastSession != null
          ? () => onLastSession!(last)
          : null,
      behavior: HitTestBehavior.opaque,
      child: _card(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 56,
              height: 50,
              child: TerrainMap(
                points: last?.points ?? const <TrackPoint>[],
                view: const Rect.fromLTWH(56, 96, 200, 200),
                radius: 8,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    last == null ? '还没有跑步记录' : '上次跑步　${_dateShort(last.startTime)}',
                    style: _txt(12, 500, _c(AppPalette.sand11)),
                  ),
                  if (last != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      '${(last.distanceMeters / 1000).toStringAsFixed(2)} km　${_clock(last.elapsed)}',
                      style: _num(14, 600, AppPalette.sand12),
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 16, color: _c(AppPalette.sand11)),
          ],
        ),
      ),
    );
  }
}

/* ---------------- 跑中 ---------------- */

class _RunningPage extends StatelessWidget {
  final WorkoutSession? session;
  final TrackingManager? tracker;
  final List<TrackPoint> points;
  final Duration elapsed;
  final double distance;
  final String pace;
  final int? heartRate;
  final int kcal;
  final bool paused;
  final bool autoCheckedIn;
  final DateTime today;
  final String planType;
  final double targetKm;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final Future<void> Function() onFinish;
  final VoidCallback onResult;

  const _RunningPage({
    required this.session,
    required this.tracker,
    required this.points,
    required this.elapsed,
    required this.distance,
    required this.pace,
    required this.heartRate,
    required this.kcal,
    required this.paused,
    required this.autoCheckedIn,
    required this.today,
    required this.planType,
    required this.targetKm,
    required this.onStart,
    required this.onPause,
    required this.onFinish,
    required this.onResult,
  });

  @override
  Widget build(BuildContext context) {
    if (session != null) return _result(session!);
    if (tracker == null) return _idle();
    return _live();
  }

  Widget _idle() => _page([
        _header(_pageTitle('跑中'), _pageMeta('未开始')),
        const SizedBox(height: _gap),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              final mapH = box.maxHeight.clamp(240.0, 900.0);
              return Stack(
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: mapH,
                    child: const TerrainMap(track: false),
                  ),
                  Positioned(
                    left: 12,
                    top: 12,
                    child: _mapChip(_iconLabel(Icons.route_outlined, '待记录')),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    top: mapH * 0.46 - 66,
                    height: 132,
                    child: Center(child: _StartButton(onTap: onStart)),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: _gap),
        _card(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              _iconLabel(Icons.track_changes, '今日目标'),
              const Spacer(),
              Text('${targetKm.toStringAsFixed(2)} km',
                  style: _num(20, 600, AppPalette.sand12)),
            ],
          ),
        ),
      ]);

  Widget _live() {
    final livePace = paceBuckets(points);
    final cells = <Widget>[
      _StatCell(
          icon: Icons.straighten,
          label: '距离',
          value: '${distance.toStringAsFixed(2)} km'),
      _StatCell(icon: Icons.speed_outlined, label: '配速', value: pace),
      if (heartRate != null)
        _StatCell(
            icon: Icons.favorite_outline, label: '心率', value: '$heartRate'),
      _StatCell(
          icon: Icons.local_fire_department_outlined, label: '消耗', value: '$kcal'),
    ];
    return _page([
      _header(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _liveDot(7, AppPalette.orange9),
            const SizedBox(width: 7),
            _pageTitle(paused ? '已暂停' : '运动中'),
          ],
        ),
        _pageMeta('${_dateShort(today)}　$planType'),
      ),
      const SizedBox(height: _gap),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            alignment: Alignment.centerLeft,
            child: Text(_clock(elapsed), style: _num(48, 700, AppPalette.sand12)),
          ),
          const SizedBox(height: 5),
          _iconLabel(Icons.schedule, '已用时间'),
        ],
      ),
      const SizedBox(height: _gap),
      Expanded(
        child: Stack(
          children: [
            Positioned.fill(child: TerrainMap(points: points)),
            Positioned(
              right: 10,
              top: 10,
              child: _mapChip(
                accent: true,
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _liveDot(6, AppPalette.orange9),
                    const SizedBox(width: 6),
                    Text('记录中', style: _txt(12, 600, _c(AppPalette.orange11))),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      if (livePace.length >= 2) ...[
        const SizedBox(height: _gap),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text('配速曲线', style: _txt(12, 600, _c(AppPalette.sand11))),
            const Spacer(),
            Text('每 500 米', style: _num(12, 500, AppPalette.sand11)),
          ],
        ),
        const SizedBox(height: 4),
        PaceProfile(values: livePace),
      ],
      const SizedBox(height: _gap),
      _StatBar(cells: cells),
      const SizedBox(height: _gap),
      Row(
        children: [
          Expanded(
            child: _Pill(
              label: paused ? '继续' : '暂停',
              icon: paused ? Icons.play_arrow_outlined : Icons.pause_outlined,
              filled: false,
              onTap: onPause,
            ),
          ),
          const SizedBox(width: _gap),
          Expanded(
            child: _Pill(
              label: '结束',
              icon: Icons.flag_outlined,
              filled: true,
              onTap: () => onFinish(),
            ),
          ),
        ],
      ),
    ]);
  }

  Widget _result(WorkoutSession s) => LayoutBuilder(
        builder: (context, box) {
          final splits = [for (final sp in s.splits) sp.seconds];
          return _page([
            _header(
              _pageTitle('完成'),
              _Tag(
                icon: Icons.check,
                label: autoCheckedIn ? '已打卡' : '已记录',
              ),
            ),
            const SizedBox(height: _gap),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: TerrainMap(points: s.points),
                  ),
                  Positioned(
                    right: 10,
                    bottom: 10,
                    child: _mapChip(
                      Text('轨迹 ${s.points.length} 点',
                          style: _num(12, 600, AppPalette.sand11)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: _gap),
            _card(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('本次距离', style: _txt(12, 500, _c(AppPalette.sand11))),
                  const SizedBox(height: 4),
                  Text(
                    '${(s.distanceMeters / 1000).toStringAsFixed(2)} km',
                    style: _num(48, 700, AppPalette.sand12),
                  ),
                  const SizedBox(height: 10),
                  FittedBox(
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _iconLabel(Icons.schedule, _clock(s.elapsed),
                            color: AppPalette.sand12, size: 14, weight: 600, gap: 5),
                        const SizedBox(width: 16),
                        _iconLabel(Icons.speed_outlined, s.averagePaceLabel,
                            color: AppPalette.sand12, size: 14, weight: 600, gap: 5),
                        const SizedBox(width: 16),
                        _iconLabel(Icons.local_fire_department_outlined,
                            '${s.calories} kcal',
                            color: AppPalette.sand12, size: 14, weight: 600, gap: 5),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: _gap),
            _card(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text('配速曲线', style: _txt(12, 600, _c(AppPalette.sand11))),
                      const Spacer(),
                      Text('每公里', style: _num(12, 500, AppPalette.sand11)),
                    ],
                  ),
                  const SizedBox(height: 4),
                  PaceProfile(values: splits, height: 36),
                ],
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: _Pill(
                    label: '查看完成数据',
                    icon: Icons.route_outlined,
                    filled: true,
                    onTap: onResult,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(width: _gap),
                Expanded(
                  child: _Pill(
                    label: '再跑一次',
                    icon: Icons.play_arrow_outlined,
                    filled: false,
                    onTap: onStart,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ]);
        },
      );
}

/* ---------------- 记录 ---------------- */

class _HistoryPage extends StatelessWidget {
  final Repository repo;
  final DateTime today;
  final double monthKm;
  final int monthCount;
  final ValueChanged<WorkoutSession> onSession;

  const _HistoryPage({
    required this.repo,
    required this.today,
    required this.monthKm,
    required this.monthCount,
    required this.onSession,
  });

  @override
  Widget build(BuildContext context) {
    final sessions = List<WorkoutSession>.from(repo.sessions)
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
    return Container(
      color: _c(AppPalette.sand2),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(_pagePad, _pagePad, _pagePad, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(_pageTitle('记录'), _pageMeta(_monthCn[today.month - 1])),
            const SizedBox(height: 8),
            _StatBar(
              cells: [
                _StatCell(
                    icon: Icons.straighten,
                    label: '本月里程',
                    value: '${monthKm.toStringAsFixed(1)} km'),
                _StatCell(
                    icon: Icons.calendar_month_outlined,
                    label: '打卡次数',
                    value: '$monthCount 次'),
              ],
            ),
            const SizedBox(height: 8),
            _card(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      _iconLabel(Icons.calendar_today_outlined, '${today.month} 月月历',
                          color: AppPalette.sand12, size: 14, weight: 600, gap: 7),
                      const Spacer(),
                      Text('周一起', style: _txt(12, 500, _c(AppPalette.sand11))),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _MonthGrid(repo: repo, today: today),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text('历史记录', style: _txt(12, 500, _c(AppPalette.sand11))),
            const SizedBox(height: 2),
            if (sessions.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text('还没有跑步记录',
                      style: _txt(14, 500, _c(AppPalette.sand11))),
                ),
              ),
            for (final s in sessions)
              _HistoryRow(session: s, onTap: () => onSession(s)),
          ],
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  final WorkoutSession session;
  final VoidCallback onTap;

  const _HistoryRow({required this.session, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final km = session.distanceMeters / 1000;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: _card(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 54,
              height: 46,
              child: TerrainMap(
                points: session.points,
                view: const Rect.fromLTWH(50, 96, 220, 220),
                radius: 8,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Expanded(
                        child: Text(_dateCn(session.startTime),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: _txt(14, 600, _c(AppPalette.sand12))),
                      ),
                      Text('${km.toStringAsFixed(2)} km',
                          style: _num(14, 600, AppPalette.orange11)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('${_clock(session.elapsed)}　${session.averagePaceLabel}',
                      style: _num(12, 500, AppPalette.sand11)),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 16, color: _c(AppPalette.sand11)),
          ],
        ),
      ),
    );
  }
}

class _MonthGrid extends StatelessWidget {
  final Repository repo;
  final DateTime today;

  const _MonthGrid({required this.repo, required this.today});

  @override
  Widget build(BuildContext context) {
    final first = DateTime(today.year, today.month, 1);
    final lead = first.weekday - 1;
    final total = _daysInMonth(today);
    final weeks = <List<int?>>[];
    var week = <int?>[];
    for (int i = 0; i < lead; i++) {
      week.add(null);
    }
    for (int day = 1; day <= total; day++) {
      week.add(day);
      if (week.length == 7) {
        weeks.add(week);
        week = <int?>[];
      }
    }
    while (week.isNotEmpty && week.length < 7) {
      week.add(null);
    }
    if (week.isNotEmpty) weeks.add(week);

    return Column(
      children: [
        Row(
          children: [
            for (final w in _weekCn)
              Expanded(
                child: Center(
                  child: Text(w, style: _txt(12, 500, _c(AppPalette.sand11))),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        for (final wk in weeks)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                for (final day in wk)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: _cell(day),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _cell(int? day) {
    if (day == null) return const SizedBox(height: 26);
    final date = DateTime(today.year, today.month, day);
    final done = repo.hasCheckIn(date);
    final isToday = day == today.day;
    final int bg;
    final int fg;
    final int edge;
    final int weight;
    if (isToday) {
      bg = AppPalette.sand1;
      fg = AppPalette.orange11;
      edge = AppPalette.orange11;
      weight = 700;
    } else if (done) {
      bg = AppPalette.teal9;
      fg = AppPalette.sand12;
      edge = AppPalette.teal9;
      weight = 600;
    } else {
      bg = AppPalette.sand2;
      fg = AppPalette.sand11;
      edge = AppPalette.sand6;
      weight = 500;
    }
    return Container(
      height: 26,
      decoration: BoxDecoration(
        color: _c(bg),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(width: AppRules.hairline, color: _c(edge)),
      ),
      child: Center(
        child: Text('$day',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.values[weight ~/ 100],
              color: _c(fg),
              height: 1,
              fontFeatures: const [FontFeature.tabularFigures()],
            )),
      ),
    );
  }
}

/* ---------------- 分段配速柱 ---------------- */

class _SplitBars extends StatelessWidget {
  final List<double> seconds;

  const _SplitBars({required this.seconds});

  @override
  Widget build(BuildContext context) {
    if (seconds.isEmpty) {
      return Text('这次没有分段数据',
          style: _txt(12, 500, _c(AppPalette.sand11)));
    }
    final shown = seconds.take(6).toList();
    var lo = shown.first;
    var hi = shown.first;
    for (final v in shown) {
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    final span = (hi - lo).abs() < 1 ? 1.0 : hi - lo;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (int i = 0; i < shown.length; i++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_paceLabel(shown[i]),
                      style: _num(12, 500, AppPalette.sand11)),
                  const SizedBox(height: 4),
                  Container(
                    height: 22 + (shown[i] - lo) / span * 24,
                    decoration: BoxDecoration(
                      color: _c(AppPalette.sage7),
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(
                          width: AppRules.hairline, color: _c(AppPalette.sage8)),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text('${i + 1} km', style: _txt(12, 400, _c(AppPalette.sand11))),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/* ---------------- 弹层 ---------------- */

Widget _dialogShell(BuildContext context,
    {required String title, required Widget child}) {
  final maxH = MediaQuery.sizeOf(context).height * 0.88;
  return Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 440, maxHeight: maxH),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _c(AppPalette.sand1),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(width: AppRules.hairline, color: _c(AppPalette.sand6)),
            boxShadow: [
              BoxShadow(
                color: _c(AppPalette.sand12).withValues(alpha: 0.22),
                blurRadius: 48,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(title, style: _txt(20, 600, _c(AppPalette.sand12))),
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                              width: AppRules.hairline,
                              color: _c(AppPalette.sand6)),
                        ),
                        child: Text('关闭',
                            style: _txt(12, 500, _c(AppPalette.sand11))),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                child,
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _ResultDialog extends StatelessWidget {
  final WorkoutSession session;
  final bool autoCheckedIn;
  final VoidCallback onSave;
  final VoidCallback? onManualCheckIn;

  const _ResultDialog({
    required this.session,
    required this.autoCheckedIn,
    required this.onSave,
    required this.onManualCheckIn,
  });

  @override
  Widget build(BuildContext context) => _dialogShell(
        context,
        title: '完成数据',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text('${(session.distanceMeters / 1000).toStringAsFixed(2)} km',
                    style: _num(28, 600, AppPalette.sand12)),
                const Spacer(),
                Text(_clock(session.elapsed),
                    style: _num(20, 600, AppPalette.sand12)),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(height: 132, child: TerrainMap(points: session.points)),
            const SizedBox(height: 12),
            _StatBar(
              card: false,
              cells: [
                _StatCell(
                    icon: Icons.speed_outlined,
                    label: '配速',
                    value: session.averagePaceLabel),
                _StatCell(
                    icon: Icons.local_fire_department_outlined,
                    label: '消耗',
                    value: '${session.calories}'),
                _StatCell(
                    icon: Icons.route_outlined,
                    label: '轨迹点',
                    value: '${session.points.length}'),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text('分段配速', style: _txt(14, 600, _c(AppPalette.sand12))),
                const Spacer(),
                Text('每公里', style: _txt(12, 500, _c(AppPalette.sand11))),
              ],
            ),
            const SizedBox(height: 10),
            _SplitBars(seconds: [for (final s in session.splits) s.seconds]),
            const SizedBox(height: 14),
            _Pill(
                label: '保存记录图',
                icon: Icons.share_outlined,
                filled: true,
                onTap: onSave),
            if (!autoCheckedIn && onManualCheckIn != null) ...[
              const SizedBox(height: 8),
              _Pill(
                  label: '手动补卡',
                  icon: Icons.check_circle_outline,
                  filled: false,
                  onTap: onManualCheckIn),
            ],
          ],
        ),
      );
}

class _SessionDialog extends StatelessWidget {
  final WorkoutSession session;
  final VoidCallback onCard;

  const _SessionDialog({required this.session, required this.onCard});

  @override
  Widget build(BuildContext context) => _dialogShell(
        context,
        title: '单次记录',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_dateCn(session.startTime),
                    style: _txt(14, 600, _c(AppPalette.sand12))),
                _Tag(icon: Icons.check, label: '已完成'),
              ],
            ),
            const SizedBox(height: 6),
            Text('${(session.distanceMeters / 1000).toStringAsFixed(2)} km',
                style: _num(28, 600, AppPalette.orange11)),
            const SizedBox(height: 10),
            SizedBox(height: 130, child: TerrainMap(points: session.points)),
            const SizedBox(height: 12),
            _StatBar(
              card: false,
              cells: [
                _StatCell(
                    icon: Icons.schedule,
                    label: '用时',
                    value: _clock(session.elapsed)),
                _StatCell(
                    icon: Icons.speed_outlined,
                    label: '配速',
                    value: session.averagePaceLabel),
                _StatCell(
                    icon: Icons.route_outlined,
                    label: '轨迹点',
                    value: '${session.points.length}'),
              ],
            ),
            const SizedBox(height: 12),
            _SplitBars(seconds: [for (final s in session.splits) s.seconds]),
            const SizedBox(height: 12),
            _Pill(
                label: '生成记录图',
                icon: Icons.share_outlined,
                filled: true,
                onTap: onCard),
          ],
        ),
      );
}

/* ---------------- 记录图全屏页 ---------------- */

class _CardScreen extends StatefulWidget {
  final WorkoutSession session;
  final String dateLabel;
  final bool autoCheckedIn;
  final GallerySaver gallery;
  const _CardScreen({
    required this.session,
    required this.dateLabel,
    required this.autoCheckedIn,
    required this.gallery,
  });

  @override
  State<_CardScreen> createState() => _CardScreenState();
}

class _CardScreenState extends State<_CardScreen> {
  bool _saving = false;
  String? _message;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      final bytes = await renderShareCardPng(
        widget.session,
        dateLabel: widget.dateLabel,
        autoCheckedIn: widget.autoCheckedIn,
      );
      final name =
          'daily-run-${widget.session.startTime.year}${widget.session.startTime.month.toString().padLeft(2, '0')}${widget.session.startTime.day.toString().padLeft(2, '0')}.png';
      final ok = await widget.gallery.savePng(bytes, name);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _message = ok ? '已保存到手机相册' : '当前为预览环境，手机上使用可保存到相册';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _message = '保存失败，请重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: _c(AppPalette.sand2),
        appBar: AppBar(
          backgroundColor: _c(AppPalette.sand2),
          surfaceTintColor: Colors.transparent,
          title: Text('运动记录图',
              style: _txt(16, 600, _c(AppPalette.sand12))),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(18),
          child: Column(
            children: [
              FittedBox(
                child: RunShareCard(
                  session: widget.session,
                  dateLabel: widget.dateLabel,
                  autoCheckedIn: widget.autoCheckedIn,
                ),
              ),
              if (_message != null) ...[
                const SizedBox(height: 14),
                Text(_message!, style: _txt(12, 500, _c(AppPalette.sand11))),
              ],
              const SizedBox(height: 18),
              _Pill(
                label: _saving ? '正在生成图片' : '保存图片到手机',
                icon: Icons.download_outlined,
                filled: true,
                onTap: _saving ? null : _save,
              ),
            ],
          ),
        ),
      );
}
