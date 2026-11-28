import 'package:flutter/foundation.dart';

import 'audio_route_monitor.dart';

/// 播放请求的来源。
///
/// 闸门（[PlaybackGuard.decide]）依据来源与当前安全状态决定是否放行：
/// - [userTap]：用户在 App 内/通知栏的显式操作（点击播放、选歌）。
/// - [systemMedia]：系统媒体会话转发的播放请求（耳机按键、车机 AVRCP、
///   Android Auto、锁屏/通知栏由系统下发的 PLAY）。
/// - [automatic]:应用自身的自动播放（打断结束恢复、连接设备自动播放、
///   开机恢复上次播放列表、歌曲播完自动切下一首）。
/// - [externalLink]：外部唤起的播放（kgka:// 深链、第三方 App 调起）。
enum PlayOrigin { userTap, systemMedia, automatic, externalLink }

/// 暂停的原因。
///
/// 「为什么暂停」决定了「之后能不能自动恢复」：
/// - [user]：用户主动暂停。绝不允许任何自动恢复接管。
/// - [interruption]：音频焦点被打断（来电、其他 App 抢占）。焦点归还后
///   且中断前正在播放时可恢复。
/// - [disconnect]：耳机/蓝牙断开（becomingNoisy / 设备移除兜底）。等待
///   路由回到外部设备（routeReady）后才可恢复——绝不直接从扬声器续播。
/// - [completion]：歌曲自然播完（含睡眠定时播完当曲暂停）。
enum PauseCause { user, interruption, disconnect, completion }

/// 音频焦点占用的阶段。
enum InterruptionPhase {
  /// 未被占用。
  none,

  /// 正在被其他音频压低（duck），音乐继续。
  ducked,

  /// 被临时打断（来电、瞬时焦点丢失），结束后可恢复。
  transient,

  /// 焦点被永久抢占（AUDIOFOCUS_LOSS）。任何非用户播放一律拒绝，
  /// 直到用户显式播放（此时会重新申请焦点）或焦点重新归还。
  permanent,
}

/// 播放闸门的裁决。
enum PlayDecision {
  /// 放行。
  allow,

  /// 挂起：当前条件不满足（多为路由未就绪），等待路由/焦点事件后
  /// 由调用方重新发起同一来源的播放。
  defer,

  /// 拒绝：此来源在当前状态下不允许播放，等待事件也不会改变结论。
  deny,
}

/// 播放安全感量的单点决策核心。
///
/// 所有状态写入只应来自三类入口：
/// 1. [recordInterruptionBegin]/[recordInterruptionEnd]（音频焦点事件）；
/// 2. [recordPause]（主动记录暂停原因与当时路由）；
/// 3. [recordUserPlay]/[recordRouteReady]（安全上下文重新建立）。
///
/// 播放判断只经 [decide]。不再由散落各处的布尔组合表达。
///
/// 判断原则（对应审计 B1–B7）：
/// - I1 自动播放必须路由与暂停前一致，否则 defer 等待路由回连；
/// - I2 只连通话通道的蓝牙（hasCallOnlyBluetooth）是疑似外放态，
///      非用户来源一律 deny；
/// - I3 只有用户显式操作（userTap）可越过路由限制；
/// - I4 焦点占用只能 defer/deny 非用户来源，绝不阻止用户播放
///      （修复 B1「点了没反应」的粘滞死锁）；
/// - 路由未知（不支持 audio_session 的平台）时不做路由拦截，
///      沿用旧平台行为，仅保留焦点与暂停原因约束。
class PlaybackGuard extends ChangeNotifier {
  InterruptionPhase _focus = InterruptionPhase.none;
  PauseCause? _lastPause;
  AudioRouteSnapshot? _routeAtPause;
  bool _resumeAfterInterruption = false;

  /// 当前焦点占用阶段。
  InterruptionPhase get focus => _focus;

  /// 最近一次暂停的原因（null 表示从未暂停或已被用户播放清除）。
  PauseCause? get lastPause => _lastPause;

  /// 最近一次暂停发生时的路由快照。用于 I1 路由一致性判断。
  AudioRouteSnapshot? get routeAtPause => _routeAtPause;

  /// 打断开始前是否正在播放（含正在启动的播放意图）。
  /// 打断结束后仅在该值为 true 时恢复。
  bool get resumeAfterInterruption => _resumeAfterInterruption;

  /// 记录音频焦点被打断。
  ///
  /// [wasPlaying]：打断开始时是否正在播放（或播放请求进行中），
  /// 决定焦点归还后是否自动恢复。
  void recordInterruptionBegin(
    InterruptionPhase phase, {
    required bool wasPlaying,
    required AudioRouteSnapshot currentRoute,
  }) {
    final previous = _focus;
    _focus = phase;
    // 打断前已在播放：记录「因打断而暂停」，并保存此刻的路由，
    // 供恢复时做 I1 一致性检查。
    if (phase != InterruptionPhase.ducked && phase != InterruptionPhase.none) {
      if (wasPlaying && _lastPause == null) {
        _lastPause = PauseCause.interruption;
        _routeAtPause = currentRoute;
      }
      _resumeAfterInterruption = wasPlaying && _lastPause == PauseCause.interruption;
    }
    if (previous != _focus) notifyListeners();
  }

  /// 记录音频焦点归还/打断结束。
  ///
  /// [permanentLossResolved]：本次结束是否解除了永久焦点丢失
  /// （Android 上重新申请焦点成功后 gain 会以 pause-end 事件到达）。
  void recordInterruptionEnd({bool permanentLossResolved = false}) {
    final previous = _focus;
    _focus = InterruptionPhase.none;
    if (permanentLossResolved || previous == InterruptionPhase.permanent) {
      // 焦点拿回来了：打断导致的暂停不再由焦点原因挂起。
      // 路由一致性仍由 decide 的 I1 检查把守。
      if (_lastPause == PauseCause.interruption) {
        _resumeAfterInterruption = true;
      }
    }
    if (previous != InterruptionPhase.none) notifyListeners();
  }

  /// 用户显式播放：清除「用户暂停/断连暂停」的挂起状态（I3/I4）。
  ///
  /// 注意不清除焦点占用——焦点是否可用由重新申请焦点的结果决定；
  /// 焦点阶段在 [recordUserPlay] 后由调用方配合 setActive(true)，
  /// 收到 gain 后经 [recordInterruptionEnd] 清除。若平台不回调 gain，
  /// 调用方可在申请成功后手动置 [clearFocus]。
  /// 用户显式播放入口的安全清理（I3/I4）。
  ///
  /// 只清除「用户暂停」与「断连暂停」两类挂起（需要解锁的状态）。
  /// 打断恢复资格（interruption）保留：来电中用户点歌的表达的意图
  /// 由焦点归还后的恢复流程接管，否则用户点歌会被否。
  ///
  /// 焦点阶段不在此时清除：permanent 丢失由用户播放重新申请焦点解决，
  /// transient 期间用户播放会被 defer 到焦点归还（见 [decide]）。
  void recordUserPlay() {
    if (_lastPause == PauseCause.user || _lastPause == PauseCause.disconnect) {
      _lastPause = null;
      _routeAtPause = null;
      notifyListeners();
    }
  }

  /// 主动清除焦点阶段（用户显式播放且已重新申请焦点成功时使用）。
  void clearFocus() {
    if (_focus != InterruptionPhase.none) {
      _focus = InterruptionPhase.none;
      notifyListeners();
    }
  }

  /// 记录一次暂停及其原因与当时路由。
  ///
  /// 用户主动暂停覆盖一切原因（阻断此后所有自动恢复）；
  /// 断连暂停保存路由快照供 routeReady 后的一致性恢复；
  /// 打断暂停仅在当前无更具体原因时记录。
  void recordPause(PauseCause cause, AudioRouteSnapshot currentRoute) {
    if (cause == PauseCause.user) {
      // 真机实测（PR#1 验收）：MIUI/AVRCP 在蓝牙断开时会给
      // MediaSession 补发一条 pause 命令，经 handler 默认参数被
      // 当成「用户暂停」——若据此改写归因，断连保护立即失效，
      // 随后的媒体键 PLAY 被放行到扬声器外放。
      // 断连挂起一经建立，只有用户显式播放（recordUserPlay）
      // 可以解除，系统转发的暂停命令不得覆盖。
      if (_lastPause == PauseCause.disconnect) {
        debugPrint(
          '[KA Music][gate] user pause ignored (disconnect hold active)',
        );
        return;
      }
      _resumeAfterInterruption = false;
      _lastPause = cause;
      _routeAtPause = currentRoute;
      notifyListeners();
      return;
    }
    // 已有用户暂停，绝不允许后续系统事件改写为可自动恢复的原因。
    if (_lastPause == PauseCause.user) return;
    if (cause == PauseCause.disconnect) {
      final previousPause = _lastPause;
      _resumeAfterInterruption = false;
      _lastPause = cause;
      // 通话中耳机断开：保留打断开始时的路由快照（耳机上），
      // 它是「通话结束+耳机回连后恢复」的判断依据（B4），
      // 不能被断连时刻的（已失去外部输出的）快照覆盖。
      final preserveInterruptionRoute =
          previousPause == PauseCause.interruption &&
          _routeAtPause?.known == true &&
          _routeAtPause!.hasExternalOutput;
      if (!preserveInterruptionRoute) {
        _routeAtPause = currentRoute;
      }
      notifyListeners();
      return;
    }
    if (_lastPause == null) {
      _lastPause = cause;
      _routeAtPause = currentRoute;
      notifyListeners();
    }
  }

  /// 外部设备回连（旧 devices 分支）时解除「断连暂停」挂起。
  ///
  /// 与 [recordRouteReady] 的区别：本方法不判断路由一致性，
  /// 由调用方在设备事件语义下使用（设备已重新出现即视为安全上下文重建）。
  void resolveDisconnectHold() {
    if (_lastPause == PauseCause.disconnect) {
      _lastPause = null;
      _routeAtPause = null;
      notifyListeners();
    }
  }

  /// 外部输出路由重新确认可用（设备回连/插入）。
  ///
  /// 返回是否产生了「可自动恢复」的唤醒信号：
  /// - 断连暂停：路由回来了，解除挂起（配合 autoResumeAfterInterruption
  ///   决定是否真的恢复）；
  /// - B4 场景：打断结束后的自动恢复因「路由尚未回到耳机」被 defer，
  ///   现在路由恢复——唤醒该次被推迟的恢复。
  bool recordRouteReady(AudioRouteSnapshot snapshot) {
    switch (_lastPause) {
      case PauseCause.disconnect:
        final atPause = _routeAtPause;
        if (atPause == null ||
            !atPause.known ||
            !snapshot.known ||
            atPause.hasExternalOutput == snapshot.hasExternalOutput ||
            snapshot.hasExternalOutput) {
          _resumeAfterInterruption = true;
          return true;
        }
        return false;
      case PauseCause.interruption:
        // B4：恢复被推迟（通话结束时路由未回耳机），现在路由回来了。
        final atPause = _routeAtPause;
        if (atPause != null &&
            atPause.known &&
            atPause.hasExternalOutput &&
            snapshot.hasExternalOutput) {
          _resumeAfterInterruption = true;
          return true;
        }
        return false;
      case null:
      case PauseCause.user:
      case PauseCause.completion:
        return false;
    }
  }

  /// 播放闸门：给定来源与当前路由，裁决是否允许出声。
  ///
  /// 这是全应用唯一判断「现在能不能播放」的函数（I5）。
  PlayDecision decide(PlayOrigin origin, AudioRouteSnapshot route) {
    final decision = _decide(origin, route);
    debugPrint(
      '[KA Music][gate] decide(${origin.name}, ${route.short}) '
      '-> ${decision.name} (focus=$_focus, lastPause=$_lastPause)',
    );
    return decision;
  }

  PlayDecision _decide(PlayOrigin origin, AudioRouteSnapshot route) {
    if (origin == PlayOrigin.userTap) {
      // I3/I4：用户的显式操作不因路由/断连被拦（那些挂起已在
      // recordUserPlay 中清除）。但来电等瞬时打断（transient）下
      // 强行起播会被系统立即再次暂停，推迟到焦点归还更可靠；
      // permanent 丢失没有 end 事件，若 defer 会重现 B1 死锁，
      // 因此允许：由用户播放重新申请焦点（setActive）解锁。
      // ducked 只压低音量，不阻止用户播放。
      if (_focus == InterruptionPhase.transient) {
        return PlayDecision.defer;
      }
      return PlayDecision.allow;
    }

    // I4：焦点占用只影响非用户来源。
    switch (_focus) {
      case InterruptionPhase.none:
        break;
      case InterruptionPhase.ducked:
      case InterruptionPhase.transient:
        return PlayDecision.defer;
      case InterruptionPhase.permanent:
        return PlayDecision.deny;
    }

    // 断连暂停：等待外部路由回来（routeReady），绝不从扬声器续播。
    if (_lastPause == PauseCause.disconnect) {
      if (route.known && !route.hasExternalOutput) {
        return PlayDecision.defer;
      }
      if (!route.known) {
        // 无路由信息的平台：与旧行为一致，保持挂起直到用户操作。
        return PlayDecision.defer;
      }
    }

    // 用户暂停后：automatic 不得恢复（I1 之外的最基本原则）。
    if (_lastPause == PauseCause.user && origin == PlayOrigin.automatic) {
      return PlayDecision.defer;
    }

    if (route.known) {
      // 疑似外放态：通话通道占用的蓝牙（车机/耳机只连 HFP），
      // 媒体必然走手机扬声器——非用户来源一律拒绝（B3/B5）。
      if (route.isAmbiguous) {
        return PlayDecision.deny;
      }
      // I1：automatic 恢复/自动播放必须与暂停前路由一致
      // （或暂停前就没有外部输出，即用户本来就在外放听歌）。
      if (origin == PlayOrigin.automatic && !route.hasExternalOutput) {
        final atPause = _routeAtPause;
        if (atPause != null &&
            atPause.known &&
            atPause.hasExternalOutput) {
          return PlayDecision.defer;
        }
      }
    }

    return PlayDecision.allow;
  }

  /// 日志友好的状态摘要。
  @override
  String toString() =>
      'PlaybackGuard(focus:$_focus, lastPause:$_lastPause, '
      'routeAtPause:${_routeAtPause?.short}, resume:$_resumeAfterInterruption)';
}
