import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'data/backup_service.dart';
import 'data/persistence_store.dart';
import 'domain/models.dart';
import 'domain/repository.dart';
import 'domain/tracking.dart';
import 'platform/gallery.dart';
import 'platform/location_source.dart';
import 'theme.dart';
import 'widgets/daily_icon.dart';
import 'widgets/run_share_card.dart';
import 'widgets/runner_mark.dart';
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
        colorScheme: ColorScheme.light(primary: _c(AppPalette.accent)),
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

enum _RunLocationStatus { acquiring, ready, weak }

class _AppShellState extends State<AppShell> {
  final PersistentRepository _repo =
      PersistentRepository(createPersistenceStore());
  final GallerySaver _gallery = createGallerySaver();
  late final DataBackupService _backup;
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
  double? _speedKmh;
  int _heartRate = 0;
  DateTime? _lastFixAt;
  _RunLocationStatus _locationStatus = _RunLocationStatus.acquiring;
  bool _checkingLocation = false;
  int _tick = 0;
  DateTime _simulated = DateTime.now().subtract(const Duration(minutes: 31));
  WorkoutSession? _finished;
  bool _paused = false;
  bool _starting = false;
  bool _openingRun = false;
  int _tab = 0;
  String? _deletingId;

  @override
  void initState() {
    super.initState();
    _backup = DataBackupService(_repo);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await _repo.init();
    } catch (_) {
      // 存储不可用时退回内存，界面仍可操作，只是不跨重启。
    }
    // 系统备份先恢复内部库；这里再检查公共目录里的人工保险。
    await _backup.initialize();
    final hadDataAtLaunch = _repo.plans.isNotEmpty ||
        _repo.sessions.isNotEmpty ||
        _repo.checkIns.isNotEmpty;
    await SoundService.instance.init();
    await _migrateOnce();
    _plan = _repo.planFor(_today) ??
        Plan(
          id: 'p-${_today.year}${_today.month}${_today.day}',
          date: _today,
          startMinutes: 0,
          type: '自由跑',
          targetMeters: 3000,
          reminderOffsetMinutes: 0,
        );
    if (_repo.planFor(_today) == null) await _repo.savePlan(_plan);
    // 冷启动原本就是空库时不写备份：Android 11+ 可能读不到旧文件，
    // 此刻哪怕只创建了默认计划，也不能覆盖掉用户真正需要的那一份。
    if (hadDataAtLaunch) await _persistBackup();
    if (!mounted) return;
    setState(() => _ready = true);
  }

  Future<bool> _persistBackup() async => _backup.save();

  /// 旧版本会写入两条示例跑步、写死 5 公里目标与 19:30 的开跑时间。
  /// 这里只收敛一次：示例数据清掉，计划里的时间字段归零，目标归一。
  Future<void> _migrateOnce() async {
    try {
      if (await _repo.readMeta('data_version') == '3') return;
      await _repo.purgeDemoData();
      for (final plan in List<Plan>.from(_repo.plans)) {
        final target =
            (plan.targetMeters - 5000).abs() < 1 ? 3000.0 : plan.targetMeters;
        await _repo.savePlan(plan.copyWith(
          targetMeters: target,
          startMinutes: 0,
          type: '自由跑',
        ));
      }
      await _repo.writeMeta('data_version', '3');
      await _persistBackup();
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

  double get _todayKm =>
      _repo.sessions
          .where((s) => dateOnly(s.startTime) == _today)
          .fold<double>(0, (sum, s) => sum + s.distanceMeters) /
      1000;

  double get _monthKm =>
      _repo.sessions
          .where((s) =>
              s.startTime.year == _today.year &&
              s.startTime.month == _today.month)
          .fold<double>(0, (sum, s) => sum + s.distanceMeters) /
      1000;

  int get _monthRuns => _repo.sessions
      .where((s) =>
          s.startTime.year == _today.year && s.startTime.month == _today.month)
      .length;

  double get _totalKm =>
      _repo.sessions.fold<double>(0, (sum, s) => sum + s.distanceMeters) / 1000;

  void _addSimulatedPoint() {
    _tick++;
    final ts = _simulated.add(const Duration(seconds: 60));
    _applyFix(TrackFix(
      lat: 39.9 + _tick * 0.0018,
      lng: 116.3 + math.sin(_tick * 0.55) * 0.0016,
      ts: ts,
      accuracyMeters: 6,
    ));
    _simulated = ts;
  }

  DateTime get _trackerNow =>
      _location.isSimulated ? _simulated : DateTime.now();

  bool get _hasFreshFix {
    final last = _lastFixAt;
    return last != null && DateTime.now().difference(last).inSeconds < 3;
  }

  void _applyFix(TrackFix fix) {
    if (_tracker == null || _finished != null || _paused) return;
    final accepted = _tracker!.addPoint(
      lat: fix.lat,
      lng: fix.lng,
      ts: fix.ts,
      accuracyMeters: fix.accuracyMeters,
      speedMps: fix.speedMps,
      heartRateBpm: fix.heartRateBpm,
    );
    if (!accepted) {
      if (!_hasFreshFix) _locationStatus = _RunLocationStatus.weak;
      return;
    }
    if (_location.isSimulated) _simulated = fix.ts;
    _lastFixAt = DateTime.now();
    _locationStatus = _RunLocationStatus.ready;
    if (fix.speedMps != null && fix.speedMps! > 0) {
      _speedKmh = fix.speedMps! * 3.6;
    } else {
      // 有些手机定位不给速度字段，用最近两点的位移自己算。
      final pts = _tracker!.points;
      if (pts.length >= 2) {
        final a = pts[pts.length - 2];
        final b = pts.last;
        final dt = b.ts.difference(a.ts).inMilliseconds / 1000.0;
        final d = haversineMeters(a.lat, a.lng, b.lat, b.lng);
        if (dt > 0 && d > 0) _speedKmh = d / dt * 3.6;
      }
    }
    if (fix.heartRateBpm != null) _heartRate = fix.heartRateBpm!;
    _elapsed = _tracker!.elapsed(_trackerNow);
    _pace = _tracker!.currentPaceSecPerKm();
  }

  /// 定位流没有按时给点时，用单次定位兜底，避免真机上只有时间在走。
  Future<void> _probeLocation() async {
    final tracker = _tracker;
    if (tracker == null || _finished != null || _paused || _checkingLocation) {
      return;
    }
    _checkingLocation = true;
    final fix = await _location.current();
    _checkingLocation = false;
    if (!mounted ||
        !identical(_tracker, tracker) ||
        _finished != null ||
        _paused) {
      return;
    }
    if (fix == null) {
      if (!_hasFreshFix) {
        setState(() => _locationStatus = _RunLocationStatus.weak);
      }
      return;
    }
    setState(() => _applyFix(fix));
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
        onError: (Object error) {
          if (!mounted || _paused || _finished != null || _hasFreshFix) return;
          setState(() => _locationStatus = _RunLocationStatus.weak);
        },
      );
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || _tracker == null) return;
        final fresh = _hasFreshFix;
        final last = _lastFixAt;
        final stale =
            last != null && DateTime.now().difference(last).inSeconds >= 8;
        setState(() {
          _elapsed = _tracker!.elapsed(_trackerNow);
          if (stale && _locationStatus == _RunLocationStatus.ready) {
            _locationStatus = _RunLocationStatus.weak;
          }
        });
        if (!fresh) {
          _probeLocation();
        }
      });
    }
  }

  Future<void> _start() async {
    if (_starting || (_tracker != null && _finished == null)) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _starting = true);
    try {
      if (!await _location.ensurePermission() || !mounted) return;
      _beginTracking();
      return;
    } catch (_) {
      // 平台无法完成定位授权时，用同一个提示让用户知道如何继续。
    } finally {
      if (mounted && _starting) {
        setState(() => _starting = false);
        messenger.showSnackBar(const SnackBar(
          content: Text('需要定位权限才能记录轨迹', style: TextStyle(fontSize: 14)),
        ));
      }
    }
  }

  void _beginTracking() {
    if (_location.isSimulated) {
      _simulated = DateTime.now().subtract(const Duration(minutes: 31));
    }
    _tracker = TrackingManager(
      sessionId: 's-${DateTime.now().millisecondsSinceEpoch}',
      planId: _plan.id,
    );
    _tracker!.start(_trackerNow);
    _finished = null;
    _paused = false;
    _heartRate = 0;
    _tick = 0;
    _speedKmh = null;
    _lastFixAt = null;
    _locationStatus = _RunLocationStatus.acquiring;
    if (_location.isSimulated) {
      _addSimulatedPoint();
    }
    _attachStreams();
    if (!_location.isSimulated) _probeLocation();
    Haptics.light();
    SoundService.instance.play(AppSound.start);
    setState(() {
      _elapsed = Duration.zero;
      _pace = 0;
      _starting = false;
      _openingRun = true;
      _tab = 1;
    });
  }

  void _togglePause() {
    if (_tracker == null || _finished != null) return;
    Haptics.light();
    SoundService.instance.play(AppSound.tap, volume: 0.7);
    if (_paused) {
      _tracker!.resume(_trackerNow);
      setState(() {
        _paused = false;
        if (!_location.isSimulated) {
          _locationStatus = _RunLocationStatus.acquiring;
        }
      });
      _attachStreams();
    } else {
      _timer?.cancel();
      _fixSub?.cancel();
      _location.stop();
      _tracker!.pause(_trackerNow);
      _lastFixAt = null;
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
    await _persistBackup();
    if (!mounted) return;
    Haptics.heavy();
    SoundService.instance.play(AppSound.finish);
    setState(() {
      _finished = session;
      _elapsed = session.elapsed;
      _pace = session.averagePaceSecPerKm;
    });
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
    await _persistBackup();
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
      fromBottom: true,
    );
    if (km == null) return;
    final updated = _plan.copyWith(targetMeters: km * 1000);
    Haptics.select();
    SoundService.instance.play(AppSound.tap, volume: 0.6);
    await _repo.savePlan(updated);
    await _persistBackup();
    if (!mounted) return;
    setState(() => _plan = updated);
  }

  Future<void> _showBackupMenu(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final action = await showAppDialog<String>(
      context,
      (_) => _BackupMenu(lastSavedAt: _backup.lastSavedAt),
    );
    if (action == null || !mounted) return;
    if (action == 'restore') {
      final ok = await _backup.restorePicked();
      if (!mounted) return;
      if (ok) {
        await _migrateOnce();
        await _persistBackup();
        setState(() {});
      }
      messenger.showSnackBar(SnackBar(
        content: Text(ok ? '已从备份文件恢复数据' : '没有读到可用的备份文件',
            style: const TextStyle(fontSize: 14)),
      ));
    } else if (action == 'save') {
      final ok = await _persistBackup();
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text(ok ? '备份已写入下载目录' : '备份写入失败',
            style: const TextStyle(fontSize: 14)),
      ));
    }
  }

  void _showResult(BuildContext context) {
    final s = _finished;
    if (s == null) return;
    showAppDialog<void>(
      context,
      (dialogContext) => _ResultDialog(
        session: s,
        onSave: () {
          Navigator.pop(dialogContext);
          _openCard(context, s);
        },
      ),
    );
  }

  void _openCard(BuildContext context, WorkoutSession s) {
    Navigator.of(context).push(PageRouteBuilder<void>(
      transitionDuration: AppMotion.runTransition,
      reverseTransitionDuration: AppMotion.runTransition,
      pageBuilder: (_, animation, secondaryAnimation) => _CardScreen(
        session: s,
        dateLabel: _dateCn(s.startTime),
        gallery: _gallery,
      ),
      transitionsBuilder: (_, animation, secondaryAnimation, child) {
        return FadeTransition(
          opacity: animation.drive(CurveTween(curve: AppMotion.standard)),
          child: child,
        );
      },
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
    final running = _tracker != null && _finished == null;
    final pages = <Widget>[
      _TodayPage(
        today: _today,
        monthKm: _monthKm,
        monthRuns: _monthRuns,
        totalKm: _totalKm,
        targetKm: _plan.targetMeters / 1000,
        todayKm: _todayKm,
        startStatus: _starting
            ? '等待定位授权'
            : running
                ? (_paused ? '已暂停，返回跑中' : '返回跑中')
                : '',
        onRun: _starting
            ? null
            : running
                ? () => _switchTab(1)
                : _start,
        onEditTarget: () => _editTarget(context),
      ),
      _RunningPage(
        session: _finished,
        tracker: _tracker,
        points: _tracker?.points ?? const <TrackPoint>[],
        elapsed: _elapsed,
        distance: (_tracker?.distanceMeters ?? 0) / 1000,
        pace: _pace.isFinite && _pace > 0 ? _paceLabel(_pace) : null,
        speedKmh: _speedKmh,
        locationStatus: _locationStatus,
        heartRate: _heartRate > 0 ? _heartRate : null,
        paused: _paused,
        onStart: _start,
        onPause: _togglePause,
        onFinish: _finish,
        onResult: () => _showResult(context),
        onCard: _finished == null ? null : () => _openCard(context, _finished!),
      ),
      _HistoryPage(
        repo: _repo,
        today: _today,
        monthKm: _monthKm,
        onSession: (s) => _showSession(context, s),
        onDelete: (s) => _deleteSession(context, s),
        deletingId: _deletingId,
        onBackup: () => _showBackupMenu(context),
      ),
    ];

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
              child: TweenAnimationBuilder<double>(
                key: ValueKey<int>(_tab),
                tween: Tween(begin: _tab == 0 ? .8 : .65, end: 1),
                duration: _openingRun ? AppMotion.runTransition : AppMotion.tab,
                curve: Curves.easeOut,
                builder: (_, value, child) =>
                    Opacity(opacity: value, child: child),
                child: pages[_tab],
              ),
            ),
          ),
        ),
        bottomNavigationBar: _TabBar(
          selected: _tab,
          recordingHint: running ? (_paused ? '已暂停' : '正在记录') : null,
          onChanged: _switchTab,
        ),
      ),
    );
  }

  void _switchTab(int index) {
    if (index == _tab) return;
    setState(() {
      _openingRun = false;
      _tab = index;
    });
  }
}

/* ---------------- 共享样式 ---------------- */

/// 全 App 字号在这里统一放大，改一处即可整体调档。
const double _typeScale = 1.08;

TextStyle _txt(double size, int weight, Color color) => TextStyle(
      fontSize: size * _typeScale,
      fontWeight: FontWeight.values[weight ~/ 100],
      color: color,
      height: 1.2,
      decoration: TextDecoration.none,
    );

/// 数字统一等宽，字号大到 28 以上才收紧字距，避免小字挤在一起。
TextStyle _num(double size, int weight, int color) => TextStyle(
      fontSize: size * _typeScale,
      fontWeight: FontWeight.values[weight ~/ 100],
      color: _c(color),
      height: 1.05,
      letterSpacing: size >= 28 ? -size * 0.02 : 0,
      fontFeatures: const [FontFeature.tabularFigures()],
      decoration: TextDecoration.none,
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
  DailyGlyph icon,
  String text, {
  int color = AppPalette.sand11,
  double size = 12,
  int weight = 500,
  double gap = 6,
}) =>
    Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DailyIcon(icon, size: 16, color: _c(color)),
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
  final bool card;

  const _StatBar({required this.cells, this.card = true});

  @override
  Widget build(BuildContext context) {
    final row = SizedBox(
      height: 64,
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
  final DailyGlyph icon;
  final String label;
  final String value;

  const _StatCell({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
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
}

class _Pill extends StatelessWidget {
  final String label;
  final DailyGlyph? icon;
  final bool filled;
  final bool danger;
  final VoidCallback? onTap;

  const _Pill({
    required this.label,
    this.icon,
    required this.filled,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final glyph = icon;
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
      bg = filled ? AppPalette.accent : AppPalette.sand1;
      edge = filled ? AppPalette.accent : AppPalette.sand6;
    }
    return Semantics(
      button: true,
      enabled: onTap != null,
      child: Pressable(
        onTap: onTap,
        child: Container(
          height: 48,
          decoration: BoxDecoration(
            color: _c(bg),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _c(edge)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (glyph != null) ...[
                DailyIcon(glyph, size: 16, color: _c(fg)),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _txt(14, 600, _c(fg)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 跑者由母版 tool/assets/runner-master.png 抽出：身体与头各是一条闭合轮廓，
/// 速度线同样是闭合轮廓。整条边缘光滑连续，没有笔画接头、端帽与折点。
/// 图标、开跑按钮、空状态、启动页共用这一份路径。
Path _contoursPath(List<List<double>> contours) {
  final path = Path()..fillType = PathFillType.evenOdd;
  for (final contour in contours) {
    if (contour.length < 6) continue;
    path.moveTo(contour[0], contour[1]);
    for (int i = 2; i + 1 < contour.length; i += 2) {
      path.lineTo(contour[i], contour[i + 1]);
    }
    path.close();
  }
  return path;
}

final Path _runnerPath = _contoursPath(runnerContours);
final Path _dashPath = _contoursPath(runnerDashes);

class _RunnerPainter extends CustomPainter {
  final int color;

  const _RunnerPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 48;
    canvas.save();
    canvas.scale(s);
    final ink = _c(color);

    canvas.drawPath(_dashPath, Paint()..color = ink);
    canvas.drawPath(_runnerPath, Paint()..color = ink);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RunnerPainter old) => old.color != color;
}

/// 实心圆响应按压，双环保持居中。
class _StartButton extends StatefulWidget {
  final VoidCallback? onTap;
  final double size;
  final String label;

  const _StartButton({
    required this.onTap,
    this.size = 226,
    this.label = '开始跑步',
  });

  @override
  State<_StartButton> createState() => _StartButtonState();
}

class _StartButtonState extends State<_StartButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final diameter = widget.size * 154 / 226;
    final pressed = _down && widget.onTap != null;
    final duration = AppMotion.reduce
        ? Duration.zero
        : Duration(milliseconds: pressed ? 90 : 150);
    return SizedBox.square(
      dimension: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFFC9DFF0)),
            ),
          ),
          Container(
            width: widget.size * 202 / 226,
            height: widget.size * 202 / 226,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(AppPalette.accentSoft),
            ),
          ),
          Semantics(
            button: true,
            enabled: widget.onTap != null,
            label: widget.label,
            child: AnimatedScale(
              duration: duration,
              curve: AppMotion.standard,
              scale: pressed && !AppMotion.reduce ? 0.97 : 1,
              child: AnimatedContainer(
                duration: duration,
                width: diameter,
                height: diameter,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      _c(pressed ? 0xFF0964BB : 0xFF0A6DCA),
                      _c(pressed ? 0xFF0C6ABB : AppPalette.accent),
                      const Color(0xFF125EAB),
                    ],
                    stops: const [0, 0.68, 1],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: _c(AppPalette.accent)
                          .withValues(alpha: pressed ? 0.10 : 0.14),
                      blurRadius: pressed ? 8 : 18,
                      offset: Offset(0, pressed ? 2 : 6),
                    ),
                  ],
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: widget.onTap,
                    onHighlightChanged: (pressed) {
                      if (_down != pressed) setState(() => _down = pressed);
                    },
                    child: Center(
                      child: SizedBox.square(
                        dimension: diameter * 0.57,
                        child: const CustomPaint(
                          painter: _RunnerPainter(color: 0xFFFFFFFF),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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
                      painter: const _RunnerPainter(color: AppPalette.accent),
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
    if (changed &&
        widget.points.isNotEmpty &&
        !widget.points.last.isPauseBoundary &&
        AppMotion.decorative) {
      _grow.forward(from: 0);
    }
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
          live: true,
          tail:
              AppMotion.reduce ? 1 : AppMotion.standard.transform(_grow.value),
        ),
      );
}

class _TabBar extends StatelessWidget {
  final int selected;
  final String? recordingHint;
  final ValueChanged<int> onChanged;

  const _TabBar({
    required this.selected,
    required this.recordingHint,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const BoxDecoration(
          color: Color(AppPalette.sand1),
          border: Border(top: BorderSide(color: Color(AppPalette.sand6))),
        ),
        child: SafeArea(
          top: false,
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 11),
                child: Row(
                  children: [
                    _item(0, DailyGlyph.calendar, '今日'),
                    _item(1, DailyGlyph.route, '跑中'),
                    _item(2, DailyGlyph.list, '记录'),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  Widget _item(int index, DailyGlyph icon, String label) {
    final on = selected == index;
    final hint = index == 1 ? recordingHint : null;
    final ink = _c(on ? AppPalette.accentText : AppPalette.sand11);
    return Expanded(
      child: Semantics(
        button: true,
        selected: on,
        label: hint == null ? label : '$label，$hint',
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: () {
              if (on) return;
              Haptics.select();
              onChanged(index);
            },
            child: ExcludeSemantics(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 58),
                child: Center(
                  child: FractionallySizedBox(
                    widthFactor: .70,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: on ? _c(AppPalette.accentSoft) : null,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Stack(
                            clipBehavior: Clip.none,
                            children: [
                              DailyIcon(icon, size: 18, color: ink),
                              if (hint != null)
                                Positioned(
                                  right: -5,
                                  top: 0,
                                  child: _liveDot(6, AppPalette.performText),
                                ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(label, style: _txt(12, on ? 600 : 500, ink)),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/* ---------------- 今日 ---------------- */

class _TodayPage extends StatelessWidget {
  final DateTime today;
  final double monthKm;
  final int monthRuns;
  final double totalKm;
  final double targetKm;
  final double todayKm;
  final String startStatus;
  final VoidCallback? onRun;
  final VoidCallback onEditTarget;

  const _TodayPage({
    required this.today,
    required this.monthKm,
    required this.monthRuns,
    required this.totalKm,
    required this.targetKm,
    required this.todayKm,
    required this.startStatus,
    required this.onRun,
    required this.onEditTarget,
  });

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (_, box) {
        final narrow = box.maxWidth <= 325;
        final short = box.maxHeight <= 600;
        final pad = narrow ? 16.0 : 20.0;
        final gap = short ? 12.0 : 16.0;
        final ring = short ? 176.0 : 226.0;
        return ColoredBox(
          color: _c(AppPalette.sand2),
          child: SingleChildScrollView(
            padding: EdgeInsets.all(pad),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: math.max(0.0, box.maxHeight - pad * 2),
              ),
              child: IntrinsicHeight(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text('今日', style: _txt(26, 700, _c(AppPalette.sand12))),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(_dateCn(today),
                              textAlign: TextAlign.end,
                              style: _txt(12, 500, _c(AppPalette.sand11))),
                        ),
                      ],
                    ),
                    SizedBox(height: gap),
                    _targetCard(targetKm, onEditTarget, todayKm: todayKm),
                    SizedBox(height: gap),
                    Expanded(
                      child: ConstrainedBox(
                        constraints:
                            BoxConstraints(minHeight: ring + (short ? 36 : 54)),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            _StartButton(
                              onTap: onRun,
                              size: ring,
                              label: startStatus.isEmpty ? '开始跑步' : startStatus,
                            ),
                            Positioned.fill(
                              child: IgnorePointer(
                                child: Center(
                                  child: Transform.translate(
                                    offset: Offset(0, ring / 2 + 11),
                                    child: Semantics(
                                      liveRegion: true,
                                      child: Text(
                                        startStatus,
                                        textAlign: TextAlign.center,
                                        style: _txt(
                                            12, 500, _c(AppPalette.sand11)),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: gap),
                    DecoratedBox(
                      decoration: _overviewCardDecoration(),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: IntrinsicHeight(
                          child: Row(
                            children: [
                              _overviewMetric('本月里程', _overviewKmLabel(monthKm),
                                  'km', narrow,
                                  emphasis: true),
                              const VerticalDivider(
                                  width: 1,
                                  thickness: 1,
                                  color: Color(AppPalette.sand6)),
                              _overviewMetric(
                                  '本月次数', '$monthRuns', '次', narrow),
                              const VerticalDivider(
                                  width: 1,
                                  thickness: 1,
                                  color: Color(AppPalette.sand6)),
                              _overviewMetric('累计里程', _overviewKmLabel(totalKm),
                                  'km', narrow),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      });
}

String _overviewKmLabel(double value) =>
    value.toStringAsFixed(1).replaceAllMapped(
          RegExp(r'\B(?=(\d{3})+(?!\d))'),
          (_) => ',',
        );

BoxDecoration _overviewCardDecoration() => BoxDecoration(
      color: _c(AppPalette.sand1),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: _c(AppPalette.sand6)),
    );

Widget _overviewMetric(String label, String value, String unit, bool narrow,
        {bool emphasis = false}) =>
    Expanded(
      child: Column(
        children: [
          Text(label,
              textAlign: TextAlign.center,
              style: _txt(12, 500, _c(AppPalette.sand11))),
          const SizedBox(height: 3),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text.rich(
              TextSpan(
                text: value,
                style: _num(narrow ? 15 : 17, 600,
                    emphasis ? AppPalette.performText : AppPalette.sand12),
                children: [
                  TextSpan(
                      text: ' $unit',
                      style: const TextStyle(fontSize: 12, letterSpacing: 0)),
                ],
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );

/// 点整张卡修改目标，上下两行里程对齐。
Widget _targetCard(double targetKm, VoidCallback onEdit, {double? todayKm}) {
  final done = todayKm ?? 0;
  final ratio = targetKm <= 0 ? 0.0 : (done / targetKm).clamp(0.0, 1.0);
  final reached = ratio >= 1;
  return DecoratedBox(
    decoration: _overviewCardDecoration(),
    child: Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onEdit,
        customBorder:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        highlightColor: _c(AppPalette.sand3),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                      child: Text('今日目标',
                          style: _txt(15, 600, _c(AppPalette.sand12)))),
                  Flexible(
                      child: Text('${targetKm.toStringAsFixed(2)} km',
                          textAlign: TextAlign.end,
                          style: _num(15, 600, AppPalette.sand12))),
                  const SizedBox(width: 8),
                  const DailyIcon(DailyGlyph.edit,
                      size: 16, color: Color(AppPalette.sand11)),
                ],
              ),
              if (todayKm != null) ...[
                const SizedBox(height: 10),
                Semantics(
                  label: '今日目标进度',
                  value: '${(ratio * 100).round()}%',
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: ratio,
                      minHeight: 5,
                      backgroundColor: _c(AppPalette.sand3),
                      color: _c(
                          reached ? AppPalette.performText : AppPalette.accent),
                    ),
                  ),
                ),
                const SizedBox(height: 7),
                Padding(
                  padding: const EdgeInsets.only(right: 24),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(reached ? '已达目标' : '今日已跑',
                            style: _txt(
                                12,
                                reached ? 600 : 500,
                                _c(reached
                                    ? AppPalette.performText
                                    : AppPalette.sand11))),
                      ),
                      Flexible(
                          child: Text(
                              done == 0
                                  ? '0 km'
                                  : '${done.toStringAsFixed(2)} km',
                              textAlign: TextAlign.end,
                              style: _num(12, 500, AppPalette.sand11))),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
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
  final String? pace;
  final double? speedKmh;
  final _RunLocationStatus locationStatus;
  final int? heartRate;
  final bool paused;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final Future<void> Function() onFinish;
  final VoidCallback onResult;
  final VoidCallback? onCard;

  const _RunningPage({
    required this.session,
    required this.tracker,
    required this.points,
    required this.elapsed,
    required this.distance,
    required this.pace,
    required this.speedKmh,
    required this.locationStatus,
    required this.heartRate,
    required this.paused,
    required this.onStart,
    required this.onPause,
    required this.onFinish,
    required this.onResult,
    required this.onCard,
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
            : _live(context);
    return AnimatedSwitcher(
      duration: AppMotion.runTransition,
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

  Widget _idle() => Container(
        color: _c(AppPalette.sand2),
        child: LayoutBuilder(
          builder: (context, box) {
            final buttonSize = (box.maxHeight * .46).clamp(140.0, 226.0);
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Column(
                children: [
                  _header(_pageTitle('跑中'), _pageMeta('等待开跑')),
                  const SizedBox(height: 24),
                  Center(child: _StartButton(onTap: onStart, size: buttonSize)),
                  const SizedBox(height: 24),
                  const _StatBar(cells: [
                    _StatCell(
                        icon: DailyGlyph.route, label: '距离', value: '0.00 km'),
                    _StatCell(
                        icon: DailyGlyph.clock, label: '用时', value: '00:00'),
                    _StatCell(icon: DailyGlyph.pace, label: '配速', value: '—'),
                  ]),
                ],
              ),
            );
          },
        ),
      );

  Widget _live(BuildContext context) {
    final livePace = paceBuckets(points);
    final locationText = paused
        ? ''
        : switch (locationStatus) {
            _RunLocationStatus.acquiring => '正在定位',
            _RunLocationStatus.ready => '',
            _RunLocationStatus.weak => '定位信号弱',
          };
    final hasLocation = locationStatus == _RunLocationStatus.ready;
    final paceValue = hasLocation ? pace : null;
    final speed = hasLocation ? speedKmh : null;
    final statusInk = paused ? AppPalette.sand11 : AppPalette.performText;

    return LayoutBuilder(
      builder: (context, box) {
        final narrow = box.maxWidth <= 325;
        final compact =
            narrow || MediaQuery.textScalerOf(context).scale(13) >= 17;
        final padding = narrow ? 16.0 : 20.0;
        final gap = compact ? 12.0 : 16.0;
        final mapHeight = (compact ? box.maxHeight * .28 : box.maxHeight - 355)
            .clamp(104.0, compact ? 156.0 : 382.0);

        return ColoredBox(
          color: _c(AppPalette.sand2),
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(padding, gap, padding, gap),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Semantics(
                              liveRegion: true,
                              child: Row(
                                children: [
                                  _liveDot(7, statusInk),
                                  const SizedBox(width: 7),
                                  Flexible(
                                    child: Text(
                                      paused ? '已暂停' : '正在记录',
                                      maxLines: 1,
                                      style: _txt(12, 600, _c(statusInk)),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Expanded(
                            child: Semantics(
                              liveRegion: true,
                              child: Text(
                                locationText,
                                textAlign: TextAlign.end,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: _txt(12, 500, _c(AppPalette.sand11)),
                              ),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: gap),
                      Text('已用时间', style: _txt(12, 500, _c(AppPalette.sand11))),
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          _clock(elapsed),
                          style: _num(56, 700, AppPalette.sand12)
                              .copyWith(fontSize: 56),
                        ),
                      ),
                      SizedBox(height: gap),
                      Row(
                        children: [
                          Expanded(
                            child: _liveMetric(
                              '距离',
                              distance.toStringAsFixed(2),
                              'km',
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: _liveMetric(
                              '当前配速',
                              paceValue ?? '—',
                              paceValue == null ? '' : '/km',
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: gap),
                      SizedBox(
                        height: mapHeight,
                        child: Semantics(
                          image: true,
                          label: '跑步轨迹',
                          child: _LiveMap(points: points),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 16,
                        runSpacing: 4,
                        children: [
                          Text(
                            speed == null
                                ? '速度 —'
                                : '速度 ${speed.toStringAsFixed(1)} km/h',
                            style: _txt(12, 500, _c(AppPalette.sand11)),
                          ),
                          if (heartRate != null)
                            Text(
                              '心率 $heartRate 次/分',
                              style: _txt(12, 500, _c(AppPalette.sand11)),
                            ),
                        ],
                      ),
                      if (livePace.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _livePaceChart(livePace),
                      ],
                    ],
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(padding, 0, padding, 12),
                child: _liveControls(),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _liveMetric(String label, String value, String unit) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: _txt(12, 500, _c(AppPalette.sand11))),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text.rich(
              TextSpan(
                text: value,
                style: _num(28, 600, AppPalette.sand12).copyWith(fontSize: 28),
                children: [
                  if (unit.isNotEmpty)
                    TextSpan(
                      text: ' $unit',
                      style: _txt(12, 500, _c(AppPalette.sand11))
                          .copyWith(letterSpacing: 0),
                    ),
                ],
              ),
            ),
          ),
        ],
      );

  Widget _livePaceChart(List<double> values) {
    final recent =
        values.length > 8 ? values.sublist(values.length - 8) : values;
    final fastest = recent.reduce(math.min);
    final span = math.max(15.0, recent.reduce(math.max) - fastest);
    return Row(
      children: [
        Expanded(
          child: Text('每 500 米配速', style: _txt(12, 600, _c(AppPalette.sand11))),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Semantics(
            image: true,
            label: '最近 ${recent.length} 段配速',
            child: SizedBox(
              height: 28,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final pace in recent)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Container(
                          height: 8 + (pace - fastest) / span * 20,
                          decoration: BoxDecoration(
                            color: _c(AppPalette.performText)
                                .withValues(alpha: .7),
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _liveControls() {
    final shape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));
    final pauseStyle = FilledButton.styleFrom(
      minimumSize: const Size(0, 52),
      visualDensity: VisualDensity.standard,
      backgroundColor: _c(paused ? AppPalette.accent : AppPalette.sand1),
      foregroundColor: _c(paused ? AppPalette.sand1 : AppPalette.sand12),
      side: paused ? null : BorderSide(color: _c(AppPalette.sand6)),
      shape: shape,
    );
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            style: pauseStyle,
            onPressed: onPause,
            icon: DailyIcon(paused ? DailyGlyph.route : DailyGlyph.pause,
                size: 18),
            label: Text(paused ? '继续' : '暂停'),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 52),
              visualDensity: VisualDensity.standard,
              backgroundColor: _c(AppPalette.red3),
              foregroundColor: _c(AppPalette.red11),
              shape: shape,
            ),
            onPressed: onFinish,
            icon: const DailyIcon(DailyGlyph.finish, size: 18),
            label: const Text('结束'),
          ),
        ),
      ],
    );
  }

  Widget _result(WorkoutSession s) => LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(
                _pageTitle('跑步完成'),
                _iconLabel(DailyGlyph.check, '已保存',
                    color: AppPalette.performText, weight: 600),
              ),
              const SizedBox(height: 16),
              Text.rich(
                TextSpan(
                  text: (s.distanceMeters / 1000).toStringAsFixed(2),
                  style: _num(48, 650, AppPalette.sand12),
                  children: [
                    TextSpan(
                      text: ' km',
                      style: _txt(14, 500, _c(AppPalette.sand11)),
                    ),
                  ],
                ),
              ),
              _pageMeta('距离'),
              const SizedBox(height: 16),
              Semantics(
                label: '跑步轨迹',
                image: true,
                child: SizedBox(
                  height: (box.maxHeight - 304).clamp(132.0, 388.0),
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
              ),
              const SizedBox(height: 16),
              _StatBar(
                cells: [
                  _StatCell(
                      icon: DailyGlyph.clock,
                      label: '用时',
                      value: _clock(s.elapsed)),
                  _StatCell(
                      icon: DailyGlyph.pace,
                      label: '平均配速',
                      value: s.averagePaceLabel),
                  _StatCell(
                      icon: DailyGlyph.energy,
                      label: '估算消耗',
                      value: '${s.calories} kcal'),
                ],
              ),
              const SizedBox(height: 16),
              _Pill(
                label: '预览记录图',
                icon: DailyGlyph.share,
                filled: true,
                onTap: onCard,
              ),
              const SizedBox(height: 8),
              _Pill(
                label: '查看分段',
                icon: DailyGlyph.list,
                filled: false,
                onTap: onResult,
              ),
            ],
          ),
        ),
      );
}

/// 备份入口，明确告诉用户文件放在哪里，以及重装后的两种恢复方式。
class _BackupMenu extends StatelessWidget {
  final DateTime? lastSavedAt;

  const _BackupMenu({required this.lastSavedAt});

  @override
  Widget build(BuildContext context) => _dialogShell(
        context,
        title: '跑步数据备份',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '每次记录变化后，数据会写进 下载 / 每日跑步 / daily-run-backup.json。'
              '卸载 App 不会删除这个文件。重装后自动读取；若系统拒绝读取，'
              '点「从备份文件恢复」手动选中它即可。',
              style: _txt(12, 400, _c(AppPalette.sand11)),
            ),
            const SizedBox(height: 8),
            Text(
              lastSavedAt == null
                  ? '尚未写入备份'
                  : '上次备份 ${_dateCn(lastSavedAt!)} ${_clock(Duration(hours: lastSavedAt!.hour, minutes: lastSavedAt!.minute))}',
              style: _txt(12, 500, _c(AppPalette.perform)),
            ),
            const SizedBox(height: 18),
            _Pill(
                label: '立即备份',
                icon: DailyGlyph.download,
                filled: true,
                onTap: () => Navigator.pop(context, 'save')),
            const SizedBox(height: 8),
            _Pill(
                label: '从备份文件恢复',
                icon: DailyGlyph.restore,
                filled: false,
                onTap: () => Navigator.pop(context, 'restore')),
          ],
        ),
      );
}

/* ---------------- 记录 ---------------- */

class _HistoryPage extends StatelessWidget {
  final Repository repo;
  final DateTime today;
  final double monthKm;
  final ValueChanged<WorkoutSession> onSession;
  final ValueChanged<WorkoutSession> onDelete;
  final String? deletingId;
  final VoidCallback onBackup;

  const _HistoryPage({
    required this.repo,
    required this.today,
    required this.monthKm,
    required this.onSession,
    required this.onDelete,
    required this.deletingId,
    required this.onBackup,
  });

  @override
  Widget build(BuildContext context) {
    final sessions = List<WorkoutSession>.from(repo.sessions)
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
    final runDays = <int>{
      for (final s in sessions)
        if (s.startTime.year == today.year && s.startTime.month == today.month)
          s.startTime.day,
    };
    final narrow = MediaQuery.sizeOf(context).width <= 325;
    final inset = narrow ? 16.0 : 20.0;
    return ColoredBox(
      color: _c(AppPalette.sand2),
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 14, inset, 7),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('记录', style: _txt(26, 700, _c(AppPalette.sand12))),
                      TextButton(
                        onPressed: onBackup,
                        style: TextButton.styleFrom(
                          foregroundColor: _c(AppPalette.accentText),
                          minimumSize: const Size(48, 48),
                          visualDensity: VisualDensity.standard,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        child: const Text('备份'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  DecoratedBox(
                    decoration: _overviewCardDecoration(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: IntrinsicHeight(
                        child: Row(
                          children: [
                            _overviewMetric(
                                '本月里程', _overviewKmLabel(monthKm), 'km', narrow,
                                emphasis: true),
                            const VerticalDivider(
                              width: 1,
                              thickness: 1,
                              color: Color(AppPalette.sand6),
                            ),
                            _overviewMetric(
                                '跑步天数', '${runDays.length}', '天', narrow,
                                emphasis: true),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  DecoratedBox(
                    decoration: _overviewCardDecoration(),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(13, 12, 13, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Wrap(
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              Text('${today.month} 月月历',
                                  style: _txt(14, 600, _c(AppPalette.sand12))),
                              Text('圆点标记跑步日',
                                  style: _txt(12, 500, _c(AppPalette.sand11))),
                            ],
                          ),
                          const SizedBox(height: 6),
                          _MonthGrid(runDays: runDays, today: today),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('历史记录', style: _txt(14, 600, _c(AppPalette.sand12))),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 0, inset, 28),
            sliver: sessions.isEmpty
                ? SliverToBoxAdapter(child: _emptyState())
                : SliverList.builder(
                    itemCount: sessions.length,
                    itemBuilder: (_, i) {
                      final session = sessions[i];
                      return RepaintBoundary(
                        key: ValueKey(session.id),
                        child: _HistoryRow(
                          session: session,
                          removing: session.id == deletingId,
                          onTap: () => onSession(session),
                          onDelete: () => onDelete(session),
                        ),
                      );
                    },
                  ),
          ),
        ],
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
          child: Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: DecoratedBox(
              decoration: _overviewCardDecoration(),
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: onTap,
                  onLongPress: onDelete,
                  borderRadius: BorderRadius.circular(20),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 55),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 38,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: _c(AppPalette.sage3),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const DailyIcon(DailyGlyph.route,
                                size: 21, color: Color(AppPalette.accent)),
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${session.startTime.month}月${session.startTime.day}日',
                                  style: _txt(13, 500, _c(AppPalette.sand12)),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${_clock(session.elapsed)} / ${session.averagePaceLabel}',
                                  style: _num(12, 500, AppPalette.sand11),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text.rich(
                              TextSpan(
                                text: km.toStringAsFixed(2),
                                style: _num(16, 600, AppPalette.sand12),
                                children: const [
                                  TextSpan(
                                      text: ' km',
                                      style: TextStyle(fontSize: 12)),
                                ],
                              ),
                              textAlign: TextAlign.end,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MonthGrid extends StatelessWidget {
  final Set<int> runDays;
  final DateTime today;

  const _MonthGrid({required this.runDays, required this.today});

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
        const SizedBox(height: 3),
        for (final wk in weeks)
          Row(
            children: [
              for (final day in wk) Expanded(child: _cell(day)),
            ],
          ),
      ],
    );
  }

  Widget _cell(int? day) {
    if (day == null) return const SizedBox(height: 25);
    final done = runDays.contains(day);
    final isToday = day == today.day;
    return Semantics(
      label: '${today.month}月$day日${isToday ? '，今天' : ''}${done ? '，有跑步' : ''}',
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 25),
        decoration: isToday
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _c(AppPalette.accent)),
              )
            : null,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text('$day',
                  style: _num(11, done ? 700 : 500,
                      done ? AppPalette.performText : AppPalette.sand12)),
            ),
            if (done)
              Positioned(
                bottom: 2,
                child: _liveDot(3, AppPalette.performText),
              ),
          ],
        ),
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
                      color: _c(AppPalette.performEdge),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          width: AppRules.hairline,
                          color: _c(AppPalette.performEdge)),
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
  final screenH = MediaQuery.sizeOf(context).height;
  final maxH = screenH * 0.92;
  return Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 440, maxHeight: maxH),
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
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
                const SizedBox(height: 18),
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
        : widget.initialKm.toStringAsFixed(2),
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double? _value() {
    final v = double.tryParse(_controller.text.trim());
    if (v == null || !v.isFinite || v < 0.5 || v > 100) return null;
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
  Widget build(BuildContext context) => Align(
        alignment: Alignment.bottomCenter,
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                12, 12, 12, 12 + MediaQuery.viewInsetsOf(context).bottom),
            child: SingleChildScrollView(
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
                      Text('随时可以改，只用来对照今天的进度',
                          style: _txt(12, 500, _c(AppPalette.sand11))),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _controller,
                        autofocus: true,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
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
                                width: 1, color: _c(AppPalette.accent)),
                          ),
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 6),
                        Text(_error!,
                            style: _txt(12, 500, _c(AppPalette.red11))),
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
          ),
        ),
      );
}

class _ResultDialog extends StatelessWidget {
  final WorkoutSession session;
  final VoidCallback onSave;

  const _ResultDialog({required this.session, required this.onSave});

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
            const SizedBox(height: 18),
            SizedBox(
              height: MediaQuery.sizeOf(context).height < 700 ? 112 : 148,
              child: TerrainMap(points: session.points),
            ),
            const SizedBox(height: 18),
            _StatBar(
              card: false,
              cells: [
                _StatCell(
                    icon: DailyGlyph.pace,
                    label: '配速',
                    value: session.averagePaceLabel),
                _StatCell(
                    icon: DailyGlyph.energy,
                    label: '消耗',
                    value: '${session.calories}'),
                _StatCell(
                    icon: DailyGlyph.route,
                    label: '轨迹点',
                    value: '${session.points.length}'),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text('分段配速', style: _txt(14, 600, _c(AppPalette.sand12))),
                const Spacer(),
                Text('每公里', style: _txt(12, 500, _c(AppPalette.sand11))),
              ],
            ),
            const SizedBox(height: 14),
            _SplitBars(seconds: [for (final s in session.splits) s.seconds]),
            const SizedBox(height: 20),
            _Pill(
                label: '保存记录图',
                icon: DailyGlyph.share,
                filled: true,
                onTap: onSave),
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
        title: '${session.startTime.month}月${session.startTime.day}日 跑步',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: MediaQuery.sizeOf(context).height < 700 ? 112 : 148,
              child: TerrainMap(points: session.points),
            ),
            const SizedBox(height: 18),
            _StatBar(
              cells: [
                _StatCell(
                    icon: DailyGlyph.route,
                    label: '距离',
                    value:
                        '${(session.distanceMeters / 1000).toStringAsFixed(2)} km'),
                _StatCell(
                    icon: DailyGlyph.clock,
                    label: '用时',
                    value: _clock(session.elapsed)),
                _StatCell(
                    icon: DailyGlyph.pace,
                    label: '配速',
                    value: session.averagePaceLabel),
              ],
            ),
            const SizedBox(height: 14),
            _SplitBars(seconds: [for (final s in session.splits) s.seconds]),
            const SizedBox(height: 20),
            _Pill(
                label: '生成记录图',
                icon: DailyGlyph.share,
                filled: true,
                onTap: onCard),
            const SizedBox(height: 8),
            _Pill(
                label: '删除这条记录',
                icon: DailyGlyph.trash,
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
  final GallerySaver gallery;
  const _CardScreen({
    required this.session,
    required this.dateLabel,
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
          leading: IconButton(
            icon: const DailyIcon(DailyGlyph.back),
            tooltip: '返回',
            onPressed: () => Navigator.pop(context),
          ),
          title: Text('记录图预览', style: _txt(16, 600, _c(AppPalette.sand12))),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FittedBox(
                    child: RunShareCard(
                      session: widget.session,
                      dateLabel: widget.dateLabel,
                    ),
                  ),
                  if (_message != null) ...[
                    const SizedBox(height: 14),
                    Text(_message!,
                        style: _txt(12, 500, _c(AppPalette.sand11))),
                  ],
                  const SizedBox(height: 16),
                  _Pill(
                    label: _saving ? '正在生成图片' : '保存图片到手机',
                    icon: DailyGlyph.download,
                    filled: true,
                    onTap: _saving ? null : _save,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}
