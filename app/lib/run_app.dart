import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'domain/checkin.dart';
import 'domain/models.dart';
import 'domain/plan_service.dart';
import 'domain/repository.dart';
import 'domain/tracking.dart';
import 'platform/location_source.dart';
import 'platform/method_channel_bridge.dart';
import 'theme.dart';

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

String _hhmm(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

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
  final InMemoryRepository _repo = InMemoryRepository();
  final CheckInService _checkIn = CheckInService();
  final PlanService _planService = PlanService(MethodChannelPlanBridge());
  final LocationSource _location = createLocationSource();
  StreamSubscription<TrackFix>? _fixSub;
  late Plan _plan;
  TrackingManager? _tracker;
  Timer? _timer;
  Duration _elapsed = Duration.zero;
  double _pace = 0;
  int _tick = 0;
  DateTime _simulated = DateTime(2026, 11, 6, 19, 30);
  WorkoutSession? _finished;
  CheckIn? _todayCheckIn;
  bool _paused = false;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _plan = Plan(
      id: 'p-today',
      date: DateTime(2026, 11, 6),
      startMinutes: 19 * 60 + 30,
      type: '轻松跑',
      targetMeters: 5000,
      reminderOffsetMinutes: 15,
    );
    _repo.savePlan(_plan);
    for (int i = 1; i <= 5; i++) {
      _repo.saveCheckIn(_checkIn.manual(DateTime(2026, 11, i)));
    }
    _repo.saveSession(WorkoutSession(
      id: 's-1103',
      startTime: DateTime(2026, 11, 3, 19, 30),
      elapsed: const Duration(minutes: 37, seconds: 12),
      distanceMeters: 6300,
      calories: 410,
    ));
    _repo.saveSession(WorkoutSession(
      id: 's-1031',
      startTime: DateTime(2026, 10, 31, 19, 30),
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

  int get _streak => _checkIn.streak(_repo.checkIns, DateTime(2026, 11, 6));
  double get _monthKm => _checkIn.monthDistance(_repo.sessions, 2026, 11) / 1000;
  int get _monthCount => _checkIn.monthCheckInCount(_repo.checkIns, 2026, 11);

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
    );
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
    _tracker = TrackingManager(sessionId: 's-today', planId: _plan.id);
    _tracker!.start(_trackerNow);
    _finished = null;
    _todayCheckIn = null;
    _paused = false;
    if (_location.isSimulated) _addSimulatedPoint();
    _attachStreams();
    setState(() {
      _elapsed = Duration.zero;
      _pace = 0;
      _tab = 2;
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

  void _finish() {
    _timer?.cancel();
    _fixSub?.cancel();
    _location.stop();
    if (_tracker == null || _tracker!.status == SessionStatus.finished) return;
    if (_paused) {
      _tracker!.resume(_trackerNow);
      _paused = false;
    }
    // 只有预览模式才补齐演示距离，真机完全按 GPS 实际轨迹结算
    if (_location.isSimulated) {
      while (_tracker!.distanceMeters < 5210) {
        _addSimulatedPoint();
      }
      _simulated = _simulated.add(const Duration(seconds: 24));
    }
    final end = _trackerNow;
    final session = _tracker!.finish(end);
    _repo.saveSession(session);
    if (_checkIn.shouldAutoCheckIn(session, _plan)) {
      _todayCheckIn = _checkIn.auto(session, end);
      _repo.saveCheckIn(_todayCheckIn!);
    }
    setState(() {
      _finished = session;
      _elapsed = session.elapsed;
      _pace = session.averagePaceSecPerKm;
      _tab = 3;
    });
  }

  void _manualCheckIn() {
    if (_finished == null) return;
    final ci = _checkIn.manual(_trackerNow);
    _repo.saveCheckIn(ci);
    _todayCheckIn = ci;
    setState(() {});
  }

  void _savePlan(Plan next, BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
    _planService.save(next).then((saved) {
      if (!mounted) return;
      setState(() {
        _plan = saved;
        _repo.savePlan(saved);
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text('${saved.startLabel} ${saved.type}　提醒 ${_remindLabel(saved)}',
              style: const TextStyle(fontSize: 14)),
          backgroundColor: _c(AppPalette.orange11),
          behavior: SnackBarBehavior.floating,
        ),
      );
    });
  }

  String _remindLabel(Plan p) {
    final r = p.remindAt;
    return '${r.hour.toString().padLeft(2, '0')}:${r.minute.toString().padLeft(2, '0')}';
  }

  void _showCard(BuildContext context) {
    final s = _finished;
    if (s == null) return;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _c(AppPalette.orange1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('运动记录图',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${(s.distanceMeters / 1000).toStringAsFixed(2)} km',
                style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                    color: _c(AppPalette.orange11))),
            const SizedBox(height: 8),
            Text('${_clock(s.elapsed)}　${_paceLabel(s.averagePaceSecPerKm)}　${s.calories} kcal',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            const SizedBox(height: 12),
            Text('分段 ${s.splits.length} 段　轨迹点 ${s.points.length} 个',
                style: TextStyle(fontSize: 12, color: _c(AppPalette.slate11))),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭', style: TextStyle(fontSize: 14))),
        ],
      ),
    );
  }

  void _showSession(BuildContext context, WorkoutSession s) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _c(AppPalette.orange1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(_dateCn(s.startTime),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${(s.distanceMeters / 1000).toStringAsFixed(2)} km',
                style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                    color: _c(AppPalette.orange11))),
            const SizedBox(height: 8),
            Text('${_clock(s.elapsed)}　${s.averagePaceLabel}　${s.calories} kcal',
                style: const TextStyle(fontSize: 14)),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭', style: TextStyle(fontSize: 14))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      _TodayPage(
        plan: _plan,
        event: _planService.eventFor(_plan),
        repo: _repo,
        streak: _streak,
        monthKm: _monthKm,
        monthCount: _monthCount,
        remindLabel: _remindLabel(_plan),
        onRun: _start,
      ),
      _PlanPage(plan: _plan, onSave: (p) => _savePlan(p, context)),
      _RunningPage(
        points: _tracker?.points ?? const <TrackPoint>[],
        elapsed: _elapsed,
        distance: (_tracker?.distanceMeters ?? 0) / 1000,
        pace: _paceLabel(_pace),
        running: _tracker != null && _finished == null,
        paused: _paused,
        done: _finished != null,
        onStart: _start,
        onPause: _togglePause,
        onFinish: _finish,
      ),
      _FinishPage(
        session: _finished,
        streak: _streak,
        autoCheckedIn: _todayCheckIn != null,
        onCard: () => _showCard(context),
        onRun: _start,
        onManualCheckIn: _manualCheckIn,
      ),
      _HistoryPage(
        repo: _repo,
        monthKm: _monthKm,
        monthCount: _monthCount,
        onSession: (s) => _showSession(context, s),
      ),
    ];

    return Scaffold(
      body: SafeArea(child: pages[_tab]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        backgroundColor: _c(AppPalette.slate1),
        indicatorColor: _c(AppPalette.orange3),
        height: 68,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.calendar_today, size: 20), label: '今日'),
          NavigationDestination(
              icon: Icon(Icons.edit_calendar, size: 20), label: '计划'),
          NavigationDestination(
              icon: Icon(Icons.route, size: 20), label: '跑中'),
          NavigationDestination(
              icon: Icon(Icons.check_circle_outline, size: 20), label: '完成'),
          NavigationDestination(icon: Icon(Icons.list, size: 20), label: '记录'),
        ],
      ),
    );
  }
}

/* ---------------- 今日 ---------------- */

class _TodayPage extends StatelessWidget {
  final Plan plan;
  final CalendarEventSpec event;
  final InMemoryRepository repo;
  final int streak;
  final double monthKm;
  final int monthCount;
  final String remindLabel;
  final VoidCallback onRun;

  const _TodayPage({
    required this.plan,
    required this.event,
    required this.repo,
    required this.streak,
    required this.monthKm,
    required this.monthCount,
    required this.remindLabel,
    required this.onRun,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(streak: streak, monthKm: monthKm),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.edit_calendar, size: 16, color: _c(AppPalette.orange11)),
                          const SizedBox(width: 8),
                          Text('今日计划',
                              style: TextStyle(fontSize: AppType.body, fontWeight: FontWeight.w600, color: _c(AppPalette.slate12))),
                          const Spacer(),
                          Icon(Icons.notifications_none, size: 16, color: _c(AppPalette.slate11)),
                          const SizedBox(width: 5),
                          Text('$remindLabel 提醒',
                              style: TextStyle(fontSize: AppType.xsmall, color: _c(AppPalette.slate11))),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text('${plan.startLabel}　${plan.type}　目标 ${(plan.targetMeters / 1000).toStringAsFixed(2)} km',
                          style: TextStyle(fontSize: AppType.body, fontWeight: FontWeight.w500, color: _c(AppPalette.slate12))),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(Icons.event, size: 14, color: _c(AppPalette.slate11)),
                          const SizedBox(width: 6),
                          Text('日历事项 ${_hhmm(event.start)} 至 ${_hhmm(event.end)}',
                              style: TextStyle(fontSize: AppType.xsmall, color: _c(AppPalette.slate11))),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('十一月',
                          style: TextStyle(fontSize: AppType.body, fontWeight: FontWeight.w600, color: _c(AppPalette.slate12))),
                      const SizedBox(height: 12),
                      _MonthGrid(repo: repo),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          _legend(_c(AppPalette.teal9), '已打卡'),
                          const SizedBox(width: 14),
                          _legend(_c(AppPalette.orange9), '今天'),
                          const SizedBox(width: 14),
                          _legend(_c(AppPalette.orange3), '待跑'),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(child: _stat('连续', '$streak 天')),
                    Expanded(child: _stat('本月里程', '${monthKm.toStringAsFixed(1)} km')),
                    Expanded(child: _stat('打卡', '$monthCount 次')),
                  ],
                ),
                const SizedBox(height: 18),
                _Pill(label: '开始今天这一跑', icon: Icons.play_arrow, onTap: onRun, filled: true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _legend(Color color, String label) => Row(
        children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(fontSize: AppType.xsmall, color: _c(AppPalette.slate11))),
        ],
      );

  Widget _stat(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: AppType.xsmall, color: _c(AppPalette.slate11))),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: AppType.body, fontWeight: FontWeight.w600, color: _c(AppPalette.slate12))),
        ],
      );
}

class _MonthGrid extends StatelessWidget {
  final InMemoryRepository repo;
  const _MonthGrid({required this.repo});

  @override
  Widget build(BuildContext context) {
    final leading = DateTime(2026, 11, 1).weekday - 1;
    final cells = <Widget>[];
    for (int i = 0; i < leading; i++) {
      cells.add(const SizedBox(height: 26));
    }
    for (int day = 1; day <= 30; day++) {
      final done = repo.hasCheckIn(DateTime(2026, 11, day));
      final today = day == 6;
      cells.add(Container(
        height: 26,
        decoration: BoxDecoration(
          color: done ? _c(AppPalette.teal9) : _c(AppPalette.orange2),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            width: AppRules.hairline,
            color: today ? _c(AppPalette.orange11) : _c(AppPalette.slate6),
          ),
        ),
        child: Center(
          child: Text('$day',
              style: TextStyle(
                  fontSize: AppType.xsmall,
                  color: done ? _c(AppPalette.slate1) : _c(AppPalette.slate11))),
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
                    style: TextStyle(fontSize: AppType.xsmall, color: _c(AppPalette.slate11))),
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

/* ---------------- 计划 ---------------- */

class _PlanPage extends StatefulWidget {
  final Plan plan;
  final ValueChanged<Plan> onSave;
  const _PlanPage({required this.plan, required this.onSave});

  @override
  State<_PlanPage> createState() => _PlanPageState();
}

class _PlanPageState extends State<_PlanPage> {
  late int _minutes;
  late String _type;
  late double _km;
  late int _remind;

  @override
  void initState() {
    super.initState();
    _minutes = widget.plan.startMinutes;
    _type = widget.plan.type;
    _km = widget.plan.targetMeters / 1000;
    _remind = widget.plan.reminderOffsetMinutes;
  }

  String get _startLabel =>
      '${(_minutes ~/ 60).toString().padLeft(2, '0')}:${(_minutes % 60).toString().padLeft(2, '0')}';

  String get _remindLabel {
    final total = _minutes - _remind;
    return '${(total ~/ 60).toString().padLeft(2, '0')}:${(total % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Header(streak: 0, monthKm: 0, title: '规划运动'),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _rowLabel(Icons.calendar_today, '日期'),
                      const SizedBox(height: 8),
                      Text('11月6日 周五',
                          style: TextStyle(fontSize: AppType.body, fontWeight: FontWeight.w600, color: _c(AppPalette.slate12))),
                      const SizedBox(height: 16),
                      _rowLabel(Icons.schedule, '出发时间'),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _stepBtn(Icons.remove, () => setState(() => _minutes = math.max(0, _minutes - 15))),
                          const SizedBox(width: 16),
                          Text(_startLabel,
                              style: TextStyle(fontSize: AppType.headline, fontWeight: FontWeight.w600, color: _c(AppPalette.orange11))),
                          const SizedBox(width: 16),
                          _stepBtn(Icons.add, () => setState(() => _minutes = math.min(23 * 60 + 45, _minutes + 15))),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _rowLabel(Icons.route, '运动类型'),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        children: ['轻松跑', '间歇跑', '长距离'].map((t) {
                          final on = t == _type;
                          return ChoiceChip(
                            label: Text(t, style: TextStyle(fontSize: AppType.xsmall, color: on ? _c(AppPalette.slate1) : _c(AppPalette.slate12))),
                            selected: on,
                            selectedColor: _c(AppPalette.orange9),
                            backgroundColor: _c(AppPalette.orange2),
                            side: BorderSide(width: AppRules.hairline, color: _c(AppPalette.slate6)),
                            onSelected: (_) => setState(() => _type = t),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 18),
                      _rowLabel(Icons.straighten, '目标距离'),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Expanded(
                            child: Slider(
                              value: _km,
                              min: 3,
                              max: 12,
                              divisions: 18,
                              activeColor: _c(AppPalette.orange9),
                              onChanged: (v) => setState(() => _km = v),
                            ),
                          ),
                          Text('${_km.toStringAsFixed(1)} km',
                              style: TextStyle(fontSize: AppType.body, fontWeight: FontWeight.w600, color: _c(AppPalette.orange11))),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _card(
                  child: Row(
                    children: [
                      Icon(Icons.notifications_none, size: 16, color: _c(AppPalette.orange11)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('提前提醒',
                                style: TextStyle(fontSize: AppType.body, fontWeight: FontWeight.w600, color: _c(AppPalette.slate12))),
                            const SizedBox(height: 3),
                            Text('$_remindLabel 提醒，提前 $_remind 分钟',
                                style: TextStyle(fontSize: AppType.xsmall, color: _c(AppPalette.slate11))),
                          ],
                        ),
                      ),
                      Switch(
                        value: _remind > 0,
                        activeThumbColor: _c(AppPalette.slate1),
                        activeTrackColor: _c(AppPalette.orange9),
                        onChanged: (v) => setState(() => _remind = v ? 15 : 0),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                _Pill(
                  label: '保存计划',
                  icon: Icons.check_circle_outline,
                  filled: true,
                  onTap: () => widget.onSave(Plan(
                    id: widget.plan.id,
                    date: widget.plan.date,
                    startMinutes: _minutes,
                    type: _type,
                    targetMeters: _km * 1000,
                    reminderOffsetMinutes: _remind,
                  )),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _rowLabel(IconData icon, String text) => Row(
        children: [
          Icon(icon, size: 16, color: _c(AppPalette.slate11)),
          const SizedBox(width: 7),
          Text(text, style: TextStyle(fontSize: AppType.xsmall, color: _c(AppPalette.slate11))),
        ],
      );

  Widget _stepBtn(IconData icon, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: _c(AppPalette.orange3),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(width: AppRules.hairline, color: _c(AppPalette.slate6)),
          ),
          child: Icon(icon, size: 16, color: _c(AppPalette.orange11)),
        ),
      );
}

/* ---------------- 跑中 ---------------- */

class _RunningPage extends StatelessWidget {
  final List<TrackPoint> points;
  final Duration elapsed;
  final double distance;
  final String pace;
  final bool running;
  final bool paused;
  final bool done;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onFinish;

  const _RunningPage({
    required this.points,
    required this.elapsed,
    required this.distance,
    required this.pace,
    required this.running,
    required this.paused,
    required this.done,
    required this.onStart,
    required this.onPause,
    required this.onFinish,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Header(streak: 0, monthKm: 0, title: '运动中'),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TrackMap(points: points),
                const SizedBox(height: 18),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(_clock(elapsed),
                        style: TextStyle(
                            fontSize: AppType.giant,
                            fontWeight: FontWeight.w600,
                            color: _c(AppPalette.orange11),
                            letterSpacing: -4,
                            height: 1)),
                    const SizedBox(width: 10),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text('已用时间',
                          style: TextStyle(fontSize: AppType.xsmall, color: _c(AppPalette.slate11))),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    _Metric(icon: Icons.straighten, label: '距离', value: '${distance.toStringAsFixed(2)} km'),
                    _Metric(icon: Icons.speed, label: '配速', value: pace),
                    _Metric(icon: Icons.favorite, label: '心率', value: running ? '142' : '--'),
                  ],
                ),
                const SizedBox(height: 20),
                if (!running && !done)
                  _Pill(label: '开始跑步', icon: Icons.play_arrow, onTap: onStart, filled: true)
                else if (done)
                  _Pill(label: '查看完成结果', icon: Icons.check_circle_outline, onTap: onFinish, filled: false)
                else
                  Row(
                    children: [
                      Expanded(child: _Pill(label: paused ? '继续' : '暂停', icon: Icons.pause, onTap: onPause, filled: false)),
                      const SizedBox(width: 10),
                      Expanded(child: _Pill(label: '结束', icon: Icons.flag, onTap: onFinish, filled: true)),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/* ---------------- 完成 ---------------- */

class _FinishPage extends StatelessWidget {
  final WorkoutSession? session;
  final int streak;
  final bool autoCheckedIn;
  final VoidCallback onCard;
  final VoidCallback onRun;
  final VoidCallback onManualCheckIn;
  const _FinishPage({
    required this.session,
    required this.streak,
    required this.autoCheckedIn,
    required this.onCard,
    required this.onRun,
    required this.onManualCheckIn,
  });

  @override
  Widget build(BuildContext context) {
    final s = session;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Header(streak: 0, monthKm: 0, title: '完成'),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
            child: s == null
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 40),
                      Icon(Icons.flag_outlined, size: 40, color: _c(AppPalette.slate6)),
                      const SizedBox(height: 14),
                      Center(
                        child: Text('今天还没有完成记录',
                            style: TextStyle(fontSize: AppType.body, color: _c(AppPalette.slate11))),
                      ),
                      const SizedBox(height: 24),
                      _Pill(label: '去跑步', icon: Icons.play_arrow, onTap: onRun, filled: true),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _card(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(autoCheckedIn ? Icons.check_circle : Icons.info_outline,
                                    size: 16,
                                    color: _c(autoCheckedIn ? AppPalette.teal9 : AppPalette.orange11)),
                                const SizedBox(width: 8),
                                Text(autoCheckedIn ? '已自动打卡　连续 $streak 天' : '本次未达标　可手动补卡',
                                    style: TextStyle(fontSize: AppType.body, fontWeight: FontWeight.w600, color: _c(AppPalette.slate12))),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text('${(s.distanceMeters / 1000).toStringAsFixed(2)} km',
                                style: TextStyle(fontSize: AppType.headline, fontWeight: FontWeight.w600, color: _c(AppPalette.orange11))),
                            const SizedBox(height: 6),
                            Text('${_clock(s.elapsed)}　${s.averagePaceLabel}　${s.calories} kcal',
                                style: TextStyle(fontSize: AppType.body, fontWeight: FontWeight.w500, color: _c(AppPalette.slate12))),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      _SharePreview(session: s, autoCheckedIn: autoCheckedIn),
                      const SizedBox(height: 14),
                      _card(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('分段配速',
                                style: TextStyle(fontSize: AppType.body, fontWeight: FontWeight.w600, color: _c(AppPalette.slate12))),
                            const SizedBox(height: 10),
                            ...s.splits.take(6).map((sp) => Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 3),
                                  child: Row(
                                    children: [
                                      Text('第 ${sp.kmIndex} 公里',
                                          style: TextStyle(fontSize: AppType.xsmall, color: _c(AppPalette.slate11))),
                                      const Spacer(),
                                      Text(sp.paceLabel,
                                          style: TextStyle(fontSize: AppType.xsmall, fontWeight: FontWeight.w600, color: _c(AppPalette.slate12))),
                                    ],
                                  ),
                                )),
                            if (s.splits.isEmpty)
                              Text('本次距离不足一公里',
                                  style: TextStyle(fontSize: AppType.xsmall, color: _c(AppPalette.slate11))),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (!autoCheckedIn) ...[
                        _Pill(label: '手动补卡', icon: Icons.check_circle_outline, onTap: onManualCheckIn, filled: true),
                        const SizedBox(height: 10),
                      ],
                      _Pill(label: '查看记录图', icon: Icons.share, onTap: onCard, filled: false),
                    ],
                  ),
            ),
        ],
      ),
    );
  }
}

class _SharePreview extends StatelessWidget {
  final WorkoutSession session;
  final bool autoCheckedIn;
  const _SharePreview({required this.session, required this.autoCheckedIn});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 210,
        height: 280,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _c(AppPalette.orange1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(width: AppRules.hairline, color: _c(AppPalette.slate6)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.share, size: 12, color: _c(AppPalette.slate12)),
                const SizedBox(width: 5),
                Text('每日跑步', style: TextStyle(fontSize: AppType.xsmall, fontWeight: FontWeight.w600, color: _c(AppPalette.slate12))),
                const Spacer(),
                Text('11月6日', style: TextStyle(fontSize: AppType.xsmall, color: _c(AppPalette.slate11))),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: _c(AppPalette.orange2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: CustomPaint(
                    painter: _TrackPainter(session.points),
                    size: const Size(double.infinity, double.infinity),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text('${(session.distanceMeters / 1000).toStringAsFixed(2)} km',
                style: TextStyle(fontSize: AppType.body, fontWeight: FontWeight.w600, color: _c(AppPalette.orange11))),
            const SizedBox(height: 3),
            Text('${_clock(session.elapsed)}　${session.averagePaceLabel}',
                style: TextStyle(fontSize: AppType.xsmall, color: _c(AppPalette.slate11))),
            const SizedBox(height: 7),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(color: _c(AppPalette.teal9), borderRadius: BorderRadius.circular(999)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check, size: 11, color: _c(AppPalette.slate1)),
                  const SizedBox(width: 4),
                  Text(autoCheckedIn ? '自动打卡成功' : '已记录本次跑步', style: TextStyle(fontSize: AppType.xsmall, color: _c(AppPalette.slate1))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* ---------------- 记录 ---------------- */

class _HistoryPage extends StatelessWidget {
  final InMemoryRepository repo;
  final double monthKm;
  final int monthCount;
  final ValueChanged<WorkoutSession> onSession;
  const _HistoryPage({required this.repo, required this.monthKm, required this.monthCount, required this.onSession});

  @override
  Widget build(BuildContext context) {
    final sessions = List<WorkoutSession>.from(repo.sessions)
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Header(streak: 0, monthKm: 0, title: '记录'),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _card(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('本月里程', style: TextStyle(fontSize: AppType.xsmall, color: _c(AppPalette.slate11))),
                            const SizedBox(height: 6),
                            Text('${monthKm.toStringAsFixed(1)} km',
                                style: TextStyle(fontSize: AppType.headline, fontWeight: FontWeight.w600, color: _c(AppPalette.orange11))),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _card(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('打卡次数', style: TextStyle(fontSize: AppType.xsmall, color: _c(AppPalette.slate11))),
                            const SizedBox(height: 6),
                            Text('$monthCount 次',
                                style: TextStyle(fontSize: AppType.headline, fontWeight: FontWeight.w600, color: _c(AppPalette.orange11))),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _card(child: _MonthGrid(repo: repo)),
                const SizedBox(height: 14),
                Text('单次记录',
                    style: TextStyle(fontSize: AppType.body, fontWeight: FontWeight.w600, color: _c(AppPalette.slate12))),
                const SizedBox(height: 8),
                ...sessions.map((s) => GestureDetector(
                      onTap: () => onSession(s),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: _c(AppPalette.orange2),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(width: AppRules.hairline, color: _c(AppPalette.slate6)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.route, size: 16, color: _c(AppPalette.orange11)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(_dateCn(s.startTime),
                                      style: TextStyle(fontSize: AppType.body, fontWeight: FontWeight.w600, color: _c(AppPalette.slate12))),
                                  const SizedBox(height: 3),
                                  Text('${_clock(s.elapsed)}　${s.averagePaceLabel}',
                                      style: TextStyle(fontSize: AppType.xsmall, color: _c(AppPalette.slate11))),
                                ],
                              ),
                            ),
                            Text('${(s.distanceMeters / 1000).toStringAsFixed(2)} km',
                                style: TextStyle(fontSize: AppType.body, fontWeight: FontWeight.w600, color: _c(AppPalette.orange11))),
                          ],
                        ),
                      ),
                    )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/* ---------------- 共享组件 ---------------- */

class _Header extends StatelessWidget {
  final int streak;
  final double monthKm;
  final String? title;
  const _Header({required this.streak, required this.monthKm, this.title});

  @override
  Widget build(BuildContext context) {
    return ClipPath(
      clipper: _BandClipper(),
      child: Container(
        height: 166,
        color: _c(AppPalette.orange9),
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.calendar_today, size: 16, color: _c(AppPalette.slate1)),
                const SizedBox(width: 8),
                Text(title ?? '每日跑步',
                    style: TextStyle(fontSize: AppType.body, fontWeight: FontWeight.w600, color: _c(AppPalette.slate1))),
                const Spacer(),
                Text('11月6日 周五',
                    style: TextStyle(fontSize: AppType.xsmall, color: _c(AppPalette.slate1))),
              ],
            ),
            const SizedBox(height: 16),
            if (title == null)
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text('$streak',
                      style: TextStyle(fontSize: AppType.headline, fontWeight: FontWeight.w600, color: _c(AppPalette.slate1))),
                  const SizedBox(width: 6),
                  Text('连续天数',
                      style: TextStyle(fontSize: AppType.xsmall, color: _c(AppPalette.slate1))),
                  const SizedBox(width: 20),
                  Text('${monthKm.toStringAsFixed(1)} km',
                      style: TextStyle(fontSize: AppType.body, fontWeight: FontWeight.w600, color: _c(AppPalette.slate1))),
                  const SizedBox(width: 6),
                  Text('本月',
                      style: TextStyle(fontSize: AppType.xsmall, color: _c(AppPalette.slate1))),
                ],
              )
            else
              Text('计划，跑，打卡，连成一圈',
                  style: TextStyle(fontSize: AppType.xsmall, color: _c(AppPalette.slate1))),
          ],
        ),
      ),
    );
  }
}

class _BandClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final p = Path();
    p.moveTo(0, 0);
    p.lineTo(size.width, 0);
    p.lineTo(size.width, size.height * 0.72);
    p.lineTo(0, size.height);
    p.close();
    return p;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

Widget _card({required Widget child}) => Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _c(AppPalette.orange3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(width: AppRules.hairline, color: _c(AppPalette.slate6)),
      ),
      child: child,
    );

class _TrackMap extends StatelessWidget {
  final List<TrackPoint> points;
  const _TrackMap({required this.points});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 190,
      decoration: BoxDecoration(
        color: _c(AppPalette.orange2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(width: AppRules.hairline, color: _c(AppPalette.slate6)),
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
                Icon(Icons.route, size: 16, color: _c(AppPalette.slate11)),
                const SizedBox(width: 6),
                Text('本次轨迹',
                    style: TextStyle(fontSize: AppType.xsmall, color: _c(AppPalette.slate11))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackPainter extends CustomPainter {
  final List<TrackPoint> points;
  _TrackPainter(this.points);

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = _c(AppPalette.slate6)
      ..strokeWidth = AppRules.hairline;
    for (int i = 1; i < 5; i++) {
      final y = size.height * i / 5;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    for (int i = 1; i < 4; i++) {
      final x = size.width * i / 4;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    if (points.length < 2) return;
    double minLat = points.first.lat;
    double maxLat = points.first.lat;
    double minLng = points.first.lng;
    double maxLng = points.first.lng;
    for (final p in points) {
      minLat = math.min(minLat, p.lat);
      maxLat = math.max(maxLat, p.lat);
      minLng = math.min(minLng, p.lng);
      maxLng = math.max(maxLng, p.lng);
    }
    final dx = (maxLng - minLng).abs() < 1e-9 ? 1.0 : maxLng - minLng;
    final dy = (maxLat - minLat).abs() < 1e-9 ? 1.0 : maxLat - minLat;
    const pad = 18.0;
    Offset project(TrackPoint p) => Offset(
          pad + (p.lng - minLng) / dx * (size.width - pad * 2),
          size.height - pad - (p.lat - minLat) / dy * (size.height - pad * 2),
        );
    final first = project(points.first);
    final path = Path()..moveTo(first.dx, first.dy);
    for (final p in points.skip(1)) {
      final o = project(p);
      path.lineTo(o.dx, o.dy);
    }
    final track = Paint()
      ..color = _c(AppPalette.orange9)
      ..strokeWidth = 7
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, track);
    final end = project(points.last);
    canvas.drawCircle(end, 8, Paint()..color = _c(AppPalette.orange9));
    canvas.drawCircle(end, 4, Paint()..color = _c(AppPalette.slate1));
  }

  @override
  bool shouldRepaint(covariant _TrackPainter oldDelegate) => true;
}

class _Metric extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _Metric({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: _c(AppPalette.slate11)),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontSize: AppType.xsmall, color: _c(AppPalette.slate11))),
            ],
          ),
          const SizedBox(height: 5),
          Text(value,
              style: TextStyle(fontSize: AppType.body, fontWeight: FontWeight.w600, color: _c(AppPalette.slate12))),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool filled;
  const _Pill({required this.label, required this.icon, required this.onTap, required this.filled});

  @override
  Widget build(BuildContext context) {
    final bg = filled ? _c(AppPalette.orange9) : _c(AppPalette.slate1);
    final fg = filled ? _c(AppPalette.slate1) : _c(AppPalette.orange11);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(width: AppRules.hairline, color: filled ? bg : _c(AppPalette.slate6)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: fg),
            const SizedBox(width: 8),
            Text(label,
                style: TextStyle(fontSize: AppType.body, fontWeight: FontWeight.w600, color: fg)),
          ],
        ),
      ),
    );
  }
}
