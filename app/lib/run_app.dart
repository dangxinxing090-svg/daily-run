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
import 'widgets/track_path.dart';

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

/* ---------------- 玻璃拟态基础 ---------------- */

Widget _glassBackdrop({required Widget child}) => Stack(
      children: [
        Positioned.fill(child: Container(color: _c(AppPalette.orange1))),
        Positioned(
          left: -120,
          top: -170,
          child: _Aura(
            size: 400,
            color: AppPalette.orange9,
            alpha: AppRules.auraAlpha,
          ),
        ),
        Positioned(
          right: -140,
          bottom: 30,
          child: _Aura(
            size: 360,
            color: AppPalette.teal9,
            alpha: AppRules.auraAlpha * 0.6,
          ),
        ),
        Positioned(
          left: -70,
          bottom: -130,
          child: _Aura(
            size: 300,
            color: AppPalette.orange5,
            alpha: AppRules.auraAlpha * 1.2,
          ),
        ),
        child,
      ],
    );

class _Aura extends StatelessWidget {
  final double size;
  final int color;
  final double alpha;
  const _Aura({required this.size, required this.color, required this.alpha});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              _c(color).withValues(alpha: alpha),
              _c(color).withValues(alpha: 0),
            ],
          ),
        ),
      );
}

class _GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double alpha;
  const _GlassCard({
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.alpha = AppRules.glassAlpha,
  });

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(AppRules.glassRadius),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(
            sigmaX: AppRules.glassBlur,
            sigmaY: AppRules.glassBlur,
          ),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: _c(AppPalette.slate1).withValues(alpha: alpha),
              borderRadius: BorderRadius.circular(AppRules.glassRadius),
              border: Border.all(
                width: AppRules.hairline,
                color: Colors.white.withValues(alpha: AppRules.glassEdgeAlpha),
              ),
            ),
            child: child,
          ),
        ),
      );
}

class _TabBar extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onChanged;
  const _TabBar({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) => Container(
        height: 78,
        decoration: BoxDecoration(
          color: _c(AppPalette.slate1).withValues(alpha: 0.82),
          border: Border(
            top: BorderSide(
                width: AppRules.hairline, color: _c(AppPalette.slate6)),
          ),
        ),
        child: ClipRRect(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Row(
              children: [
                _tabItem(0, Icons.today, '今日'),
                _tabItem(1, Icons.route, '跑中'),
                _tabItem(2, Icons.history, '记录'),
              ],
            ),
          ),
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
            Icon(icon,
                size: 24,
                color: on ? _c(AppPalette.orange11) : _c(AppPalette.slate11)),
            const SizedBox(height: 6),
            Text(label,
                style: TextStyle(
                  fontSize: AppType.tiny,
                  fontWeight:
                      on ? FontWeight.w600 : FontWeight.w400,
                  color: on
                      ? _c(AppPalette.orange11)
                      : _c(AppPalette.slate11),
                )),
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
  Widget build(BuildContext context) => _glassBackdrop(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 30, 24, 30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${today.month}月${today.day}日',
                          style: TextStyle(
                              fontSize: AppType.body,
                              color: _c(AppPalette.slate11))),
                      Text('${_weekCn[today.weekday - 1]}曜日',
                          style: TextStyle(
                              fontSize: AppType.body,
                              fontWeight: FontWeight.w600,
                              color: _c(AppPalette.slate12))),
                    ],
                  ),
                  const Spacer(),
                  _Chip(
                      label: '连续 $streak 天',
                      color: AppPalette.orange9,
                      filled: false),
                ],
              ),
              const SizedBox(height: 34),
              Text('今日',
                  style: TextStyle(
                      fontSize: AppType.display,
                      fontWeight: FontWeight.w700,
                      color: _c(AppPalette.slate12),
                      height: 1)),
              const SizedBox(height: 8),
              Text('跑起来，就现在',
                  style: TextStyle(
                      fontSize: AppType.title,
                      fontWeight: FontWeight.w500,
                      color: _c(AppPalette.orange11))),
              const SizedBox(height: 36),
              Center(child: _RunOrb(onTap: onRun)),
              const SizedBox(height: 14),
              Center(
                child: Text('目标 ${targetKm.toStringAsFixed(2)} km',
                    style: TextStyle(
                        fontSize: AppType.body,
                        color: _c(AppPalette.slate11))),
              ),
              const SizedBox(height: 40),
              _GlassCard(
                padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _Stat(
                        label: '连续天数',
                        value: '$streak',
                        unit: '天',
                        large: true),
                    _Divider(),
                    _Stat(
                        label: '本月里程',
                        value: monthKm.toStringAsFixed(1),
                        unit: 'km',
                        large: true),
                    _Divider(),
                    _Stat(
                        label: '打卡',
                        value: '$monthCount',
                        unit: '次',
                        large: true),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

class _RunOrb extends StatelessWidget {
  final VoidCallback onTap;
  const _RunOrb({required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 248,
              height: 248,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _c(AppPalette.orange9).withValues(alpha: 0.10),
              ),
            ),
            Container(
              width: 208,
              height: 208,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _c(AppPalette.orange9).withValues(alpha: 0.18),
              ),
            ),
            Container(
              width: 168,
              height: 168,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [_c(AppPalette.orange5), _c(AppPalette.orange9)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: _c(AppPalette.orange9).withValues(alpha: 0.35),
                    blurRadius: 36,
                    offset: const Offset(0, 14),
                  ),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.play_arrow, size: 46, color: Colors.white),
                  const SizedBox(height: 6),
                  Text('开跑',
                      style: TextStyle(
                          fontSize: AppType.title,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                ],
              ),
            ),
          ],
        ),
      );
}

/* ---------------- 跑中（实时 / 结果双态） ---------------- */

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

  Widget _backdrop({required Widget child}) =>
      _glassBackdrop(child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 30, 24, 30),
        child: child,
      ));

  Widget _idle(BuildContext context) => _backdrop(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _pageTitle('跑中', '准备好就开始'),
            const SizedBox(height: 90),
            Center(child: _RunOrb(onTap: onStart)),
            const SizedBox(height: 18),
            Center(
              child: Text('一键开始记录轨迹',
                  style: TextStyle(
                      fontSize: AppType.body, color: _c(AppPalette.slate11))),
            ),
          ],
        ),
      );

  Widget _live(BuildContext context) => _backdrop(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('跑中',
                    style: TextStyle(
                        fontSize: AppType.display,
                        fontWeight: FontWeight.w700,
                        color: _c(AppPalette.slate12),
                        height: 1)),
                _Chip(
                  label: paused ? '已暂停' : '记录中',
                  color: paused ? AppPalette.slate11 : AppPalette.teal9,
                  filled: paused,
                ),
              ],
            ),
            const SizedBox(height: 24),
            _GlassCard(
              padding: const EdgeInsets.all(10),
              child: _TrackMap(points: points, height: 190),
            ),
            const SizedBox(height: 28),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(_clock(elapsed),
                    style: TextStyle(
                        fontSize: AppType.display,
                        fontWeight: FontWeight.w700,
                        color: _c(AppPalette.orange11),
                        letterSpacing: -3,
                        height: 1)),
                const SizedBox(width: 10),
                Text('已用时间',
                    style: TextStyle(
                        fontSize: AppType.body,
                        color: _c(AppPalette.slate11))),
              ],
            ),
            const SizedBox(height: 22),
            _GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _Stat(
                      label: '距离',
                      value: distance.toStringAsFixed(2),
                      unit: 'km'),
                  _Divider(),
                  _Stat(label: '配速', value: pace, unit: ''),
                  if (heartRate != null) ...[
                    _Divider(),
                    _Stat(label: '心率', value: '$heartRate', unit: ''),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 28),
            Row(
              children: [
                Expanded(
                  child: _BigButton(
                    label: paused ? '继续' : '暂停',
                    icon: paused ? Icons.play_arrow : Icons.pause,
                    onTap: onPause,
                    filled: false,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _BigButton(
                    label: '结束',
                    icon: Icons.flag,
                    onTap: () => onFinish(),
                    filled: true,
                  ),
                ),
              ],
            ),
          ],
        ),
      );

  Widget _result(BuildContext context, WorkoutSession s) => _backdrop(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('完成',
                    style: TextStyle(
                        fontSize: AppType.display,
                        fontWeight: FontWeight.w700,
                        color: _c(AppPalette.slate12),
                        height: 1)),
                _Chip(
                  label: autoCheckedIn ? '已打卡' : '已记录',
                  color: autoCheckedIn ? AppPalette.teal9 : AppPalette.slate11,
                  filled: autoCheckedIn,
                ),
              ],
            ),
            const SizedBox(height: 24),
            _GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text((s.distanceMeters / 1000).toStringAsFixed(2),
                          style: TextStyle(
                              fontSize: AppType.display,
                              fontWeight: FontWeight.w700,
                              color: _c(AppPalette.orange11),
                              letterSpacing: -3,
                              height: 1)),
                      const SizedBox(width: 8),
                      Text('km',
                          style: TextStyle(
                              fontSize: AppType.title,
                              color: _c(AppPalette.orange11))),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _Stat(label: '用时', value: _clock(s.elapsed), unit: ''),
                      _Divider(),
                      _Stat(label: '配速', value: s.averagePaceLabel, unit: ''),
                      _Divider(),
                      _Stat(label: '消耗', value: '${s.calories}', unit: 'kcal'),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _GlassCard(
              padding: const EdgeInsets.all(10),
              child: _TrackMap(points: s.points, height: 180),
            ),
            const SizedBox(height: 28),
            _BigButton(
              label: '查看完成数据',
              icon: Icons.analytics_outlined,
              onTap: onResult,
              filled: true,
            ),
            const SizedBox(height: 12),
            _BigButton(
              label: '再跑一次',
              icon: Icons.replay,
              onTap: onStart,
              filled: false,
            ),
          ],
        ),
      );

  Widget _pageTitle(String title, String sub) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: AppType.display,
                  fontWeight: FontWeight.w700,
                  color: _c(AppPalette.slate12),
                  height: 1)),
          const SizedBox(height: 8),
          Text(sub,
              style: TextStyle(
                  fontSize: AppType.title,
                  color: _c(AppPalette.orange11))),
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
    return _glassBackdrop(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 26, 20, 26),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('记录',
                style: TextStyle(
                    fontSize: AppType.title,
                    fontWeight: FontWeight.w700,
                    color: _c(AppPalette.slate12))),
            const SizedBox(height: 18),
            _GlassCard(
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _Stat(
                      label: '本月里程',
                      value: monthKm.toStringAsFixed(1),
                      unit: 'km'),
                  _Divider(),
                  _Stat(label: '打卡', value: '$monthCount', unit: '次'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _GlassCard(
              padding: const EdgeInsets.all(14),
              child: _MonthGrid(repo: repo, today: today),
            ),
            const SizedBox(height: 20),
            Text('历史记录',
                style: TextStyle(
                    fontSize: AppType.small,
                    fontWeight: FontWeight.w600,
                    color: _c(AppPalette.slate12))),
            const SizedBox(height: 10),
            if (sessions.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 30),
                child: Center(
                  child: Text('还没有跑步记录',
                      style: TextStyle(
                          fontSize: AppType.small,
                          color: _c(AppPalette.slate11))),
                ),
              ),
            ...sessions.map((s) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _GlassCard(
                    padding:
                        const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                    alpha: 0.45,
                    child: GestureDetector(
                      onTap: () => onSession(s),
                      behavior: HitTestBehavior.opaque,
                      child: Row(
                        children: [
                          Icon(Icons.route,
                              size: 18, color: _c(AppPalette.orange11)),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_dateCn(s.startTime),
                                    style: TextStyle(
                                        fontSize: AppType.small,
                                        fontWeight: FontWeight.w600,
                                        color: _c(AppPalette.slate12))),
                                const SizedBox(height: 4),
                                Text(
                                    '${_clock(s.elapsed)}　${s.averagePaceLabel}　${s.points.length} 轨迹点',
                                    style: TextStyle(
                                        fontSize: AppType.tiny,
                                        color: _c(AppPalette.slate11))),
                              ],
                            ),
                          ),
                          Text('${(s.distanceMeters / 1000).toStringAsFixed(2)} km',
                              style: TextStyle(
                                  fontSize: AppType.small,
                                  fontWeight: FontWeight.w600,
                                  color: _c(AppPalette.orange11))),
                        ],
                      ),
                    ),
                  ),
                )),
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
      final date = DateTime(today.year, today.month, day);
      final done = repo.hasCheckIn(date);
      final isToday = day == today.day;
      cells.add(Container(
        height: 24,
        decoration: BoxDecoration(
          color: done
              ? _c(AppPalette.teal9)
              : isToday
                  ? _c(AppPalette.orange5)
                  : _c(AppPalette.orange2),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            width: AppRules.hairline,
            color: isToday ? _c(AppPalette.orange11) : _c(AppPalette.slate6),
          ),
        ),
        child: Center(
          child: Text('$day',
              style: TextStyle(
                  fontSize: AppType.tiny,
                  color:
                      done ? _c(AppPalette.slate1) : _c(AppPalette.slate11))),
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
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: 7,
          mainAxisSpacing: 5,
          crossAxisSpacing: 5,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: cells,
        ),
      ],
    );
  }
}

/* ---------------- 结果 / 详情弹层 ---------------- */

class _Sheet extends StatelessWidget {
  final Widget child;
  const _Sheet({required this.child});

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(AppRules.glassRadius)),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(
              sigmaX: AppRules.glassBlur, sigmaY: AppRules.glassBlur),
          child: Container(
            decoration: BoxDecoration(
              color: _c(AppPalette.slate1).withValues(alpha: 0.94),
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(AppRules.glassRadius)),
              border: Border.all(
                width: AppRules.hairline,
                color: Colors.white.withValues(alpha: AppRules.glassEdgeAlpha),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 32),
            child: child,
          ),
        ),
      );
}

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
  Widget build(BuildContext context) => _Sheet(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: _c(AppPalette.slate6),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('完成数据',
                      style: TextStyle(
                          fontSize: AppType.title,
                          fontWeight: FontWeight.w700,
                          color: _c(AppPalette.slate12))),
                  _Chip(
                      label: autoCheckedIn ? '连续 $streak 天' : '未达标',
                      color: autoCheckedIn ? AppPalette.teal9 : AppPalette.orange11,
                      filled: autoCheckedIn),
                ],
              ),
              const SizedBox(height: 16),
              _GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text((session.distanceMeters / 1000).toStringAsFixed(2),
                            style: TextStyle(
                                fontSize: AppType.display,
                                fontWeight: FontWeight.w700,
                                color: _c(AppPalette.orange11),
                                height: 1)),
                        const SizedBox(width: 8),
                        Text('km',
                            style: TextStyle(
                                fontSize: AppType.title,
                                color: _c(AppPalette.orange11))),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _Stat(label: '用时', value: _clock(session.elapsed), unit: ''),
                        _Divider(),
                        _Stat(label: '配速', value: session.averagePaceLabel, unit: ''),
                        _Divider(),
                        _Stat(label: '消耗', value: '${session.calories}', unit: 'kcal'),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              _GlassCard(
                padding: const EdgeInsets.all(10),
                child: _TrackMap(points: session.points, height: 170),
              ),
              const SizedBox(height: 14),
              _GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('分段配速',
                        style: TextStyle(
                            fontSize: AppType.small,
                            fontWeight: FontWeight.w600,
                            color: _c(AppPalette.slate12))),
                    const SizedBox(height: 10),
                    ...session.splits.take(5).map((sp) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Text('第 ${sp.kmIndex} 公里',
                                  style: TextStyle(
                                      fontSize: AppType.tiny,
                                      color: _c(AppPalette.slate11))),
                              const Spacer(),
                              Text(sp.paceLabel,
                                  style: TextStyle(
                                      fontSize: AppType.tiny,
                                      fontWeight: FontWeight.w600,
                                      color: _c(AppPalette.slate12))),
                            ],
                          ),
                        )),
                    if (session.splits.isEmpty)
                      Text('本次距离不足一公里',
                          style: TextStyle(
                              fontSize: AppType.tiny,
                              color: _c(AppPalette.slate11))),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _BigButton(
                  label: '保存记录图', icon: Icons.download, onTap: onSave, filled: true),
              if (!autoCheckedIn && onManualCheckIn != null) ...[
                const SizedBox(height: 10),
                _BigButton(
                    label: '手动补卡',
                    icon: Icons.check_circle_outline,
                    onTap: () => onManualCheckIn!(),
                    filled: false),
              ],
            ],
          ),
        ),
      );
}

class _SessionSheet extends StatelessWidget {
  final WorkoutSession session;
  final VoidCallback onCard;
  const _SessionSheet({required this.session, required this.onCard});

  @override
  Widget build(BuildContext context) => _Sheet(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: _c(AppPalette.slate6),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(_dateCn(session.startTime),
                  style: TextStyle(
                      fontSize: AppType.title,
                      fontWeight: FontWeight.w700,
                      color: _c(AppPalette.slate12))),
              const SizedBox(height: 14),
              _GlassCard(
                padding: const EdgeInsets.all(10),
                child: _TrackMap(points: session.points, height: 190),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _Stat(
                      label: '距离',
                      value: (session.distanceMeters / 1000).toStringAsFixed(2),
                      unit: 'km'),
                  _Divider(),
                  _Stat(label: '用时', value: _clock(session.elapsed), unit: ''),
                  _Divider(),
                  _Stat(label: '配速', value: session.averagePaceLabel, unit: ''),
                ],
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                    '轨迹点 ${session.points.length} 个　分段 ${session.splits.length} 段',
                    style: TextStyle(
                        fontSize: AppType.tiny, color: _c(AppPalette.slate11))),
              ),
              const SizedBox(height: 18),
              _BigButton(
                  label: '生成记录图', icon: Icons.share, onTap: onCard, filled: true),
            ],
          ),
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
              _BigButton(
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

/* ---------------- 共享组件 ---------------- */

class _Chip extends StatelessWidget {
  final String label;
  final int color;
  final bool filled;
  const _Chip(
      {required this.label, required this.color, required this.filled});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: filled
              ? _c(color)
              : _c(color).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
              width: AppRules.hairline,
              color: filled
                  ? _c(color)
                  : _c(color).withValues(alpha: 0.4)),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: AppType.tiny,
                fontWeight: FontWeight.w600,
                color: filled ? Colors.white : _c(color))),
      );
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final bool large;
  const _Stat({
    required this.label,
    required this.value,
    required this.unit,
    this.large = false,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: AppType.tiny, color: _c(AppPalette.slate11))),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value,
                  style: TextStyle(
                      fontSize: large ? AppType.hero : AppType.title,
                      fontWeight: FontWeight.w700,
                      color: _c(AppPalette.orange11),
                      height: 1)),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(unit,
                    style: TextStyle(
                        fontSize: AppType.tiny,
                        color: _c(AppPalette.slate11))),
              ],
            ],
          ),
        ],
      );
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => Container(
        width: AppRules.hairline,
        height: 42,
        color: _c(AppPalette.slate6),
      );
}

class _BigButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool filled;
  const _BigButton({
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
          height: 60,
          decoration: BoxDecoration(
            color: filled
                ? _c(AppPalette.orange9)
                : _c(AppPalette.slate1).withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              width: AppRules.hairline,
              color: filled
                  ? _c(AppPalette.orange9)
                  : _c(AppPalette.slate6),
            ),
            boxShadow: filled
                ? [
                    BoxShadow(
                      color: _c(AppPalette.orange9).withValues(alpha: 0.28),
                      blurRadius: 22,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 22,
                  color: filled ? Colors.white : _c(AppPalette.orange11)),
              const SizedBox(width: 10),
              Text(label,
                  style: TextStyle(
                      fontSize: AppType.body,
                      fontWeight: FontWeight.w700,
                      color: filled ? Colors.white : _c(AppPalette.orange11))),
            ],
          ),
        ),
      );
}

class _TrackMap extends StatelessWidget {
  final List<TrackPoint> points;
  final double height;
  const _TrackMap({required this.points, this.height = 190});

  @override
  Widget build(BuildContext context) => Container(
        height: height,
        decoration: BoxDecoration(
          color: _c(AppPalette.orange2).withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: CustomPaint(painter: _TrackPainter(points)),
              ),
            ),
            Positioned(
              left: 14,
              top: 12,
              child: Row(
                children: [
                  Icon(Icons.route,
                      size: 16, color: _c(AppPalette.slate11)),
                  const SizedBox(width: 6),
                  Text('本次轨迹',
                      style: TextStyle(
                          fontSize: AppType.tiny,
                          color: _c(AppPalette.slate11))),
                ],
              ),
            ),
          ],
        ),
      );
}

class _TrackPainter extends CustomPainter {
  final List<TrackPoint> points;
  _TrackPainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = _c(AppPalette.slate6).withValues(alpha: 0.6)
      ..strokeWidth = AppRules.hairline;
    for (int i = 1; i < 5; i++) {
      final y = size.height * i / 5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    for (int i = 1; i < 4; i++) {
      final x = size.width * i / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    final proj = projectTrack(points, size);
    if (!proj.isValid) return;
    final path = Path()..moveTo(proj.points.first.dx, proj.points.first.dy);
    for (final p in proj.points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = _c(AppPalette.orange9)
        ..strokeWidth = 8
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    final end = proj.end!;
    canvas.drawCircle(end, 9, Paint()..color = _c(AppPalette.orange9));
    canvas.drawCircle(end, 5, Paint()..color = _c(AppPalette.slate1));
  }

  @override
  bool shouldRepaint(covariant _TrackPainter oldDelegate) => true;
}
