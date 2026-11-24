import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

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
import 'widgets/field_shapes.dart';

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
        scaffoldBackgroundColor: _c(AppPalette.orange1),
        colorScheme: ColorScheme.light(primary: _c(AppPalette.orange9)),
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
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ResultSheet(
        session: s,
        streak: _streak,
        autoCheckedIn: _todayCheckIn != null,
        onSave: () => _openCard(context, s),
        onManualCheckIn: _todayCheckIn == null ? _manualCheckIn : null,
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
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SessionSheet(
        session: s,
        onCard: () => _openCard(context, s),
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
        onRun: _start,
      ),
      _RunningPage(
        session: _finished,
        tracker: _tracker,
        points: _tracker?.points ?? const <TrackPoint>[],
        elapsed: _elapsed,
        distance: (_tracker?.distanceMeters ?? 0) / 1000,
        pace: _paceLabel(_pace),
        heartRate: _heartRate > 0 ? _heartRate : null,
        paused: _paused,
        streak: _streak,
        autoCheckedIn: _todayCheckIn != null,
        onStart: _start,
        onPause: _togglePause,
        onFinish: _finish,
        onResult: () => _showResult(context),
        onManualCheckIn: _manualCheckIn,
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

/* ---------------- 流场页面骨架 ---------------- */

/// 每页底色都是浅暖白，流带由各页自己决定，不用满版玻璃或深色。
Widget _fieldPage({
  required List<Widget> bands,
  required Widget child,
  bool bottomInset = true,
}) =>
    Stack(
      children: [
        Positioned.fill(child: Container(color: _c(AppPalette.orange1))),
        ...bands,
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.fromLTRB(18, 18, 18, bottomInset ? 78 : 18),
            child: child,
          ),
        ),
      ],
    );

/// 流场里的玻璃卡，比上一版克制：圆角 10，半透明浅底加 0.5px 边。
Widget _fieldGlass({
  required Widget child,
  EdgeInsetsGeometry padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
}) =>
    ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: _c(AppPalette.slate1).withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(width: AppRules.hairline, color: _c(AppPalette.slate6)),
          ),
          child: child,
        ),
      ),
    );

class _TabBar extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onChanged;
  const _TabBar({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) => Container(
        height: 78,
        decoration: BoxDecoration(
          color: _c(AppPalette.orange1),
          border: Border(
            top: BorderSide(width: AppRules.hairline, color: _c(AppPalette.slate6)),
          ),
        ),
        child: Row(
          children: [
            _tabItem(0, Icons.today, '今日'),
            _tabItem(1, Icons.route, '跑中'),
            _tabItem(2, Icons.history, '记录'),
          ],
        ),
      );

  Widget _tabItem(int index, IconData icon, String label) {
    final on = selected == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => onChanged(index),
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20,
                color: on ? _c(AppPalette.orange11) : _c(AppPalette.slate11)),
            const SizedBox(height: 4),
            ClipPath(
              clipper: const PolygonClipper(FieldCut.chip),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
                color: on ? _c(AppPalette.orange3) : Colors.transparent,
                child: Text(label,
                    style: TextStyle(
                        fontSize: AppType.tiny,
                        fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                        color: on
                            ? _c(AppPalette.orange11)
                            : _c(AppPalette.slate11))),
              ),
            ),
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
  final VoidCallback onRun;
  const _TodayPage({
    required this.today,
    required this.streak,
    required this.monthKm,
    required this.monthCount,
    required this.targetKm,
    required this.onRun,
  });

  @override
  Widget build(BuildContext context) => _fieldPage(
        bands: [
          flowBand(vertices: FieldCut.bandDown, height: 150, top: 92, left: -48, right: -48),
          flowBand(
            vertices: FieldCut.bandThin,
            height: 54,
            top: 320,
            left: -48,
            right: -48,
            opacity: 0.32,
          ),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('今日',
                    style: TextStyle(
                        fontSize: AppType.title,
                        fontWeight: FontWeight.w700,
                        color: _c(AppPalette.slate12),
                        letterSpacing: -0.02)),
                Text('${today.month}月${today.day}日 ${_weekCn[today.weekday - 1]}',
                    style: TextStyle(
                        fontSize: AppType.tiny,
                        fontWeight: FontWeight.w500,
                        color: _c(AppPalette.slate11))),
              ],
            ),
            const SizedBox(height: 26),
            Row(
              children: [
                Icon(Icons.flag_outlined,
                    size: 16, color: _c(AppPalette.slate12)),
                const SizedBox(width: 6),
                Text('今日目标',
                    style: TextStyle(
                        fontSize: AppType.tiny,
                        fontWeight: FontWeight.w500,
                        color: _c(AppPalette.slate12))),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                cutNumber(targetKm.toStringAsFixed(2)),
                const SizedBox(width: 8),
                Text('km',
                    style: TextStyle(
                        fontSize: AppType.title,
                        fontWeight: FontWeight.w600,
                        color: _c(AppPalette.slate12))),
              ],
            ),
            const SizedBox(height: 22),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Icon(Icons.local_fire_department,
                    size: 20, color: _c(AppPalette.slate12)),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('连续打卡',
                        style: TextStyle(
                            fontSize: AppType.tiny,
                            fontWeight: FontWeight.w500,
                            color: _c(AppPalette.slate12))),
                    Text('$streak',
                        style: TextStyle(
                            fontSize: AppType.hero,
                            fontWeight: FontWeight.w700,
                            color: _c(AppPalette.slate12),
                            height: 1.05,
                            fontFeatures: const [FontFeature.tabularFigures()])),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 22),
            _FieldButton(
              label: '开跑',
              icon: Icons.play_arrow,
              onTap: onRun,
              filled: true,
            ),
            const Spacer(),
            _fieldGlass(
              child: Column(
                children: [
                  _glassLine(
                    icon: Icons.straighten,
                    label: '本月累计',
                    value: '${monthKm.toStringAsFixed(1)} km',
                  ),
                  _glassLine(
                    icon: Icons.check_circle_outline,
                    label: '打卡次数',
                    value: '$monthCount 次',
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _glassLine({
    required IconData icon,
    required String label,
    required String value,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Icon(icon, size: 16, color: _c(AppPalette.slate11)),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: AppType.tiny, color: _c(AppPalette.slate11))),
            const Spacer(),
            Text(value,
                style: TextStyle(
                    fontSize: AppType.small,
                    fontWeight: FontWeight.w600,
                    color: _c(AppPalette.slate12),
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ],
        ),
      );
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
  final bool paused;
  final int streak;
  final bool autoCheckedIn;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final Future<void> Function() onFinish;
  final VoidCallback onResult;
  final Future<void> Function() onManualCheckIn;

  const _RunningPage({
    required this.session,
    required this.tracker,
    required this.points,
    required this.elapsed,
    required this.distance,
    required this.pace,
    required this.heartRate,
    required this.paused,
    required this.streak,
    required this.autoCheckedIn,
    required this.onStart,
    required this.onPause,
    required this.onFinish,
    required this.onResult,
    required this.onManualCheckIn,
  });

  @override
  Widget build(BuildContext context) {
    if (session != null) return _result(context, session!);
    if (tracker == null) return _idle(context);
    return _live(context);
  }

  Widget _idle(BuildContext context) => _fieldPage(
        bands: [
          flowBand(vertices: FieldCut.bandDown, height: 150,
              top: 180, left: -48, right: -48),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('跑中',
                    style: TextStyle(
                        fontSize: AppType.title,
                        fontWeight: FontWeight.w700,
                        color: _c(AppPalette.slate12))),
                Text('准备就绪',
                    style: TextStyle(
                        fontSize: AppType.tiny, color: _c(AppPalette.slate11))),
              ],
            ),
            const Spacer(),
            Text('0:00',
                style: TextStyle(
                    fontSize: AppType.hero,
                    fontWeight: FontWeight.w700,
                    color: _c(AppPalette.slate12),
                    letterSpacing: -0.04)),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.flag_outlined,
                    size: 16, color: _c(AppPalette.slate11)),
                const SizedBox(width: 6),
                Text('目标 5.00 km',
                    style: TextStyle(
                        fontSize: AppType.tiny, color: _c(AppPalette.slate11))),
              ],
            ),
            const SizedBox(height: 26),
            _FieldButton(
                label: '开跑', icon: Icons.play_arrow, onTap: onStart, filled: true),
            const Spacer(),
            Center(
              child: Text('点开跑进入实时',
                  style: TextStyle(
                      fontSize: AppType.tiny, color: _c(AppPalette.slate11))),
            ),
          ],
        ),
      );

  Widget _live(BuildContext context) => Stack(
        children: [
          Positioned.fill(child: Container(color: _c(AppPalette.orange1))),
          // 抽象街区在流带下层
          Positioned(
            left: 12,
            right: 12,
            top: 62,
            height: 190,
            child: Opacity(
              opacity: 0.45,
              child: CustomPaint(painter: FieldTrackPainter(points: points)),
            ),
          ),
          // 主流带，轨迹画成带内白线
          flowBand(
            vertices: FieldCut.bandMid,
            height: 92,
            top: 150,
            left: -48,
            right: -48,
          ),
          Positioned(
            left: 12,
            right: 12,
            top: 150,
            height: 100,
            child: ClipPath(
              clipper: const PolygonClipper(FieldCut.bandMid),
              child: CustomPaint(
                  painter: FieldTrackPainter(points: points, whiteTrack: true)),
            ),
          ),
          Positioned(
            left: 18,
            right: 18,
            top: 4,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.route, size: 16, color: _c(AppPalette.slate12)),
                    const SizedBox(width: 6),
                    Text(paused ? '已暂停' : '运动中',
                        style: TextStyle(
                            fontSize: AppType.body,
                            fontWeight: FontWeight.w600,
                            color: _c(AppPalette.slate12))),
                  ],
                ),
                Text('5.00 km',
                    style: TextStyle(
                        fontSize: AppType.tiny, color: _c(AppPalette.slate11))),
              ],
            ),
          ),
          Positioned(
            left: 18,
            top: 42,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                cutNumber(_clock(elapsed)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(Icons.schedule,
                        size: 16, color: _c(AppPalette.slate11)),
                    const SizedBox(width: 6),
                    Text('已用时间',
                        style: TextStyle(
                            fontSize: AppType.tiny,
                            color: _c(AppPalette.slate11))),
                  ],
                ),
              ],
            ),
          ),
          Positioned(
            left: 14,
            right: 14,
            bottom: 148,
            child: _fieldGlass(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _metric(Icons.straighten, '${distance.toStringAsFixed(2)} km', '已跑距离'),
                  _metric(Icons.speed, pace, '当前配速'),
                  if (heartRate != null)
                    _metric(Icons.favorite, '$heartRate', '心率'),
                ],
              ),
            ),
          ),
          Positioned(
            left: 14,
            right: 14,
            bottom: 76,
            child: Row(
              children: [
                Expanded(
                  child: _FieldButton(
                    label: paused ? '继续' : '暂停',
                    icon: paused ? Icons.play_arrow : Icons.pause,
                    onTap: onPause,
                    filled: false,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _FieldButton(
                    label: '结束',
                    icon: Icons.flag,
                    onTap: () => onFinish(),
                    filled: true,
                  ),
                ),
              ],
            ),
          ),
        ],
      );

  Widget _metric(IconData icon, String value, String label) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: AppType.title,
                  fontWeight: FontWeight.w700,
                  color: _c(AppPalette.slate12),
                  fontFeatures: const [FontFeature.tabularFigures()])),
          const SizedBox(height: 3),
          Row(
            children: [
              Icon(icon, size: 16, color: _c(AppPalette.slate11)),
              const SizedBox(width: 5),
              Text(label,
                  style: TextStyle(
                      fontSize: AppType.tiny, color: _c(AppPalette.slate11))),
            ],
          ),
        ],
      );

  Widget _result(BuildContext context, WorkoutSession s) => _fieldPage(
        bands: [
          flowBand(vertices: FieldCut.bandDown, height: 146,
              top: 96, left: -48, right: -48),
          flowBand(vertices: FieldCut.bandThin, height: 52,
              top: 300, left: -48, right: -48, opacity: 0.3),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('完成',
                    style: TextStyle(
                        fontSize: AppType.title,
                        fontWeight: FontWeight.w700,
                        color: _c(AppPalette.slate12))),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _c(autoCheckedIn
                        ? AppPalette.teal9
                        : AppPalette.slate6),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check,
                          size: 12, color: _c(AppPalette.orange1)),
                      const SizedBox(width: 4),
                      Text(autoCheckedIn ? '已打卡' : '已记录',
                          style: TextStyle(
                              fontSize: AppType.tiny,
                              fontWeight: FontWeight.w600,
                              color: _c(AppPalette.orange1))),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Icon(Icons.straighten,
                    size: 16, color: _c(AppPalette.slate12)),
                const SizedBox(width: 6),
                Text('本次距离',
                    style: TextStyle(
                        fontSize: AppType.tiny,
                        fontWeight: FontWeight.w500,
                        color: _c(AppPalette.slate12))),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                cutNumber((s.distanceMeters / 1000).toStringAsFixed(2)),
                const SizedBox(width: 8),
                Text('km',
                    style: TextStyle(
                        fontSize: AppType.title,
                        fontWeight: FontWeight.w600,
                        color: _c(AppPalette.slate12))),
              ],
            ),
            const SizedBox(height: 18),
            _fieldGlass(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _resultMetric(Icons.schedule, _clock(s.elapsed), '用时'),
                  _resultMetric(Icons.speed, s.averagePaceLabel, '平均配速'),
                  _resultMetric(Icons.local_fire_department, '${s.calories}', '消耗'),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Container(
              height: 92,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    width: AppRules.hairline, color: _c(AppPalette.slate6)),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: CustomPaint(
                    painter: FieldTrackPainter(points: s.points),
                    size: Size.fromHeight(92)),
              ),
            ),
            const Spacer(),
            _FieldButton(
              label: '查看完成数据',
              icon: Icons.list,
              onTap: onResult,
              filled: true,
            ),
            const SizedBox(height: 8),
            _FieldButton(
              label: '再跑一次',
              icon: Icons.play_arrow,
              onTap: onStart,
              filled: false,
            ),
          ],
        ),
      );

  Widget _resultMetric(IconData icon, String value, String label) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: value.length > 5 ? AppType.body : AppType.title,
                  fontWeight: FontWeight.w700,
                  color: _c(AppPalette.slate12),
                  fontFeatures: const [FontFeature.tabularFigures()])),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(icon, size: 16, color: _c(AppPalette.slate11)),
              const SizedBox(width: 5),
              Text(label,
                  style: TextStyle(
                      fontSize: AppType.tiny, color: _c(AppPalette.slate11))),
            ],
          ),
        ],
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
    return _fieldPage(
      bands: const [],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('记录',
                  style: TextStyle(
                      fontSize: AppType.title,
                      fontWeight: FontWeight.w700,
                      color: _c(AppPalette.slate12))),
              Text('${today.month}月',
                  style: TextStyle(
                      fontSize: AppType.tiny, color: _c(AppPalette.slate11))),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(monthKm.toStringAsFixed(1),
                  style: TextStyle(
                      fontSize: AppType.title,
                      fontWeight: FontWeight.w600,
                      color: _c(AppPalette.slate12),
                      fontFeatures: const [FontFeature.tabularFigures()])),
              const SizedBox(width: 10),
              Text('$monthCount 打卡',
                  style: TextStyle(
                      fontSize: AppType.small, color: _c(AppPalette.slate11))),
            ],
          ),
          const SizedBox(height: 10),
          _fieldGlass(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.calendar_month,
                            size: 16, color: _c(AppPalette.slate12)),
                        const SizedBox(width: 5),
                        Text('${today.month}月月历',
                            style: TextStyle(
                                fontSize: AppType.small,
                                fontWeight: FontWeight.w600,
                                color: _c(AppPalette.slate12))),
                      ],
                    ),
                    Text('打卡完成',
                        style: TextStyle(
                            fontSize: AppType.tiny,
                            color: _c(AppPalette.slate11))),
                  ],
                ),
                const SizedBox(height: 7),
                _MonthGrid(repo: repo, today: today),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Icon(Icons.list, size: 16, color: _c(AppPalette.slate12)),
              const SizedBox(width: 6),
              Text('历史记录',
                  style: TextStyle(
                      fontSize: AppType.small,
                      fontWeight: FontWeight.w600,
                      color: _c(AppPalette.slate12))),
            ],
          ),
          const SizedBox(height: 2),
          if (sessions.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text('还没有跑步记录',
                    style: TextStyle(
                        fontSize: AppType.small, color: _c(AppPalette.slate11))),
              ),
            ),
          ...sessions.map((s) => _HistoryRow(session: s, onTap: () => onSession(s))),
        ],
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
    final bandWidth = 52.0 + km * 6.2;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 44,
        margin: const EdgeInsets.only(top: 6),
        decoration: BoxDecoration(
          color: _c(AppPalette.orange2),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              width: AppRules.hairline, color: _c(AppPalette.orange6)),
        ),
        child: Stack(
          children: [
            ClipPath(
              clipper: const PolygonClipper(FieldCut.bandThin),
              child: SizedBox(
                width: bandWidth,
                child: Opacity(
                  opacity: 0.9,
                  child: Container(decoration: BoxDecoration(gradient: fieldFlow)),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.calendar_today,
                              size: 16, color: _c(AppPalette.slate12)),
                          const SizedBox(width: 5),
                          Text(_dateCn(session.startTime),
                              style: TextStyle(
                                  fontSize: AppType.small,
                                  fontWeight: FontWeight.w600,
                                  color: _c(AppPalette.slate12))),
                        ],
                      ),
                      Text('${km.toStringAsFixed(2)} km',
                          style: TextStyle(
                              fontSize: AppType.small,
                              fontWeight: FontWeight.w700,
                              color: _c(AppPalette.orange11),
                              fontFeatures: const [FontFeature.tabularFigures()])),
                    ],
                  ),
                  Row(
                    children: [
                      Icon(Icons.schedule,
                          size: 16, color: _c(AppPalette.slate11)),
                      const SizedBox(width: 6),
                      Text(_clock(session.elapsed),
                          style: TextStyle(
                              fontSize: AppType.tiny,
                              color: _c(AppPalette.slate11),
                              fontFeatures: const [FontFeature.tabularFigures()])),
                      const SizedBox(width: 8),
                      Icon(Icons.speed,
                          size: 16, color: _c(AppPalette.slate11)),
                      const SizedBox(width: 6),
                      Text(session.averagePaceLabel,
                          style: TextStyle(
                              fontSize: AppType.tiny,
                              color: _c(AppPalette.slate11),
                              fontFeatures: const [FontFeature.tabularFigures()])),
                    ],
                  ),
                ],
              ),
            ),
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
    final leading = first.weekday - 1;
    final total = _daysInMonth(today);
    final cells = <Widget>[];
    for (int i = 0; i < leading; i++) {
      cells.add(const SizedBox(height: 24));
    }
    for (int day = 1; day <= total; day++) {
      final done = repo.hasCheckIn(DateTime(today.year, today.month, day));
      final isToday = day == today.day;
      cells.add(Container(
        height: 24,
        decoration: BoxDecoration(
          color: isToday
              ? _c(AppPalette.orange9)
              : done
                  ? _c(AppPalette.teal9)
                  : _c(AppPalette.orange1),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            width: AppRules.hairline,
            color: isToday
                ? _c(AppPalette.orange9)
                : done
                    ? _c(AppPalette.teal9)
                    : _c(AppPalette.slate6),
          ),
        ),
        child: Center(
          child: Text('$day',
              style: TextStyle(
                  fontSize: AppType.tiny,
                  fontWeight: isToday || done
                      ? FontWeight.w600
                      : FontWeight.w500,
                  color: isToday || done
                      ? _c(AppPalette.orange1)
                      : _c(AppPalette.slate11),
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ),
      ));
    }
    return Column(
      children: [
        Row(
          children: List.generate(
            7,
            (i) => Expanded(
              child: Center(
                child: Text(_weekCn[i],
                    style: TextStyle(
                        fontSize: AppType.tiny,
                        color: _c(AppPalette.slate11))),
              ),
            ),
          ),
        ),
        const SizedBox(height: 7),
        GridView.count(
          crossAxisCount: 7,
          mainAxisSpacing: 3,
          crossAxisSpacing: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: cells,
        ),
      ],
    );
  }
}

/* ---------------- 按钮 ---------------- */

class _FieldButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool filled;
  const _FieldButton({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.filled,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 48,
          decoration: BoxDecoration(
            color: filled
                ? _c(AppPalette.orange11)
                : _c(AppPalette.orange2),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              width: AppRules.hairline,
              color: filled
                  ? _c(AppPalette.orange11)
                  : _c(AppPalette.orange6),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: filled ? 20 : 16,
                  color: filled
                      ? _c(AppPalette.orange1)
                      : _c(AppPalette.orange11)),
              const SizedBox(width: 8),
              Text(label,
                  style: TextStyle(
                      fontSize: filled ? AppType.body : AppType.small,
                      fontWeight: FontWeight.w600,
                      color: filled
                          ? _c(AppPalette.orange1)
                          : _c(AppPalette.orange11))),
            ],
          ),
        ),
      );
}

/* ---------------- 弹层 ---------------- */

Widget _fieldSheet({
  required String title,
  required VoidCallback onClose,
  required Widget child,
}) =>
    ClipRRect(
      borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppRules.glassRadius)),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: _c(AppPalette.slate1).withValues(alpha: 0.92),
            borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppRules.glassRadius)),
            border: Border.all(
              width: AppRules.hairline,
              color: _c(AppPalette.slate6),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: AppType.small,
                          fontWeight: FontWeight.w700,
                          color: _c(AppPalette.slate12))),
                  GestureDetector(
                    onTap: onClose,
                    child: Text('关闭',
                        style: TextStyle(
                            fontSize: AppType.tiny,
                            color: _c(AppPalette.slate11))),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              child,
            ],
          ),
        ),
      ),
    );

class _ResultSheet extends StatelessWidget {
  final WorkoutSession session;
  final int streak;
  final bool autoCheckedIn;
  final VoidCallback onSave;
  final Future<void> Function()? onManualCheckIn;
  const _ResultSheet({
    required this.session,
    required this.streak,
    required this.autoCheckedIn,
    required this.onSave,
    required this.onManualCheckIn,
  });

  @override
  Widget build(BuildContext context) => _fieldSheet(
        title: '完成数据',
        onClose: () => Navigator.pop(context),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _sheetMetric(Icons.straighten,
                      '${(session.distanceMeters / 1000).toStringAsFixed(2)} km', '距离'),
                  _sheetMetric(Icons.schedule, _clock(session.elapsed), '用时'),
                  _sheetMetric(Icons.speed, session.averagePaceLabel, '配速'),
                  _sheetMetric(Icons.local_fire_department,
                      '${session.calories}', '消耗'),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                height: 104,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      width: AppRules.hairline, color: _c(AppPalette.slate6)),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: CustomPaint(
                    painter: FieldTrackPainter(points: session.points),
                    size: Size.fromHeight(104),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.route, size: 16, color: _c(AppPalette.slate11)),
                  const SizedBox(width: 6),
                  Text('${session.points.length} 个轨迹点',
                      style: TextStyle(
                          fontSize: AppType.tiny,
                          color: _c(AppPalette.slate11))),
                ],
              ),
              const SizedBox(height: 8),
              Text('${session.splits.length} 段分段配速',
                  style: TextStyle(
                      fontSize: AppType.tiny,
                      fontWeight: FontWeight.w600,
                      color: _c(AppPalette.slate12))),
              const SizedBox(height: 8),
              Row(
                children: session.splits.take(5).map((sp) => Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: Text(sp.kmIndex.toString(),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: AppType.tiny,
                                color: _c(AppPalette.slate11),
                                fontFeatures: const [FontFeature.tabularFigures()])),
                      ),
                    )).toList(),
              ),
              const SizedBox(height: 12),
              _FieldButton(
                  label: '保存记录图',
                  icon: Icons.share,
                  onTap: onSave,
                  filled: true),
              if (!autoCheckedIn && onManualCheckIn != null) ...[
                const SizedBox(height: 8),
                _FieldButton(
                    label: '手动补卡',
                    icon: Icons.check_circle_outline,
                    onTap: () => onManualCheckIn!(),
                    filled: false),
              ],
            ],
          ),
        ),
      );

  Widget _sheetMetric(IconData icon, String value, String label) => Column(
        children: [
          Icon(icon, size: 16, color: _c(AppPalette.slate11)),
          const SizedBox(height: 4),
          Text(value,
              style: TextStyle(
                  fontSize: AppType.tiny,
                  fontWeight: FontWeight.w700,
                  color: _c(AppPalette.slate12),
                  fontFeatures: const [FontFeature.tabularFigures()])),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(
                  fontSize: AppType.tiny, color: _c(AppPalette.slate11))),
        ],
      );
}

class _SessionSheet extends StatelessWidget {
  final WorkoutSession session;
  final VoidCallback onCard;
  const _SessionSheet({required this.session, required this.onCard});

  @override
  Widget build(BuildContext context) => _fieldSheet(
        title: _dateCn(session.startTime),
        onClose: () => Navigator.pop(context),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 150,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      width: AppRules.hairline, color: _c(AppPalette.slate6)),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: CustomPaint(
                    painter: FieldTrackPainter(points: session.points),
                    size: Size.fromHeight(150),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _sheetMetric(Icons.straighten,
                      '${(session.distanceMeters / 1000).toStringAsFixed(2)} km', '距离'),
                  _sheetMetric(Icons.schedule, _clock(session.elapsed), '用时'),
                  _sheetMetric(Icons.speed, session.averagePaceLabel, '配速'),
                ],
              ),
              const SizedBox(height: 10),
              Center(
                child: Text(
                    '${session.points.length} 个轨迹点　${session.splits.length} 段配速',
                    style: TextStyle(
                        fontSize: AppType.tiny, color: _c(AppPalette.slate11))),
              ),
              const SizedBox(height: 16),
              _FieldButton(
                  label: '生成记录图', icon: Icons.share, onTap: onCard, filled: true),
            ],
          ),
        ),
      );

  Widget _sheetMetric(IconData icon, String value, String label) => Column(
        children: [
          Icon(icon, size: 16, color: _c(AppPalette.slate11)),
          const SizedBox(height: 4),
          Text(value,
              style: TextStyle(
                  fontSize: AppType.tiny,
                  fontWeight: FontWeight.w700,
                  color: _c(AppPalette.slate12),
                  fontFeatures: const [FontFeature.tabularFigures()])),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(
                  fontSize: AppType.tiny, color: _c(AppPalette.slate11))),
        ],
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
        backgroundColor: _c(AppPalette.orange1),
        appBar: AppBar(
          backgroundColor: _c(AppPalette.orange1),
          title: Text('运动记录图',
              style: TextStyle(
                  fontSize: AppType.body, fontWeight: FontWeight.w600)),
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
                Text(_message!,
                    style: TextStyle(
                        fontSize: AppType.tiny, color: _c(AppPalette.slate11))),
              ],
              const SizedBox(height: 18),
              _FieldButton(
                label: _saving ? '正在生成图片' : '保存图片到手机',
                icon: Icons.download,
                onTap: _saving ? () {} : _save,
                filled: true,
              ),
            ],
          ),
        ),
      );
}
