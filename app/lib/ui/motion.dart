import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 全 App 的动效语言。分四类，不再到处自己写时长：
/// - press   按下与松手，最快，反复操作不拖沓
/// - quick   离场、收起、局部替换
/// - base    位置移动、页内状态切换
/// - enter   新内容出现
/// - settle  数字落定
///
/// 曲线只用两条：standard（减速，绝大多数）与 emphasized（更明显的减速，
/// 用于出现与位移）。系统开启「减少动态效果」时全部归零。
class AppMotion {
  static bool reduce = false;

  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Cubic(0.2, 0, 0, 1);

  static Duration get press =>
      reduce ? Duration.zero : const Duration(milliseconds: 120);
  static Duration get quick =>
      reduce ? Duration.zero : const Duration(milliseconds: 180);

  /// 标签切换：只做很短的淡入，不拖住点击后的第一眼反馈。
  static Duration get tab =>
      reduce ? Duration.zero : const Duration(milliseconds: 140);
  static Duration get base =>
      reduce ? Duration.zero : const Duration(milliseconds: 240);
  static Duration get enter =>
      reduce ? Duration.zero : const Duration(milliseconds: 320);
  static Duration get settle =>
      reduce ? Duration.zero : const Duration(milliseconds: 520);

  /// 动效开启时才播的循环装饰（呼吸点、启动图标）。
  static bool get decorative => !reduce;
}

/// 触觉反馈。设备不支持时直接忽略，不影响任何流程。
class Haptics {
  static Future<void> select() async {
    try {
      await HapticFeedback.selectionClick();
    } catch (_) {}
  }

  static Future<void> light() async {
    try {
      await HapticFeedback.lightImpact();
    } catch (_) {}
  }

  static Future<void> medium() async {
    try {
      await HapticFeedback.mediumImpact();
    } catch (_) {}
  }

  static Future<void> heavy() async {
    try {
      await HapticFeedback.heavyImpact();
    } catch (_) {}
  }
}

enum AppSound { start, finish, tap }

/// 三个短音效：开跑、完成、点按。全部预加载，播完即停。
/// 跟随系统静音，与其他 App 的声音混播而不是抢占。
class SoundService {
  SoundService._();

  static final SoundService instance = SoundService._();

  final Map<AppSound, AudioPlayer> _players = <AppSound, AudioPlayer>{};
  bool enabled = true;
  bool _ready = false;

  static const Map<AppSound, String> _assets = <AppSound, String>{
    AppSound.start: 'audio/start.wav',
    AppSound.finish: 'audio/finish.wav',
    AppSound.tap: 'audio/tap.wav',
  };

  Future<void> init() async {
    if (_ready) return;
    try {
      await AudioPlayer.global.setAudioContext(
        AudioContextConfig(
          focus: AudioContextConfigFocus.mixWithOthers,
          respectSilence: true,
        ).build(),
      );
      for (final entry in _assets.entries) {
        final player = AudioPlayer(playerId: 'daily-run-${entry.key.name}');
        await player.setReleaseMode(ReleaseMode.stop);
        await player.setSource(AssetSource(entry.value));
        _players[entry.key] = player;
      }
      _ready = true;
    } catch (_) {
      // 音频不可用就静默降级，界面与记录不受影响。
    }
  }

  Future<void> play(AppSound sound, {double volume = 1}) async {
    if (!enabled) return;
    final player = _players[sound];
    if (player == null) return;
    try {
      await player.stop();
      await player.setVolume(volume);
      await player.resume();
    } catch (_) {}
  }

  Future<void> dispose() async {
    for (final player in _players.values) {
      try {
        await player.dispose();
      } catch (_) {}
    }
    _players.clear();
    _ready = false;
  }
}

/// 可点击容器的统一按压反馈：按下缩到 0.97，抬起回弹；
/// 有鼠标时再叠一层很淡的底色，让「可以点」这件事在悬停时就成立。
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final bool haptic;
  final double scale;

  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.haptic = true,
    this.scale = 0.97,
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;
  bool _hover = false;

  void _setDown(bool value) {
    if (widget.onTap == null) return;
    if (_down != value) setState(() => _down = value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) {
        if (enabled) setState(() => _hover = true);
      },
      onExit: (_) {
        if (_hover) setState(() => _hover = false);
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setDown(true),
        onTapUp: (_) => _setDown(false),
        onTapCancel: () => _setDown(false),
        onTap: enabled
            ? () {
                if (widget.haptic) Haptics.select();
                widget.onTap!();
              }
            : null,
        child: AnimatedScale(
          scale: _down ? widget.scale : 1,
          duration: AppMotion.press,
          curve: AppMotion.standard,
          child: AnimatedOpacity(
            opacity: _hover && !_down ? 0.92 : 1,
            duration: AppMotion.press,
            curve: AppMotion.standard,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// 全 App 的浮层入口：淡入加 0.96 → 1 的轻微放大。
Future<T?> showAppDialog<T>(BuildContext context, WidgetBuilder builder) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭',
    barrierColor: const Color(0x471F211F),
    transitionDuration: AppMotion.base,
    pageBuilder: (context, animation, secondary) => builder(context),
    transitionBuilder: (context, animation, secondary, child) {
      final curved =
          CurvedAnimation(parent: animation, curve: AppMotion.emphasized);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// 数字变化时从当前显示值滚到新值，被打断也从半路接上。
/// 首次出现不滚（避免每次进页面都从 0 数一遍）。
class RollingNumber extends StatefulWidget {
  final double value;
  final String Function(double value) format;
  final TextStyle style;
  final Duration? duration;

  const RollingNumber({
    super.key,
    required this.value,
    required this.format,
    required this.style,
    this.duration,
  });

  @override
  State<RollingNumber> createState() => _RollingNumberState();
}

class _RollingNumberState extends State<RollingNumber>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration ?? AppMotion.settle,
  )..value = 1;
  late double _from = widget.value;
  late double _to = widget.value;

  @override
  void didUpdateWidget(RollingNumber old) {
    super.didUpdateWidget(old);
    if (widget.value == _to) return;
    _from = _current;
    _to = widget.value;
    if (AppMotion.reduce) {
      _controller.value = 1;
    } else {
      _controller.forward(from: 0);
    }
  }

  double get _current {
    final t = AppMotion.emphasized.transform(_controller.value);
    return _from + (_to - _from) * t;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _controller,
        builder: (context, child) =>
            Text(widget.format(_current), style: widget.style),
      );
}
