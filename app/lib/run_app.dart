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
import 'ui/motion.dart';
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
      themeMode: ThemeMode.light,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        scaffoldBackgroundColor: _c(AppPalette.sand2),
        colorScheme: ColorScheme.light(primary: _c(AppPalette.orange11)),
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
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
  int _tabShift = 1;
  String? _deletingId;

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
    await SoundService.instance.init();
    await _migrateOnce();
    _plan = _repo.planFor(_today) ??
        Plan(
          id: 'p-${_today.year}${_today.month}${_today.day}',
          date: _today,
          startMinutes: 19 * 60 + 30,
          type: '轻松跑',
          targetMeters: 3000,
          reminderOffsetMinutes: 15,
        );
    if (_repo.planFor(_today) == null) await _repo.savePlan(_plan);
    if (!mounted) return;
    setState(() => _ready = true);
  }

  /// 旧版本会写入两条示例跑步和几天打卡，这里只清一次；
  /// 顺带把当时写死的 5 公里目标归一到 3 公里。存在真实跑步时整段跳过。
  Future<void> _migrateOnce() async {
    try {
      if (await _repo.readMeta('data_version') == '2') return;
      await _repo.purgeDemoData();
      final plan = _repo.planFor(_today);
      if (plan != null && (plan.targetMeters - 5000).abs() < 1) {
        await _repo.savePlan(plan.copyWith(targetMeters: 3000));
      }
      await _repo.writeMeta('data_version', '2');
    } catch (_) {
      // 迁移失败不影响启动，下次再试。
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 系统开启「减少动态效果」时，所有时长归零、循环动效停掉。
    AppMotion.reduce = MediaQuery.disableAnimationsOf(context);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _fixSub?.cancel();
    _location.stop();
    super.dispose();
  }

  int get _streak => _checkIn.streak(_repo.checkIns, _today);
  double get _todayKm =>
      _repo.sessions
          .where((s) => dateOnly(s.startTime) == _today)
          .fold<double>(0, (sum, s) => sum + s.distanceMeters) /
      1000;

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
    Haptics.medium();
    SoundService.instance.play(AppSound.start);
    setState(() {
      _elapsed = Duration.zero;
      _pace = 0;
      _tabShift = 1;
      _tab = 1;
    });
  }

  void _togglePause() {
    if (_tracker == null || _finished != null) return;
    Haptics.light();
    SoundService.instance.play(AppSound.tap, volume: 0.7);
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
    Haptics.heavy();
    SoundService.instance.play(AppSound.finish);
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

  Future<void> _deleteSession(BuildContext context, WorkoutSession s) async {
    final ok = await showAppDialog<bool>(
          context,
          (_) => const _ConfirmDialog(
            title: '删除这条记录',
            body: '这次跑步的轨迹和数据会一起删掉，不能恢复。',
            confirmLabel: '删除',
          ),
        ) ??
        false;
    if (!ok) return;
    Haptics.medium();
    SoundService.instance.play(AppSound.tap, volume: 0.8);
    setState(() => _deletingId = s.id);
    await Future<void>.delayed(AppMotion.base);
    await _repo.deleteSession(s.id);
    if (!mounted) return;
    setState(() {
      _deletingId = null;
      if (_finished?.id == s.id) {
        _finished = null;
        _tracker = null;
      }
    });
  }

  Future<void> _editTarget(BuildContext context) async {
    final km = await showAppDialog<double>(
      context,
      (_) => _TargetDialog(initialKm: _plan.targetMeters / 1000),
    );
    if (km == null) return;
    final updated = _plan.copyWith(targetMeters: km * 1000);
    Haptics.select();
    SoundService.instance.play(AppSound.tap, volume: 0.6);
    await _repo.savePlan(updated);
    if (!mounted) return;
    setState(() => _plan = updated);
  }

  void _showResult(BuildContext context) {
    final s = _finished;
    if (s == null) return;
    showAppDialog<void>(
      context,
      (dialogContext) => _ResultDialog(
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
    showAppDialog<void>(
      context,
      (dialogContext) => _SessionDialog(
        session: s,
        onCard: () {
          Navigator.pop(dialogContext);
          _openCard(context, s);
        },
        onDelete: () {
          Navigator.pop(dialogContext);
          _deleteSession(context, s);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: _BootLoader());
    }
    final pages = <Widget>[
      _TodayPage(
        today: _today,
        streak: _streak,
        monthKm: _monthKm,
        monthCount: _monthCount,
        targetKm: _plan.targetMeters / 1000,
        todayKm: _todayKm,
        planType: _plan.type,
        planLabel: _plan.startLabel,
        lastSession: _latestSession,
        onRun: _start,
        onLastSession: (s) => _showSession(context, s),
        onEditTarget: () => _editTarget(context),
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
        onEditTarget: () => _editTarget(context),
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
        onDelete: (s) => _deleteSession(context, s),
        deletingId: _deletingId,
      ),
    ];

    final running = _tracker != null && _finished == null;
    return PopScope(
      key: const ValueKey<String>('app'),
      canPop: !running,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        Haptics.light();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('跑步还在进行中，结束或退出跑中页再返回', style: TextStyle(fontSize: 14)),
            duration: Duration(seconds: 2),
          ),
        );
      },
      child: Scaffold(
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: AnimatedSwitcher(
                duration: AppMotion.base,
                switchInCurve: AppMotion.emphasized,
                switchOutCurve: AppMotion.standard,
                transitionBuilder: (child, animation) {
                  final curved = CurvedAnimation(
                      parent: animation, curve: AppMotion.emphasized);
                  // 往右边的标签走，新页从右侧 12 px 进来，旧页往右退，反之镜像。
                  final dx = _tabShift * 0.03;
                  return FadeTransition(
                    opacity: curved,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: Offset(dx, 0.012),
                        end: Offset.zero,
                      ).animate(curved),
                      child: child,
                    ),
                  );
                },
                child: KeyedSubtree(
                  key: ValueKey<int>(_tab),
                  child: pages[_tab],
                ),
              ),
            ),
          ),
        ),
        bottomNavigationBar: _TabBar(
          selected: _tab,
          onChanged: (i) => setState(() {
            _tabShift = i > _tab ? 1 : -1;
            _tab = i;
          }),
        ),
      ),
    );
  }
}

/* ---------------- 色块地形页面骨架 ---------------- */

const double _gap = 10;
const double _pagePad = 14;

const List<String> _monthCn = [
  '一月',
  '二月',
  '三月',
  '四月',
  '五月',
  '六月',
  '七月',
  '八月',
  '九月',
  '十月',
  '十一月',
  '十二月',
];

TextStyle _txt(double size, int weight, Color color) => TextStyle(
      fontSize: size,
      fontWeight: FontWeight.values[weight ~/ 100],
      color: color,
      height: 1.2,
      decoration: TextDecoration.none,
    );

/// 数字统一等宽，字号大到 28 以上才收紧字距，避免小字挤在一起。
TextStyle _num(double size, int weight, int color) => TextStyle(
      fontSize: size,
      fontWeight: FontWeight.values[weight ~/ 100],
      color: _c(color),
      height: 1.05,
      letterSpacing: size >= 28 ? -size * 0.02 : 0,
      fontFeatures: const [FontFeature.tabularFigures()],
      decoration: TextDecoration.none,
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

Widget _pageMeta(String text) =>
    Text(text, style: _txt(12, 500, _c(AppPalette.sand11)));

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
        borderRadius: BorderRadius.circular(AppRules.cardRadius),
        border:
            Border.all(width: AppRules.hairline, color: _c(AppPalette.sand6)),
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
            top: BorderSide(
                width: AppRules.hairline, color: _c(AppPalette.sand6)),
            bottom: BorderSide(
                width: AppRules.hairline, color: _c(AppPalette.sand6)),
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
  final double? number;
  final String Function(double value)? format;

  const _StatCell({
    required this.icon,
    required this.label,
    required this.value,
    this.number,
    this.format,
  });

  @override
  Widget build(BuildContext context) {
    final num = number;
    final fmt = format;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 2),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _iconLabel(icon, label),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: num != null && fmt != null
                ? RollingNumber(
                    value: num,
                    format: fmt,
                    style: _num(20, 600, AppPalette.sand12),
                  )
                : Text(value, style: _num(20, 600, AppPalette.sand12)),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool filled;
  final bool danger;
  final VoidCallback? onTap;
  final double fontSize;

  const _Pill({
    required this.label,
    this.icon,
    required this.filled,
    required this.onTap,
    this.danger = false,
    this.fontSize = 14,
  });

  @override
  Widget build(BuildContext context) {
    final int fg;
    final int bg;
    final int edge;
    if (danger && filled) {
      fg = AppPalette.sand1;
      bg = AppPalette.red11;
      edge = AppPalette.red11;
    } else if (danger) {
      fg = AppPalette.red11;
      bg = AppPalette.sand1;
      edge = AppPalette.red6;
    } else {
      fg = filled ? AppPalette.sand1 : AppPalette.sand12;
      bg = filled ? AppPalette.orange11 : AppPalette.sand1;
      edge = filled ? AppPalette.orange11 : AppPalette.sand6;
    }
    return Pressable(
      onTap: onTap,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: _c(bg),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(width: AppRules.hairline, color: _c(edge)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: _c(fg)),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _txt(fontSize, 600, _c(fg)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 粗笔跑者：44×44 骨架、4.8 笔重、圆头圆角，和设计板里第 6 个方案一致。
class _RunnerPainter extends CustomPainter {
  final int color;

  const _RunnerPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 44;
    canvas.scale(s);
    // 骨架本身略偏左，整体右移让它在圆里看起来居中。
    canvas.translate(2.3, -0.6);
    final body = Paint()
      ..color = _c(color)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawCircle(const Offset(28, 8.4), 4.4, Paint()..color = _c(color));

    final torso = Path()
      ..moveTo(25.4, 13.6)
      ..lineTo(19, 26);
    final frontLeg = Path()
      ..moveTo(19, 26)
      ..lineTo(27.6, 30.4)
      ..lineTo(26.2, 39);
    final backLeg = Path()
      ..moveTo(19, 26)
      ..lineTo(11.6, 29.8)
      ..lineTo(5, 27.2);
    final frontArm = Path()
      ..moveTo(23.8, 16.4)
      ..lineTo(31.4, 18.6)
      ..lineTo(34.4, 12.6);
    final backArm = Path()
      ..moveTo(22.8, 17.4)
      ..lineTo(14.6, 20.2)
      ..lineTo(11.6, 26.6);

    for (final path in [torso, frontLeg, backLeg, frontArm, backArm]) {
      canvas.drawPath(path, body);
    }
  }

  @override
  bool shouldRepaint(covariant _RunnerPainter old) => old.color != color;
}

/// 地形上的开跑钮：按下缩到 0.92，松手后一圈橙色脉冲扩散再进入跑中。
class _StartButton extends StatefulWidget {
  final VoidCallback onTap;

  const _StartButton({required this.onTap});

  @override
  State<_StartButton> createState() => _StartButtonState();
}

class _StartButtonState extends State<_StartButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 460),
  );
  bool _down = false;

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _fire() {
    if (!AppMotion.decorative) {
      widget.onTap();
      return;
    }
    _pulse.forward(from: 0);
    // 先让脉冲跑起来再切页，否则动效刚起就被新页面盖掉。
    Future<void>.delayed(AppMotion.quick, () {
      if (mounted) widget.onTap();
    });
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: _fire,
        child: SizedBox(
          width: 164,
          height: 164,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedBuilder(
                animation: _pulse,
                builder: (context, _) {
                  if (_pulse.value == 0) return const SizedBox.shrink();
                  final t = Curves.easeOutCubic.transform(_pulse.value);
                  return Container(
                    width: 108 + t * 50,
                    height: 108 + t * 50,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        width: 2,
                        color: _c(AppPalette.orange9)
                            .withValues(alpha: (1 - t) * 0.7),
                      ),
                    ),
                  );
                },
              ),
              Container(
                width: 138,
                height: 138,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    width: AppRules.hairline,
                    color: _c(AppPalette.sand1).withValues(alpha: 0.95),
                  ),
                ),
              ),
              AnimatedScale(
                scale: _down ? 0.92 : 1,
                duration: AppMotion.press,
                curve: AppMotion.standard,
                child: Container(
                  width: 108,
                  height: 108,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _c(AppPalette.orange11),
                    boxShadow: [
                      BoxShadow(
                        color: _c(AppPalette.orange9).withValues(alpha: 0.35),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: const Center(
                    child: SizedBox(
                      width: 58,
                      height: 58,
                      child: CustomPaint(
                        painter: _RunnerPainter(color: AppPalette.sand1),
                      ),
                    ),
                  ),
                ),
              ),
            ],
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
          border:
              Border.all(width: AppRules.hairline, color: _c(AppPalette.teal6)),
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

/// 启动时的呼吸图标，替代转圈。
class _BootLoader extends StatefulWidget {
  const _BootLoader();

  @override
  State<_BootLoader> createState() => _BootLoaderState();
}

class _BootLoaderState extends State<_BootLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breathe = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  @override
  void initState() {
    super.initState();
    if (AppMotion.decorative) _breathe.repeat(reverse: true);
  }

  @override
  void dispose() {
    _breathe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _breathe,
              builder: (context, _) {
                final t = AppMotion.decorative
                    ? Curves.easeInOut.transform(_breathe.value)
                    : 1.0;
                return Opacity(
                  opacity: 0.35 + 0.65 * t,
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: CustomPaint(
                      painter: const _RunnerPainter(color: AppPalette.orange11),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 14),
            Text('每日跑步', style: _txt(12, 500, _c(AppPalette.sand11))),
          ],
        ),
      );
}

/// 跑中的轨迹：每来一个新点，最后一段从 0 长到 1，轨迹是接着长出来的。
class _LiveMap extends StatefulWidget {
  final List<TrackPoint> points;

  const _LiveMap({required this.points});

  @override
  State<_LiveMap> createState() => _LiveMapState();
}

class _LiveMapState extends State<_LiveMap>
    with SingleTickerProviderStateMixin {
  late final AnimationController _grow = AnimationController(
    vsync: this,
    duration: AppMotion.base,
    value: 1,
  );
  late int _count = widget.points.length;

  @override
  void didUpdateWidget(_LiveMap old) {
    super.didUpdateWidget(old);
    final changed = widget.points.length != _count;
    _count = widget.points.length;
    if (changed && AppMotion.decorative) _grow.forward(from: 0);
  }

  @override
  void dispose() {
    _grow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _grow,
        builder: (context, child) => TerrainMap(
          points: widget.points,
          tail:
              AppMotion.reduce ? 1 : AppMotion.standard.transform(_grow.value),
        ),
      );
}

/// 颜色变化时才过渡，首帧直接落到目标色，不会从透明淡进来。
class _TintIcon extends StatefulWidget {
  final IconData icon;
  final int color;

  const _TintIcon({required this.icon, required this.color});

  @override
  State<_TintIcon> createState() => _TintIconState();
}

class _TintIconState extends State<_TintIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.base,
    value: 1,
  );
  late int _from = widget.color;
  late int _to = widget.color;

  @override
  void didUpdateWidget(_TintIcon old) {
    super.didUpdateWidget(old);
    if (widget.color == _to) return;
    _from = _to;
    _to = widget.color;
    if (AppMotion.reduce) {
      _controller.value = 1;
    } else {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _controller,
        builder: (context, child) => Icon(
          widget.icon,
          size: 20,
          color: Color.lerp(
            _c(_from),
            _c(_to),
            AppMotion.standard.transform(_controller.value),
          ),
        ),
      );
}

/// 记录中的呼吸点，告诉用户轨迹还在采。
class _PulseDot extends StatefulWidget {
  final double size;

  const _PulseDot({this.size = 7});

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );
  @override
  void initState() {
    super.initState();
    if (AppMotion.decorative) _pulse.repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) {
          final t = AppMotion.decorative
              ? Curves.easeInOut.transform(_pulse.value)
              : 1.0;
          return Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _c(AppPalette.orange9).withValues(alpha: 0.45 + 0.55 * t),
            ),
          );
        },
      );
}

class _TabBar extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onChanged;

  const _TabBar({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: _c(AppPalette.sand1),
          border: Border(
            top: BorderSide(
                width: AppRules.hairline, color: _c(AppPalette.sand6)),
          ),
        ),
        child: SafeArea(
          top: false,
          // 高度必须先钉死在 52，再谈居中；否则 Center 会吃掉整屏高度。
          child: SizedBox(
            height: 52,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: LayoutBuilder(
                  builder: (context, box) {
                    final w = box.maxWidth / 3;
                    return Stack(
                      children: [
                        AnimatedPositioned(
                          duration: AppMotion.base,
                          curve: AppMotion.standard,
                          left: w * selected + 20,
                          width: w - 40,
                          top: 7,
                          height: 38,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: _c(AppPalette.sand3),
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                        ),
                        Row(
                          children: [
                            _item(0, Icons.calendar_today_outlined, '今日'),
                            _item(1, Icons.route_outlined, '跑中'),
                            _item(2, Icons.list_outlined, '记录'),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );

  Widget _item(int index, IconData icon, String label) {
    final on = selected == index;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          if (selected == index) return;
          Haptics.select();
          onChanged(index);
        },
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _TintIcon(
              icon: icon,
              color: on ? AppPalette.orange11 : AppPalette.sand11,
            ),
            const SizedBox(height: 3),
            AnimatedDefaultTextStyle(
              duration: AppMotion.press,
              curve: Curves.easeOut,
              style: _txt(12, on ? 600 : 400,
                  _c(on ? AppPalette.orange11 : AppPalette.sand11)),
              child: Text(label),
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
  final double todayKm;
  final String planType;
  final String planLabel;
  final WorkoutSession? lastSession;
  final VoidCallback onRun;
  final ValueChanged<WorkoutSession>? onLastSession;
  final VoidCallback onEditTarget;

  const _TodayPage({
    required this.today,
    required this.streak,
    required this.monthKm,
    required this.monthCount,
    required this.targetKm,
    required this.todayKm,
    required this.planType,
    required this.planLabel,
    required this.lastSession,
    required this.onRun,
    required this.onLastSession,
    required this.onEditTarget,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) {
          final mapH = (box.maxHeight - 300).clamp(200.0, 560.0);
          return _page([
            _header(
              _pageTitle('今日'),
              _pageMeta(
                  '${today.month}月${today.day}日 周${_weekCn[today.weekday - 1]}'),
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
                    top: mapH * 0.46 - 82,
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
                          value: '$streak 天',
                          number: streak.toDouble(),
                          format: (v) => '${v.round()} 天',
                        ),
                        _StatCell(
                          icon: Icons.straighten,
                          label: '本月',
                          value: '${monthKm.toStringAsFixed(1)} km',
                          number: monthKm,
                          format: (v) => '${v.toStringAsFixed(1)} km',
                        ),
                        _StatCell(
                          icon: Icons.calendar_month_outlined,
                          label: '打卡',
                          value: '$monthCount 次',
                          number: monthCount.toDouble(),
                          format: (v) => '${v.round()} 次',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: _gap),
            _targetCard(targetKm, onEditTarget, todayKm: todayKm),
            const SizedBox(height: _gap),
            _lastRun(),
          ]);
        },
      );

  Widget _lastRun() {
    final last = lastSession;
    return Pressable(
      onTap: last != null && onLastSession != null
          ? () => onLastSession!(last)
          : null,
      scale: 0.98,
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
                radius: AppRules.thumbRadius,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    last == null
                        ? '还没有跑步记录'
                        : '上次跑步　${_dateShort(last.startTime)}',
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
            if (last != null)
              Icon(Icons.chevron_right, size: 16, color: _c(AppPalette.sand11)),
          ],
        ),
      ),
    );
  }
}

/// 目标卡：点一下就能改，右侧铅笔提示可编辑。
Widget _targetCard(
  double targetKm,
  VoidCallback onEdit, {
  double? todayKm,
}) {
  final done = todayKm ?? 0;
  final ratio = targetKm <= 0 ? 0.0 : (done / targetKm).clamp(0.0, 1.0);
  final reached = ratio >= 1;
  return Pressable(
    onTap: onEdit,
    scale: 0.98,
    child: _card(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _iconLabel(Icons.track_changes, '今日目标'),
              const Spacer(),
              RollingNumber(
                value: targetKm,
                format: (v) => '${v.toStringAsFixed(2)} km',
                style: _num(20, 600, AppPalette.sand12),
              ),
              const SizedBox(width: 8),
              Icon(Icons.edit_outlined, size: 16, color: _c(AppPalette.sand11)),
            ],
          ),
          if (todayKm != null) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: ratio),
                duration: AppMotion.settle,
                curve: AppMotion.standard,
                builder: (context, value, child) => Stack(
                  children: [
                    Container(height: 5, color: _c(AppPalette.sand4)),
                    FractionallySizedBox(
                      widthFactor: value,
                      child: Container(
                        height: 5,
                        color:
                            _c(reached ? AppPalette.teal9 : AppPalette.orange9),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Text('今日已跑', style: _txt(12, 500, _c(AppPalette.sand11))),
                const Spacer(),
                Text('${done.toStringAsFixed(2)} km',
                    style: _num(12, 600, AppPalette.sand11)),
              ],
            ),
          ],
        ],
      ),
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
  final int kcal;
  final bool paused;
  final bool autoCheckedIn;
  final DateTime today;
  final String planType;
  final double targetKm;
  final VoidCallback onEditTarget;
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
    required this.onEditTarget,
    required this.onStart,
    required this.onPause,
    required this.onFinish,
    required this.onResult,
  });

  @override
  Widget build(BuildContext context) {
    final stage = session != null
        ? 'result'
        : tracker == null
            ? 'idle'
            : 'live';
    final child = session != null
        ? _result(session!)
        : tracker == null
            ? _idle()
            : _live();
    return AnimatedSwitcher(
      duration: AppMotion.base,
      switchInCurve: AppMotion.emphasized,
      switchOutCurve: AppMotion.standard,
      transitionBuilder: (child, animation) {
        final curved =
            CurvedAnimation(parent: animation, curve: AppMotion.emphasized);
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.015),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
      child: KeyedSubtree(key: ValueKey<String>(stage), child: child),
    );
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
                    top: mapH * 0.46 - 82,
                    height: 132,
                    child: Center(child: _StartButton(onTap: onStart)),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: _gap),
        _targetCard(targetKm, onEditTarget),
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
          icon: Icons.local_fire_department_outlined,
          label: '消耗',
          value: '$kcal'),
    ];
    return _page([
      _header(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            paused ? _liveDot(7, AppPalette.sand11) : const _PulseDot(size: 7),
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
            child:
                Text(_clock(elapsed), style: _num(48, 700, AppPalette.sand12)),
          ),
          const SizedBox(height: 5),
          _iconLabel(Icons.schedule, '已用时间'),
        ],
      ),
      const SizedBox(height: _gap),
      Expanded(
        child: Stack(
          children: [
            Positioned.fill(child: _LiveMap(points: points)),
            Positioned(
              right: 10,
              top: 10,
              child: _mapChip(
                accent: !paused,
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (paused)
                      _liveDot(6, AppPalette.sand11)
                    else
                      const _PulseDot(size: 6),
                    const SizedBox(width: 6),
                    Text(
                      paused ? '已暂停' : '记录中',
                      style: _txt(12, 600,
                          _c(paused ? AppPalette.sand11 : AppPalette.orange11)),
                    ),
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
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0, end: 1),
                      duration: AppMotion.reduce
                          ? Duration.zero
                          : const Duration(milliseconds: 720),
                      curve: AppMotion.emphasized,
                      builder: (context, value, child) =>
                          TerrainMap(points: s.points, progress: value),
                    ),
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
                  TweenAnimationBuilder<double>(
                    tween:
                        Tween<double>(begin: 0, end: s.distanceMeters / 1000),
                    duration: AppMotion.settle,
                    curve: AppMotion.emphasized,
                    builder: (context, value, child) => Text(
                      '${value.toStringAsFixed(2)} km',
                      style: _num(48, 700, AppPalette.sand12),
                    ),
                  ),
                  const SizedBox(height: 10),
                  FittedBox(
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _iconLabel(Icons.schedule, _clock(s.elapsed),
                            color: AppPalette.sand12,
                            size: 14,
                            weight: 600,
                            gap: 5),
                        const SizedBox(width: 16),
                        _iconLabel(Icons.speed_outlined, s.averagePaceLabel,
                            color: AppPalette.sand12,
                            size: 14,
                            weight: 600,
                            gap: 5),
                        const SizedBox(width: 16),
                        _iconLabel(Icons.local_fire_department_outlined,
                            '${s.calories} kcal',
                            color: AppPalette.sand12,
                            size: 14,
                            weight: 600,
                            gap: 5),
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
                  PaceProfile(values: splits, height: 44),
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
                    icon: Icons.replay,
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
  final ValueChanged<WorkoutSession> onDelete;
  final String? deletingId;

  const _HistoryPage({
    required this.repo,
    required this.today,
    required this.monthKm,
    required this.monthCount,
    required this.onSession,
    required this.onDelete,
    required this.deletingId,
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
                  value: '${monthKm.toStringAsFixed(1)} km',
                  number: monthKm,
                  format: (v) => '${v.toStringAsFixed(1)} km',
                ),
                _StatCell(
                  icon: Icons.calendar_month_outlined,
                  label: '打卡次数',
                  value: '$monthCount 次',
                  number: monthCount.toDouble(),
                  format: (v) => '${v.round()} 次',
                ),
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
                      _iconLabel(
                          Icons.calendar_today_outlined, '${today.month} 月月历',
                          color: AppPalette.sand12,
                          size: 14,
                          weight: 600,
                          gap: 7),
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
            AnimatedSwitcher(
              duration: AppMotion.quick,
              switchInCurve: AppMotion.standard,
              switchOutCurve: AppMotion.standard,
              child: sessions.isEmpty
                  ? _emptyState()
                  : Column(
                      key: const ValueKey<String>('rows'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final s in sessions)
                          _HistoryRow(
                            session: s,
                            removing: s.id == deletingId,
                            onTap: () => onSession(s),
                            onDelete: () => onDelete(s),
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

/// 没有记录时给一个安静的空状态，不留一句干巴巴的提示。
Widget _emptyState() => Padding(
      padding: const EdgeInsets.only(top: 44, bottom: 36),
      child: Column(
        children: [
          SizedBox(
            width: 64,
            height: 64,
            child: CustomPaint(
              painter: const _RunnerPainter(color: AppPalette.sage8),
            ),
          ),
          const SizedBox(height: 12),
          Text('还没有跑步记录', style: _txt(14, 600, _c(AppPalette.sand11))),
          const SizedBox(height: 4),
          Text('回今日页点一下开跑，第一条记录就出现在这里',
              textAlign: TextAlign.center,
              style: _txt(12, 400, _c(AppPalette.sand11))),
        ],
      ),
    );

class _HistoryRow extends StatelessWidget {
  final WorkoutSession session;
  final bool removing;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _HistoryRow({
    required this.session,
    required this.removing,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final km = session.distanceMeters / 1000;
    return ClipRect(
      child: AnimatedAlign(
        alignment: Alignment.topCenter,
        heightFactor: removing ? 0 : 1,
        duration: AppMotion.quick,
        curve: AppMotion.standard,
        child: AnimatedOpacity(
          opacity: removing ? 0 : 1,
          duration: AppMotion.quick,
          curve: AppMotion.standard,
          child: Pressable(
            onTap: onTap,
            haptic: false,
            scale: 0.985,
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
                      radius: AppRules.thumbRadius,
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
                        Text(
                            '${_clock(session.elapsed)}　${session.averagePaceLabel}',
                            style: _num(12, 500, AppPalette.sand11)),
                      ],
                    ),
                  ),
                  // 44 宽的点击区，避免手指落在卡片空白处反而打开详情。
                  Pressable(
                    onTap: onDelete,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                      child: Icon(Icons.delete_outline,
                          size: 16, color: _c(AppPalette.sand11)),
                    ),
                  ),
                ],
              ),
            ),
          ),
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
    return AnimatedContainer(
      height: 26,
      duration: AppMotion.base,
      curve: AppMotion.standard,
      decoration: BoxDecoration(
        color: _c(bg),
        borderRadius: BorderRadius.circular(AppRules.cellRadius),
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
      return Text('这次没有分段数据', style: _txt(12, 500, _c(AppPalette.sand11)));
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
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          width: AppRules.hairline,
                          color: _c(AppPalette.sage8)),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text('${i + 1} km',
                      style: _txt(12, 400, _c(AppPalette.sand11))),
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
            borderRadius: BorderRadius.circular(AppRules.dialogRadius),
            border: Border.all(
                width: AppRules.hairline, color: _c(AppPalette.sand6)),
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

/// 通用确认浮卡，破坏性操作统一走它。
class _ConfirmDialog extends StatelessWidget {
  final String title;
  final String body;
  final String confirmLabel;

  const _ConfirmDialog({
    required this.title,
    required this.body,
    required this.confirmLabel,
  });

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: _c(AppPalette.sand1),
                borderRadius: BorderRadius.circular(AppRules.dialogRadius),
                border: Border.all(
                    width: AppRules.hairline, color: _c(AppPalette.sand6)),
                boxShadow: [
                  BoxShadow(
                    color: _c(AppPalette.sand12).withValues(alpha: 0.22),
                    blurRadius: 48,
                    offset: const Offset(0, 18),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(title, style: _txt(18, 600, _c(AppPalette.sand12))),
                  const SizedBox(height: 6),
                  Text(body,
                      style: _txt(13, 400, _c(AppPalette.sand11))
                          .copyWith(height: 1.5)),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _Pill(
                          label: '取消',
                          filled: false,
                          onTap: () => Navigator.pop(context, false),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _Pill(
                          label: confirmLabel,
                          filled: true,
                          danger: true,
                          onTap: () => Navigator.pop(context, true),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

/// 改每日目标：直接输入公里数，也可以点 3 / 5 / 10 快速填。
class _TargetDialog extends StatefulWidget {
  final double initialKm;

  const _TargetDialog({required this.initialKm});

  @override
  State<_TargetDialog> createState() => _TargetDialogState();
}

class _TargetDialogState extends State<_TargetDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialKm == widget.initialKm.roundToDouble()
        ? widget.initialKm.toStringAsFixed(0)
        : widget.initialKm.toStringAsFixed(1),
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double? _value() {
    final v = double.tryParse(_controller.text.trim());
    if (v == null || v < 0.5 || v > 100) return null;
    return v;
  }

  void _save() {
    final v = _value();
    if (v == null) {
      setState(() => _error = '请输入 0.5 到 100 之间的公里数');
      return;
    }
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: _c(AppPalette.sand1),
                borderRadius: BorderRadius.circular(AppRules.dialogRadius),
                border: Border.all(
                    width: AppRules.hairline, color: _c(AppPalette.sand6)),
                boxShadow: [
                  BoxShadow(
                    color: _c(AppPalette.sand12).withValues(alpha: 0.22),
                    blurRadius: 48,
                    offset: const Offset(0, 18),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('每日目标', style: _txt(18, 600, _c(AppPalette.sand12))),
                  const SizedBox(height: 4),
                  Text('跑满目标的 80% 会自动打卡',
                      style: _txt(12, 500, _c(AppPalette.sand11))),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _controller,
                    autofocus: true,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _save(),
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                    style: _num(28, 600, AppPalette.sand12),
                    decoration: InputDecoration(
                      suffixText: 'km',
                      suffixStyle: _txt(14, 500, _c(AppPalette.sand11)),
                      filled: true,
                      fillColor: _c(AppPalette.sand2),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      enabledBorder: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(AppRules.fieldRadius),
                        borderSide: BorderSide(
                            width: AppRules.hairline,
                            color: _c(AppPalette.sand6)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(AppRules.fieldRadius),
                        borderSide: BorderSide(
                            width: 1, color: _c(AppPalette.orange11)),
                      ),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 6),
                    Text(_error!, style: _txt(12, 500, _c(AppPalette.red11))),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      for (final km in const [3.0, 5.0, 10.0])
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Pressable(
                            onTap: () {
                              _controller.text = km.toStringAsFixed(0);
                              setState(() => _error = null);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 8),
                              decoration: BoxDecoration(
                                color: _c(AppPalette.sand2),
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                    width: AppRules.hairline,
                                    color: _c(AppPalette.sand6)),
                              ),
                              child: Text('${km.toStringAsFixed(0)} km',
                                  style: _num(12, 600, AppPalette.sand11)),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _Pill(
                          label: '取消',
                          filled: false,
                          onTap: () => Navigator.pop(context),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _Pill(
                          label: '保存',
                          filled: true,
                          onTap: _save,
                        ),
                      ),
                    ],
                  ),
                ],
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
  final VoidCallback onDelete;

  const _SessionDialog({
    required this.session,
    required this.onCard,
    required this.onDelete,
  });

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
            const SizedBox(height: 8),
            _Pill(
                label: '删除这条记录',
                icon: Icons.delete_outline,
                filled: false,
                danger: true,
                onTap: onDelete),
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
          title: Text('运动记录图', style: _txt(16, 600, _c(AppPalette.sand12))),
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
