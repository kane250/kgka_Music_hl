// ignore_for_file: experimental_member_use
import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kgka_music_hl/services/audio_route_monitor.dart';

/// 假 AudioSession：只实现 AudioRouteMonitor 用到的三个接口。
class _MonitorShim implements AudioSession {
  final noisy = StreamController<void>.broadcast();
  final devicesChanged =
      StreamController<AudioDevicesChangedEvent>.broadcast();
  Set<AudioDevice> devices = {};

  @override
  Future<Set<AudioDevice>> getDevices({
    bool includeInputs = true,
    bool includeOutputs = true,
  }) async => devices;

  @override
  Stream<void> get becomingNoisyEventStream => noisy.stream;

  @override
  Stream<AudioDevicesChangedEvent> get devicesChangedEventStream =>
      devicesChanged.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  void close() {
    noisy.close();
    devicesChanged.close();
  }
}

AudioDevice _bt(String id) => AudioDevice(
      id: id,
      name: 'BT $id',
      isInput: false,
      isOutput: true,
      type: AudioDeviceType.bluetoothA2dp,
    );

AudioDevice _sco(String id) => AudioDevice(
      id: id,
      name: 'SCO $id',
      isInput: true,
      isOutput: true,
      type: AudioDeviceType.bluetoothSco,
    );

final _speaker = AudioDevice(
  id: 'spk',
  name: 'Speaker',
  isInput: false,
  isOutput: true,
  type: AudioDeviceType.builtInSpeaker,
);

final _wired = AudioDevice(
  id: 'wired',
  name: 'Wired',
  isInput: true,
  isOutput: true,
  type: AudioDeviceType.wiredHeadset,
);

Future<AudioRouteMonitor> _start(_MonitorShim session) async {
  final monitor = AudioRouteMonitor(
    sessionProvider: () async => session,
  );
  await monitor.start();
  return monitor;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  group('AudioRouteMonitor', () {
    test('初始快照来自 getDevices', () async {
      final session = _MonitorShim()..devices = {_bt('a'), _speaker};
      final monitor = await _start(session);
      expect(monitor.current.known, isTrue);
      expect(monitor.current.hasExternalOutput, isTrue);
      monitor.dispose();
      session.close();
    });

    test('becomingNoisy 立即广播 abandoned（快通道无防抖）', () async {
      final session = _MonitorShim()..devices = {_bt('a')};
      final monitor = await _start(session);
      final events = <AudioRouteChange>[];
      monitor.changes.listen(events.add);

      session.noisy.add(null);
      await Future<void>.delayed(Duration.zero);

      expect(
        events.any((e) => e.reason == AudioRouteChangeReason.abandoned),
        isTrue,
        reason: 'becomingNoisy 必须立即产生 abandoned 事件',
      );
      monitor.dispose();
      session.close();
    });

    test('外部设备移除且无 becomingNoisy 时兜底产生 abandoned（B2）',
        () async {
      final session = _MonitorShim()..devices = {_bt('a')};
      final monitor = await _start(session);
      final events = <AudioRouteChange>[];
      monitor.changes.listen(events.add);

      // 只有设备移除事件，没有 noisy 广播。
      session.devices = {_speaker};
      session.devicesChanged.add(AudioDevicesChangedEvent(
        devicesAdded: const {},
        devicesRemoved: {_bt('a')},
      ));
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(
        events.any((e) => e.reason == AudioRouteChangeReason.abandoned),
        isTrue,
        reason: 'becomingNoisy 缺席时设备移除兜底必须触发 abandoned',
      );
      monitor.dispose();
      session.close();
    });

    test('新输出设备出现后防抖确认为 ready（B5 修复）', () async {
      final session = _MonitorShim()..devices = {_speaker};
      final monitor = await _start(session);
      final events = <AudioRouteChange>[];
      monitor.changes.listen(events.add);

      session.devices = {_speaker, _bt('b')};
      session.devicesChanged.add(AudioDevicesChangedEvent(
        devicesAdded: {_bt('b')},
        devicesRemoved: const {},
      ));
      await Future<void>.delayed(Duration.zero);
      expect(
        events.any((e) => e.reason == AudioRouteChangeReason.ready),
        isFalse,
        reason: '确认前不得发出 ready',
      );

      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(
        events.any((e) => e.reason == AudioRouteChangeReason.ready),
        isTrue,
      );
      expect(monitor.current.hasExternalOutput, isTrue);
      monitor.dispose();
      session.close();
    });

    test('仅 SCO（通话通道）设备出现不产生 ready（B5 修复）', () async {
      final session = _MonitorShim()..devices = {_speaker};
      final monitor = await _start(session);
      final events = <AudioRouteChange>[];
      monitor.changes.listen(events.add);

      session.devices = {_speaker, _sco('s')};
      session.devicesChanged.add(AudioDevicesChangedEvent(
        devicesAdded: {_sco('s')},
        devicesRemoved: const {},
      ));
      await Future<void>.delayed(const Duration(milliseconds: 350));

      expect(
        events.any((e) => e.reason == AudioRouteChangeReason.ready),
        isFalse,
        reason: 'SCO 不算媒体输出，不得触发自动播放的 ready 信号',
      );
      expect(monitor.current.isAmbiguous, isTrue);
      monitor.dispose();
      session.close();
    });

    test('快照分类：SCO-only 为 ambiguous，A2DP 为外部输出', () {
      final scoOnly = AudioRouteSnapshot.fromDevices({_speaker, _sco('s')});
      expect(scoOnly.isAmbiguous, isTrue);
      expect(scoOnly.hasExternalOutput, isFalse);

      final withBt = AudioRouteSnapshot.fromDevices({_sco('s'), _bt('a')});
      expect(withBt.isAmbiguous, isFalse);
      expect(withBt.hasExternalOutput, isTrue);

      final wired = AudioRouteSnapshot.fromDevices({_wired});
      expect(wired.hasExternalOutput, isTrue);

      final speakerOnly = AudioRouteSnapshot.fromDevices({_speaker});
      expect(speakerOnly.hasExternalOutput, isFalse);
      expect(speakerOnly.isAmbiguous, isFalse);
    });

    test('非移动平台上 start 失败时快照保持 unknown（B9 行为定义）',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final monitor = AudioRouteMonitor(
        sessionProvider: () async => throw StateError('no session'),
      );
      await monitor.start();
      expect(monitor.current.known, isFalse);
      monitor.dispose();
    });
  });
}
