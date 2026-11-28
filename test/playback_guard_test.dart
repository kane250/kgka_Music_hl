import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/services/audio_route_monitor.dart';
import 'package:kgka_music_hl/services/playback_guard.dart';

const _speaker = AudioRouteSnapshot(
  known: true,
  hasExternalOutput: false,
  hasCallOnlyBluetooth: false,
);

const _bluetooth = AudioRouteSnapshot(
  known: true,
  hasExternalOutput: true,
  hasCallOnlyBluetooth: false,
  externalDeviceIds: {'bt-1'},
);

/// 只连通话通道（SCO/HFP）的蓝牙：媒体必然走手机扬声器。
const _callOnlyBluetooth = AudioRouteSnapshot(
  known: true,
  hasExternalOutput: false,
  hasCallOnlyBluetooth: true,
);

const _unknown = AudioRouteSnapshot.unknown();

void main() {
  group('decide: I3/I4 用户显式播放不被静默吞掉', () {
    test('焦点被永久抢占时 userTap 仍放行（B1 死锁修复）', () {
      final guard = PlaybackGuard();
      guard.recordInterruptionBegin(
        InterruptionPhase.permanent,
        wasPlaying: true,
        currentRoute: _bluetooth,
      );
      expect(guard.decide(PlayOrigin.userTap, _speaker), PlayDecision.allow);
    });

    test('来电（transient）中 userTap 推迟到焦点归还，不强行起播', () {
      final guard = PlaybackGuard();
      guard.recordInterruptionBegin(
        InterruptionPhase.transient,
        wasPlaying: true,
        currentRoute: _bluetooth,
      );
      expect(guard.decide(PlayOrigin.userTap, _bluetooth), PlayDecision.defer);
    });

    test('duck 只压音量不拦用户播放', () {
      final guard = PlaybackGuard();
      guard.recordInterruptionBegin(
        InterruptionPhase.ducked,
        wasPlaying: true,
        currentRoute: _bluetooth,
      );
      expect(guard.decide(PlayOrigin.userTap, _bluetooth), PlayDecision.allow);
    });

    test('断连暂停后 userTap 仍放行', () {
      final guard = PlaybackGuard();
      guard.recordPause(PauseCause.disconnect, _bluetooth);
      expect(guard.decide(PlayOrigin.userTap, _speaker), PlayDecision.allow);
    });
  });

  group('decide: 焦点约束（I4，只约束非用户来源）', () {
    test('永久焦点丢失：systemMedia/automatic 一律 deny', () {
      final guard = PlaybackGuard();
      guard.recordInterruptionBegin(
        InterruptionPhase.permanent,
        wasPlaying: true,
        currentRoute: _bluetooth,
      );
      expect(
        guard.decide(PlayOrigin.systemMedia, _bluetooth),
        PlayDecision.deny,
      );
      expect(
        guard.decide(PlayOrigin.automatic, _bluetooth),
        PlayDecision.deny,
      );
    });

    test('临时打断/duck：非用户来源 defer', () {
      final guard = PlaybackGuard();
      guard.recordInterruptionBegin(
        InterruptionPhase.transient,
        wasPlaying: true,
        currentRoute: _bluetooth,
      );
      expect(
        guard.decide(PlayOrigin.automatic, _bluetooth),
        PlayDecision.defer,
      );
      guard.recordInterruptionEnd();
      guard.recordInterruptionBegin(
        InterruptionPhase.ducked,
        wasPlaying: true,
        currentRoute: _bluetooth,
      );
      expect(
        guard.decide(PlayOrigin.automatic, _bluetooth),
        PlayDecision.defer,
      );
    });

    test('焦点归还后解除 deny', () {
      final guard = PlaybackGuard();
      guard.recordInterruptionBegin(
        InterruptionPhase.permanent,
        wasPlaying: true,
        currentRoute: _bluetooth,
      );
      guard.recordInterruptionEnd(permanentLossResolved: true);
      expect(
        guard.decide(PlayOrigin.systemMedia, _bluetooth),
        PlayDecision.allow,
      );
    });
  });

  group('decide: 断连暂停 fail-closed（B2/B6）', () {
    test('断连暂停后路由落回扬声器：automatic defer', () {
      final guard = PlaybackGuard();
      guard.recordPause(PauseCause.disconnect, _bluetooth);
      expect(
        guard.decide(PlayOrigin.automatic, _speaker),
        PlayDecision.defer,
      );
    });

    test('断连暂停后外部设备回连：automatic allow', () {
      final guard = PlaybackGuard();
      guard.recordPause(PauseCause.disconnect, _bluetooth);
      expect(
        guard.decide(PlayOrigin.automatic, _bluetooth),
        PlayDecision.allow,
      );
    });

    test('无路由信息平台：断连后 automatic 保持挂起', () {
      final guard = PlaybackGuard();
      guard.recordPause(PauseCause.disconnect, _unknown);
      expect(
        guard.decide(PlayOrigin.automatic, _unknown),
        PlayDecision.defer,
      );
    });
  });

  group('decide: 用户暂停不被自动恢复（I1 前提）', () {
    test('用户暂停后 automatic defer，systemMedia/externalLink 放行', () {
      final guard = PlaybackGuard();
      guard.recordPause(PauseCause.user, _speaker);
      expect(
        guard.decide(PlayOrigin.automatic, _speaker),
        PlayDecision.defer,
      );
      expect(
        guard.decide(PlayOrigin.systemMedia, _speaker),
        PlayDecision.allow,
      );
      expect(
        guard.decide(PlayOrigin.externalLink, _speaker),
        PlayDecision.allow,
      );
    });

    test('用户暂停后，后续系统事件不得改写为可恢复原因', () {
      final guard = PlaybackGuard();
      guard.recordPause(PauseCause.user, _speaker);
      // 断连事件发生在用户已暂停之后：不得解锁自动恢复。
      guard.recordPause(PauseCause.disconnect, _speaker);
      expect(
        guard.decide(PlayOrigin.automatic, _speaker),
        PlayDecision.defer,
      );
    });
  });

  group('decide: 疑似外放态（B3/B5）', () {
    test('只连通话通道的蓝牙：非用户来源一律 deny', () {
      final guard = PlaybackGuard();
      expect(
        guard.decide(PlayOrigin.systemMedia, _callOnlyBluetooth),
        PlayDecision.deny,
      );
      expect(
        guard.decide(PlayOrigin.automatic, _callOnlyBluetooth),
        PlayDecision.deny,
      );
      expect(
        guard.decide(PlayOrigin.externalLink, _callOnlyBluetooth),
        PlayDecision.deny,
      );
      expect(
        guard.decide(PlayOrigin.userTap, _callOnlyBluetooth),
        PlayDecision.allow,
      );
    });

    test('automatic 路由一致性：暂停前在扬声器上则允许扬声器恢复', () {
      final guard = PlaybackGuard();
      // 用户本来就用手机扬声器外放听歌，通话结束后允许原位恢复。
      guard.recordPause(PauseCause.interruption, _speaker);
      guard.recordInterruptionEnd();
      expect(
        guard.decide(PlayOrigin.automatic, _speaker),
        PlayDecision.allow,
      );
    });

    test('automatic 路由一致性：暂停前在蓝牙上则不得从扬声器恢复（B4/B6）', () {
      final guard = PlaybackGuard();
      guard.recordPause(PauseCause.interruption, _bluetooth);
      guard.recordInterruptionEnd();
      expect(
        guard.decide(PlayOrigin.automatic, _speaker),
        PlayDecision.defer,
      );
      // 蓝牙回连后允许恢复。
      expect(
        guard.decide(PlayOrigin.automatic, _bluetooth),
        PlayDecision.allow,
      );
    });

    test('无路由信息平台不做路由拦截', () {
      final guard = PlaybackGuard();
      guard.recordInterruptionBegin(
        InterruptionPhase.transient,
        wasPlaying: true,
        currentRoute: _unknown,
      );
      guard.recordInterruptionEnd();
      expect(
        guard.decide(PlayOrigin.automatic, _unknown),
        PlayDecision.allow,
      );
      expect(
        guard.decide(PlayOrigin.systemMedia, _unknown),
        PlayDecision.allow,
      );
    });
  });

  group('打断恢复资格', () {
    test('打断开始时在播：结束后获得恢复资格', () {
      final guard = PlaybackGuard();
      guard.recordInterruptionBegin(
        InterruptionPhase.transient,
        wasPlaying: true,
        currentRoute: _bluetooth,
      );
      expect(guard.resumeAfterInterruption, isTrue);
      guard.recordInterruptionEnd();
      expect(guard.resumeAfterInterruption, isTrue);
      expect(guard.lastPause, PauseCause.interruption);
    });

    test('打断开始时已被用户暂停：结束后不得恢复（B1 场景）', () {
      final guard = PlaybackGuard();
      guard.recordPause(PauseCause.user, _bluetooth);
      guard.recordInterruptionBegin(
        InterruptionPhase.transient,
        wasPlaying: false,
        currentRoute: _bluetooth,
      );
      guard.recordInterruptionEnd();
      expect(guard.resumeAfterInterruption, isFalse);
      expect(guard.decide(PlayOrigin.automatic, _bluetooth), PlayDecision.defer);
    });
  });

  group('recordRouteReady', () {
    test('断连暂停后路由回连解除挂起', () {
      final guard = PlaybackGuard();
      guard.recordPause(PauseCause.disconnect, _bluetooth);
      expect(guard.recordRouteReady(_bluetooth), isTrue);
      expect(guard.decide(PlayOrigin.automatic, _bluetooth), PlayDecision.allow);
    });

    test('非断连暂停不受 routeReady 影响', () {
      final guard = PlaybackGuard();
      guard.recordPause(PauseCause.user, _speaker);
      expect(guard.recordRouteReady(_bluetooth), isFalse);
    });
  });

  group('recordUserPlay', () {
    test('清除用户/断连暂停状态（但不清除打断恢复资格）', () {
      final guard = PlaybackGuard();
      guard.recordPause(PauseCause.disconnect, _bluetooth);
      guard.recordUserPlay();
      expect(guard.lastPause, isNull);
      expect(guard.decide(PlayOrigin.automatic, _bluetooth), PlayDecision.allow);
    });

    test('来电中用户点歌：打断恢复资格保留，焦点归还后可接管意图', () {
      final guard = PlaybackGuard();
      guard.recordInterruptionBegin(
        InterruptionPhase.transient,
        wasPlaying: false,
        currentRoute: _bluetooth,
      );
      // 用户点歌不清除打断状态（区别于用户暂停）。
      guard.recordUserPlay();
      expect(guard.lastPause, isNull);
    });
  });

  group('AudioRouteSnapshot', () {
    test('matches：同一设备视为一致', () {
      const a = AudioRouteSnapshot(
        known: true,
        hasExternalOutput: true,
        externalDeviceIds: {'bt-1', 'bt-2'},
      );
      const b = AudioRouteSnapshot(
        known: true,
        hasExternalOutput: true,
        externalDeviceIds: {'bt-2'},
      );
      expect(a.matches(b), isTrue);
    });

    test('matches：外部→扬声器不一致', () {
      expect(_bluetooth.matches(_speaker), isFalse);
      expect(_speaker.matches(_bluetooth), isFalse);
    });

    test('matches：unknown 宽松一致', () {
      expect(_unknown.matches(_bluetooth), isTrue);
    });
  });
}
