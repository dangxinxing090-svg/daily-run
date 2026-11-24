import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 全 App 的动效节奏，四档够用：按下、切页、强调、结果计数。
class AppMotion {
  static const Duration fast = Duration(milliseconds: 140);
  static const Duration base = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 320);
  static const Duration result = Duration(milliseconds: 620);
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

/// 可点击容器的统一按压反馈：按下缩到 0.97，抬手回弹。
/// 卡片、列表行、按钮都用它，保证全 App 手感一致。
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

  void _setDown(bool value) {
    if (widget.onTap == null) return;
    if (_down != value) setState(() => _down = value);
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _setDown(true),
        onTapUp: (_) => _setDown(false),
        onTapCancel: () => _setDown(false),
        onTap: widget.onTap == null
            ? null
            : () {
                if (widget.haptic) Haptics.select();
                widget.onTap!();
              },
        child: AnimatedScale(
          scale: _down ? widget.scale : 1,
          duration: AppMotion.fast,
          curve: Curves.easeOut,
          child: widget.child,
        ),
      );
}

/// 全 App 的浮层入口：淡入加 0.96 → 1 的轻微放大，比默认弹窗更贴手。
Future<T?> showAppDialog<T>(BuildContext context, WidgetBuilder builder) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭',
    barrierColor: const Color(0x471F211F),
    transitionDuration: AppMotion.base,
    pageBuilder: (context, animation, secondary) => builder(context),
    transitionBuilder: (context, animation, secondary, child) {
      final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
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
