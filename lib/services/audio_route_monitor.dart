// ignore_for_file: experimental_member_use
import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';

/// 只把「可作为媒体输出的外部设备」算作外部输出。
///
/// 修复 B5：原实现不检查 [AudioDevice.isOutput] 且把 bluetoothSco
/// （通话通道）也当作新音频设备，导致只连 HFP 的车机触发自动播放后
/// 直接从手机扬声器外放。
bool isMediaOutput(AudioDevice device) {
  if (!device.isOutput) return false;
  return switch (device.type) {
    AudioDeviceType.bluetoothA2dp ||
    AudioDeviceType.bluetoothLe ||
    AudioDeviceType.wiredHeadset ||
    AudioDeviceType.wiredHeadphones ||
    AudioDeviceType.usbAudio ||
    AudioDeviceType.carAudio ||
    AudioDeviceType.hearingAid ||
    AudioDeviceType.airPlay => true,
    _ => false,
  };
}

/// 音频路由快照：某一时刻「媒体输出走哪里」的安全归类。
///
/// 不直接暴露设备列表，只暴露闸门关心的三个信号：
/// - [known]：是否有真实路由信息（不支持 audio_session 的桌面平台
///   永远是 false，闸门对此不做路由拦截，沿用旧平台行为）；
/// - [hasExternalOutput]：是否存在耳机/蓝牙/USB/车机等外部媒体输出
///   （A2DP、LE Audio、有线、USB、车机、助听器、AirPlay，且 isOutput）；
///   注意 SCO（通话通道）不算媒体输出；
/// - [hasCallOnlyBluetooth]：存在 SCO 设备但没有外部媒体输出——
///   典型是车机/耳机「只连了电话（HFP）」：媒体必然走手机扬声器，
///   这是意外外放的高危状态（isAmbiguous）。
@immutable
class AudioRouteSnapshot {
  const AudioRouteSnapshot({
    required this.known,
    this.hasExternalOutput = false,
    this.hasCallOnlyBluetooth = false,
    this.externalDeviceIds = const {},
  });

  /// 无路由信息（平台不支持/查询失败）。闸门不做路由拦截。
  const AudioRouteSnapshot.unknown()
    : known = false,
      hasExternalOutput = false,
      hasCallOnlyBluetooth = false,
      externalDeviceIds = const {};

  /// 从 audio_session 报告的设备集合派生快照。
  factory AudioRouteSnapshot.fromDevices(Set<AudioDevice> devices) {
    final external = devices.where(isMediaOutput).toSet();
    final hasSco = devices.any((d) => d.type == AudioDeviceType.bluetoothSco);
    return AudioRouteSnapshot(
      known: true,
      hasExternalOutput: external.isNotEmpty,
      hasCallOnlyBluetooth: hasSco && external.isEmpty,
      externalDeviceIds: external.map((d) => d.id).toSet(),
    );
  }

  final bool known;
  final bool hasExternalOutput;
  final bool hasCallOnlyBluetooth;
  final Set<String> externalDeviceIds;

  /// 媒体输出会落到手机扬声器的高危状态。
  bool get isAmbiguous => known && hasCallOnlyBluetooth;

  /// 两个快照的媒体输出是否一致（I1 路由一致性判断）。
  bool matches(AudioRouteSnapshot other) {
    if (!known || !other.known) return true;
    if (hasExternalOutput != other.hasExternalOutput) return false;
    if (!hasExternalOutput) return true;
    // 至少一个相同的外部设备仍在，视为路由一致。
    return externalDeviceIds.intersection(other.externalDeviceIds).isNotEmpty;
  }

  String get short => known
      ? (hasExternalOutput
            ? 'external(${externalDeviceIds.length})'
            : hasCallOnlyBluetooth
            ? 'call-only-bt'
            : 'speaker')
      : 'unknown';

  @override
  String toString() => 'AudioRouteSnapshot($short)';
}

/// 路由变化事件的触发原因。
enum AudioRouteChangeReason {
  /// 外部媒体输出丢失（拔耳机/蓝牙断开）——立即暂停信号。
  abandoned,

  /// 外部媒体输出确认可用（重连/插入后经防抖确认）——恢复信号。
  ready,

  /// 普通快照刷新（不含上述两类语义变化）。
  snapshot,
}

/// 一次路由变化。
class AudioRouteChange {
  const AudioRouteChange({
    required this.snapshot,
    required this.reason,
    this.context,
  });

  final AudioRouteSnapshot snapshot;
  final AudioRouteChangeReason reason;

  /// 触发上下文（如 'becomingNoisy'、'removed:12'），仅用于日志。
  final String? context;

  @override
  String toString() =>
      'AudioRouteChange(${reason.name}, ${snapshot.short}, $context)';
}

/// 双源路由监听：becomingNoisy 快通道 + 设备增删兜底通道。
///
/// 单一依赖 ACTION_AUDIO_BECOMING_NOISY 广播是审计 B2 的根因：
/// 通话占线、LE Audio、双设备切换、定制 ROM 上这条广播可能缺席。
/// 本监听器同时订阅：
/// - [AudioSession.becomingNoisyEventStream]：权威的「离开耳机」信号，
///   立即广播 [AudioRouteChangeReason.abandoned]，不做防抖；
/// - [AudioSession.devicesChangedEventStream]：设备级增删事件。
///   移除外部输出 → 同样立即（含短防抖合并抖动）广播 abandoned 兜底；
///   新增输出设备 → 防抖 [confirmationDelay] 后重新查询设备集合，
///   只有确认外部输出存在才广播 [AudioRouteChangeReason.ready]，
///   避免「设备出现 ≠ 路由已生效」造成的瞬间外放（B5）。
class AudioRouteMonitor {
  AudioRouteMonitor({
    required Future<AudioSession> Function() sessionProvider,
    this.confirmationDelay = const Duration(milliseconds: 250),
  }) : _sessionProvider = sessionProvider;

  final Future<AudioSession> Function() _sessionProvider;

  /// 设备出现后确认路由生效的防抖等待。车机 A2DP 建立需 1~3 秒的场景
  /// 由重连时的设备事件再触发确认，250ms 只用于合并同一抖动窗口。
  final Duration confirmationDelay;

  final _changesController = StreamController<AudioRouteChange>.broadcast();

  StreamSubscription<void>? _noisySub;
  StreamSubscription<AudioDevicesChangedEvent>? _devicesChangedSub;
  Timer? _removalDebounce;
  Timer? _additionConfirm;
  AudioSession? _session;
  bool _disposed = false;

  AudioRouteSnapshot _current = const AudioRouteSnapshot.unknown();

  /// 当前快照。
  AudioRouteSnapshot get current => _current;

  /// 路由变化流（broadcast）。
  Stream<AudioRouteChange> get changes => _changesController.stream;

  bool get _isSupportedPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// 启动监听并获取初始快照。
  Future<void> start() async {
    if (_disposed || !_isSupportedPlatform) return;
    try {
      final session = await _sessionProvider();
      if (_disposed) return;
      _session = session;
      _current = AudioRouteSnapshot.fromDevices(await session.getDevices());
      _changesController.add(AudioRouteChange(
        snapshot: _current,
        reason: AudioRouteChangeReason.snapshot,
        context: 'initial',
      ));

      _noisySub = session.becomingNoisyEventStream.listen((_) {
        _handleBecomingNoisy();
      });

      _devicesChangedSub =
          session.devicesChangedEventStream.listen((event) {
            _handleDevicesChanged(event);
          });
    } catch (error) {
      // 获取失败保持 unknown：闸门对该平台不做路由拦截，
      // 行为退化为修复前的旧逻辑，不会更糟。
      debugPrint('[KA Music][route] monitor start failed: $error');
    }
  }

  /// becomingNoisy：权威的「外部输出丢失」信号，立即广播。
  ///
  /// 不做 getDevices 刷新：真机上广播可能先于设备列表更新（竞态），
  /// 刷新会把「已丢失」错误地改回「存在」。合成快照保持到下一次
  /// 设备事件（added 确认/removed 剔除）驱动。
  void _handleBecomingNoisy() {
    if (_disposed) return;
    debugPrint('[KA Music][route] becomingNoisy received');
    _additionConfirm?.cancel();
    _emitAbandoned('becomingNoisy');
  }

  void _handleDevicesChanged(AudioDevicesChangedEvent event) {
    if (_disposed) return;
    debugPrint(
      '[KA Music][route] devicesChanged '
      'added=${event.devicesAdded.map((d) => d.type.name).join(',')} '
      'removed=${event.devicesRemoved.map((d) => d.type.name).join(',')}',
    );
    final removedExternal = event.devicesRemoved.any(isMediaOutput);
    final addedOutput = event.devicesAdded.any((d) => d.isOutput);

    if (removedExternal) {
      // 兜底通道：becomingNoisy 缺席时靠它暂停。
      // 以设备事件为权威剔除被移除的外部输出（getDevices 与事件竞态时
      // 不可靠）；短防抖合并同一断开动作产生的多条事件。
      _additionConfirm?.cancel();
      _removalDebounce?.cancel();
      _removalDebounce = Timer(const Duration(milliseconds: 60), () {
        if (_disposed) return;
        _applyRemoval(
          event.devicesRemoved.where(isMediaOutput).map((d) => d.id).toSet(),
        );
      });
      return;
    }

    if (addedOutput) {
      // 设备出现 ≠ 路由生效：防抖后再查询并确认。
      _removalDebounce?.cancel();
      _additionConfirm?.cancel();
      _additionConfirm = Timer(confirmationDelay, () {
        if (_disposed) return;
        unawaited(_confirmAddition());
      });
    }
  }

  /// 从当前快照中剔除被移除的外部设备。
  ///
  /// 若仍有其他外部输出（双耳机/双蓝牙切换）：只刷新快照不发
  /// abandoned（避免多设备切换误暂停）；若全部移除：广播 abandoned。
  void _applyRemoval(Set<String> removedIds) {
    final remaining = _current.externalDeviceIds.difference(removedIds);
    debugPrint(
      '[KA Music][route] applyRemoval removed=${removedIds.join(',')} '
      'remaining=${remaining.length}',
    );
    final snapshot = AudioRouteSnapshot(
      known: true,
      hasExternalOutput: remaining.isNotEmpty,
      hasCallOnlyBluetooth:
          remaining.isNotEmpty ? false : _current.hasCallOnlyBluetooth,
      externalDeviceIds: remaining,
    );
    _current = snapshot;
    _changesController.add(AudioRouteChange(
      snapshot: snapshot,
      reason: remaining.isEmpty
          ? AudioRouteChangeReason.abandoned
          : AudioRouteChangeReason.snapshot,
      context: 'removed:${removedIds.join(',')}',
    ));
  }

  Future<void> _confirmAddition() async {
    final snapshot = await _refreshSnapshot(
      reason: AudioRouteChangeReason.snapshot,
    );
    if (_disposed) return;
    debugPrint(
      '[KA Music][route] addition confirmed -> ${snapshot.short}',
    );
    if (snapshot.known && snapshot.hasExternalOutput) {
      _changesController.add(AudioRouteChange(
        snapshot: snapshot,
        reason: AudioRouteChangeReason.ready,
        context: 'addition-confirmed',
      ));
    }
  }

  void _emitAbandoned(String context) {
    final snapshot = AudioRouteSnapshot(
      known: _current.known,
      hasExternalOutput: false,
      hasCallOnlyBluetooth: _current.hasCallOnlyBluetooth,
      externalDeviceIds: const {},
    );
    _current = snapshot;
    _changesController.add(AudioRouteChange(
      snapshot: snapshot,
      reason: AudioRouteChangeReason.abandoned,
      context: context,
    ));
  }

  Future<AudioRouteSnapshot> _refreshSnapshot(
      {required AudioRouteChangeReason reason}) async {
    final session = _session;
    if (session == null) return _current;
    try {
      final snapshot = AudioRouteSnapshot.fromDevices(
        await session.getDevices(),
      );
      if (_disposed) return _current;
      debugPrint('[KA Music][route] refresh -> ${snapshot.short}');
      _current = snapshot;
      _changesController.add(AudioRouteChange(
        snapshot: snapshot,
        reason: reason,
        context: 'refresh',
      ));
      return snapshot;
    } catch (error) {
      debugPrint('[KA Music][route] refresh failed: $error');
      return _current;
    }
  }

  /// 手动触发一次快照刷新（前台切换/播放前校验用）。
  Future<AudioRouteSnapshot> refresh() => _refreshSnapshot(
        reason: AudioRouteChangeReason.snapshot,
      );

  void dispose() {
    _disposed = true;
    _removalDebounce?.cancel();
    _additionConfirm?.cancel();
    unawaited(_noisySub?.cancel());
    unawaited(_devicesChangedSub?.cancel());
    unawaited(_changesController.close());
  }
}
