import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:kgka_music_hl/controllers/auth_controller.dart';
import 'package:kgka_music_hl/controllers/download_controller.dart';
import 'package:kgka_music_hl/controllers/local_music_controller.dart';
import 'package:kgka_music_hl/controllers/player_controller.dart';
import 'package:kgka_music_hl/controllers/theme_controller.dart';
import 'package:kgka_music_hl/models/music_models.dart';
import 'package:kgka_music_hl/services/cache_service.dart';
import 'package:kgka_music_hl/services/music_api.dart';
import 'package:kgka_music_hl/services/music_audio_handler.dart';
import 'package:kgka_music_hl/services/playback_guard.dart';
import 'package:kgka_music_hl/ui/pages/home_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Session extends Fake implements AudioSession {
  final interruptions = StreamController<AudioInterruptionEvent>.broadcast();
  final noisy = StreamController<void>.broadcast();
  final devices = StreamController<Set<AudioDevice>>.broadcast();
  final devicesChanged =
      StreamController<AudioDevicesChangedEvent>.broadcast();

  /// 可变的设备集合：模拟耳机/蓝牙连接状态。
  Set<AudioDevice> currentDevices = {};

  @override
  Stream<AudioInterruptionEvent> get interruptionEventStream =>
      interruptions.stream;
  @override
  Stream<void> get becomingNoisyEventStream => noisy.stream;
  @override
  Stream<Set<AudioDevice>> get devicesStream => devices.stream;
  @override
  Stream<AudioDevicesChangedEvent> get devicesChangedEventStream =>
      devicesChanged.stream;
  @override
  Future<void> configure(AudioSessionConfiguration configuration) async {}
  @override
  Future<Set<AudioDevice>> getDevices({
    bool includeInputs = true,
    bool includeOutputs = true,
  }) async => currentDevices;

  void interrupt(
    bool begin, [
    AudioInterruptionType type = AudioInterruptionType.pause,
  ]) {
    interruptions.add(AudioInterruptionEvent(begin, type));
  }

  void removeExternalDevices() {
    final removed = currentDevices.where(_isMediaOutputDevice).toSet();
    currentDevices = currentDevices.difference(removed);
    devicesChanged.add(AudioDevicesChangedEvent(
      devicesAdded: const {},
      devicesRemoved: removed,
    ));
  }

  void addBluetoothMediaDevice() {
    final device = AudioDevice(
      id: 'bt-media',
      name: 'BT Media',
      isInput: false,
      isOutput: true,
      // ignore: experimental_member_use
      type: AudioDeviceType.bluetoothA2dp,
    );
    currentDevices = {...currentDevices, device};
    devicesChanged.add(AudioDevicesChangedEvent(
      devicesAdded: {device},
      devicesRemoved: const {},
    ));
  }

  void addScoOnlyDevice() {
    final device = AudioDevice(
      id: 'bt-sco',
      name: 'BT SCO',
      isInput: true,
      isOutput: true,
      // ignore: experimental_member_use
      type: AudioDeviceType.bluetoothSco,
    );
    currentDevices = {...currentDevices, device};
    devicesChanged.add(AudioDevicesChangedEvent(
      devicesAdded: {device},
      devicesRemoved: const {},
    ));
  }

  static bool _isMediaOutputDevice(AudioDevice d) {
    // ignore: experimental_member_use
    return d.type == AudioDeviceType.bluetoothA2dp ||
        // ignore: experimental_member_use
        d.type == AudioDeviceType.wiredHeadset ||
        // ignore: experimental_member_use
        d.type == AudioDeviceType.wiredHeadphones;
  }

  Future<void> close() async {
    await interruptions.close();
    await noisy.close();
    await devices.close();
    await devicesChanged.close();
  }
}

class _Player extends Fake implements AudioPlayer {
  final states = StreamController<PlayerState>.broadcast(sync: true);
  final processing = StreamController<ProcessingState>.broadcast(sync: true);
  bool _playing = false;
  double _volume = 1;
  ProcessingState _processingState = ProcessingState.ready;

  void complete() {
    setProcessingState(ProcessingState.completed);
  }

  void setProcessingState(ProcessingState state) {
    _processingState = state;
    processing.add(state);
  }

  @override
  double get volume => _volume;
  @override
  Future<void> setVolume(double value) async {
    _volume = value;
  }

  @override
  bool get playing => _playing;
  void setPlaying(bool value) {
    _playing = value;
    states.add(PlayerState(value, ProcessingState.ready));
  }

  @override
  Stream<PlayerState> get playerStateStream => states.stream;
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<ProcessingState> get processingStateStream => processing.stream;
  @override
  Stream<int?> get androidAudioSessionIdStream => const Stream.empty();
  @override
  Duration get position => Duration.zero;
  @override
  int? get androidAudioSessionId => null;
  @override
  ProcessingState get processingState => _processingState;
  @override
  Future<void> setSpeed(double speed) async {}
}

class _Handler extends Fake implements MusicAudioHandler {
  @override
  final _Player audioPlayer = _Player();
  void Function()? _onPause;
  void Function()? _onPlay;
  int automaticPlays = 0;
  Completer<void>? sourceLoad;
  Completer<void>? pendingSeek;
  Completer<void>? pendingPlay;
  PlayDecision Function(PlayOrigin origin)? gate;

  @override
  void attachPlaybackGate(PlayDecision Function(PlayOrigin origin) decide) {
    gate = decide;
  }
  @override
  Song? loadedSong;

  @override
  Future<void> loadSong({
    required Song song,
    required String url,
    required List<Song> queueSongs,
    required int queueIndex,
  }) async {
    await sourceLoad?.future;
    loadedSong = song;
    audioPlayer.setProcessingState(ProcessingState.ready);
  }

  @override
  Future<void> seek(Duration position) async {
    await pendingSeek?.future;
    audioPlayer.setProcessingState(ProcessingState.ready);
  }

  @override
  void attachTransportControls({
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
    void Function()? onPause,
    void Function()? onPlay,
  }) {
    _onPause = onPause;
    _onPlay = onPlay;
  }

  @override
  void detachTransportControls() {}
  @override
  void setBluetoothLyricsTitleSync(bool enabled) {}
  @override
  void updateLyricMetadata({
    String? lyricText,
    String? translationText,
    String? romanizationText,
    String? fullLyricLrc,
  }) {}
  @override
  Future<void> pause({bool userInitiated = true}) async {
    if (userInitiated) _onPause?.call();
    audioPlayer.setPlaying(false);
  }

  @override
  Future<void> play({PlayOrigin origin = PlayOrigin.systemMedia}) async {
    // 与真实 MusicAudioHandler 一致：系统直达的请求也要过闸门；
    // 外部 userTap 过闸后同步 transport 回调（controller 的用户意图）。
    final decision = gate?.call(origin);
    if (decision != null && decision != PlayDecision.allow) {
      return;
    }
    if (origin == PlayOrigin.userTap) {
      _onPlay?.call();
    } else {
      automaticPlays++;
    }
    audioPlayer.setPlaying(true);
    await pendingPlay?.future;
  }

  /// controller 内部起播：过闸门、计数，但不触发 transport 回调。
  @override
  Future<void> playInternal(PlayOrigin origin) async {
    final decision = gate?.call(origin);
    if (decision != null && decision != PlayDecision.allow) {
      return;
    }
    automaticPlays++;
    audioPlayer.setPlaying(true);
    await pendingPlay?.future;
  }

  @override
  Future<void> close() async {
    await audioPlayer.states.close();
    await audioPlayer.processing.close();
  }
}

class _Downloads extends Fake implements DownloadController {}

class _LocalMusic extends Fake implements LocalMusicController {}

class _HomePlayer extends ChangeNotifier implements PlayerController {
  Song? requestedSong;
  List<Song>? requestedQueue;
  bool? requestedByUser;

  @override
  Future<void> get settingsRestored async {}
  @override
  bool get autoPlayOnStartupEnabled => true;
  @override
  bool get isPlaying => false;
  @override
  bool get isPersonalFmActive => false;
  @override
  bool get isLoadingPersonalFm => false;
  @override
  Song? get currentSong => null;
  @override
  DownloadController? get downloadController => null;
  @override
  Future<int> getPlaybackHistoryCount() async => 0;

  @override
  Future<void> playSong(
    Song song, {
    List<Song>? queue,
    bool preservePersonalFmSession = false,
    QueueOrigin? origin,
    bool userInitiated = true,
    PlayOrigin? playOrigin,
  }) async {
    requestedSong = song;
    requestedQueue = queue;
    requestedByUser = userInitiated;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Api extends Fake implements MusicApi {
  Completer<List<Song>>? recommendations;
  Completer<PlayUrl>? url;
  Completer<DailyRecommend>? daily;

  @override
  Future<DailyRecommend> dailyRecommend() => daily!.future;
  @override
  Future<List<PlaylistSummary>> recommendedPlaylists({
    int categoryId = 0,
    int page = 1,
  }) async => [];
  @override
  Future<List<AlbumShopItem>> albumShop({
    int page = 1,
    int pageSize = 30,
  }) async => [];
  @override
  Future<List<Song>> topSongs({int type = 21608, int page = 1}) async => [];
  @override
  Future<List<TopAlbumItem>> topAlbums({
    int page = 1,
    int pageSize = 30,
  }) async => [];
  @override
  Future<List<RecommendedSongCard>> recommendedSongCards() async => [];
  @override
  Future<List<Song>> fmSongs(
    FmStation station, {
    int offset = -1,
    int size = 20,
  }) async => [];
  @override
  Future<List<FmStation>> fmRecommendedStations() async => [];
  @override
  Future<List<FmClassGroup>> fmClassGroups() async => [];
  @override
  Future<Map<String, FmImage>> fmImages(List<String> fmids) async => {};

  @override
  Future<List<Song>> personalFm({
    String? hash,
    String? songId,
    int? playtime,
    bool isOverplay = false,
  }) => recommendations!.future;

  @override
  Future<PlayUrl> songUrl(
    Song song, {
    AudioQuality quality = AudioQuality.standard,
    bool hashOnly = false,
  }) => url!.future;

  @override
  Future<SongClimax?> songClimax(String hash) async => null;
  @override
  Future<List<LyricLine>> lyrics(Song song) async => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Session session;
  late _Handler handler;
  late PlayerController player;
  late _Api api;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    session = _Session();
    handler = _Handler();
    api = _Api();
    player = PlayerController(
      api,
      handler,
      audioSessionProvider: () async => session,
    );
    player.currentSong = const Song(
      id: '1',
      title: 'Test',
      artist: 'Artist',
      hash: 'HASH',
    );
  });

  tearDown(() async {
    await Future<void>.delayed(Duration.zero);
    player.dispose();
    await session.close();
    debugDefaultTargetPlatformOverride = null;
  });

  test('a call does not start a song that was already paused', () async {
    await Future<void>.delayed(Duration.zero);
    session.interrupt(true);
    await Future<void>.delayed(Duration.zero);
    session.interrupt(false);
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(handler.audioPlayer.playing, isFalse);
    expect(handler.automaticPlays, 0);
  });

  test('a playing song pauses for a call and resumes once', () async {
    await Future<void>.delayed(Duration.zero);
    handler.audioPlayer.setPlaying(true);
    session.interrupt(true);
    await Future<void>.delayed(Duration.zero);
    expect(handler.audioPlayer.playing, isFalse);
    session.interrupt(false);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(handler.audioPlayer.playing, isTrue);
    expect(handler.automaticPlays, 1);
    session.interrupt(false);
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(handler.automaticPlays, 1);
  });

  test('auto-resume disabled keeps interrupted playback paused', () async {
    await Future<void>.delayed(Duration.zero);
    player.autoResumeAfterInterruption = false;
    handler.audioPlayer.setPlaying(true);
    session.interrupt(true);
    await Future<void>.delayed(Duration.zero);
    session.interrupt(false);
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(handler.audioPlayer.playing, isFalse);
    expect(handler.automaticPlays, 0);
  });

  test(
    'disconnect during a call prevents resuming through the speaker',
    () async {
      await Future<void>.delayed(Duration.zero);
      handler.audioPlayer.setPlaying(true);
      session.interrupt(true);
      await Future<void>.delayed(Duration.zero);
      session.noisy.add(null);
      await Future<void>.delayed(Duration.zero);
      session.interrupt(false);
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(handler.audioPlayer.playing, isFalse);
      expect(handler.automaticPlays, 0);
    },
  );

  test('disconnect during ducking stays paused after focus returns', () async {
    await Future<void>.delayed(Duration.zero);
    handler.audioPlayer.setPlaying(true);
    session.interrupt(true, AudioInterruptionType.duck);
    await Future<void>.delayed(Duration.zero);
    expect(handler.audioPlayer.playing, isTrue);
    session.noisy.add(null);
    await Future<void>.delayed(Duration.zero);
    session.interrupt(false, AudioInterruptionType.duck);
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(handler.audioPlayer.playing, isFalse);
    expect(handler.automaticPlays, 0);
  });

  test('notification pause cancels an already scheduled resume', () async {
    await Future<void>.delayed(Duration.zero);
    handler.audioPlayer.setPlaying(true);
    session.interrupt(true);
    await Future<void>.delayed(Duration.zero);
    session.interrupt(false);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await handler.pause();
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(handler.audioPlayer.playing, isFalse);
    expect(handler.automaticPlays, 0);
  });

  test('notification pause during a call clears resume intent', () async {
    await Future<void>.delayed(Duration.zero);
    handler.audioPlayer.setPlaying(true);
    session.interrupt(true);
    await Future<void>.delayed(Duration.zero);
    await handler.pause();
    session.interrupt(false);
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(handler.audioPlayer.playing, isFalse);
    expect(handler.automaticPlays, 0);
  });

  test(
    'explicit playback after disconnect permits later call recovery',
    () async {
      await Future<void>.delayed(Duration.zero);
      handler.audioPlayer.setPlaying(true);
      session.noisy.add(null);
      await Future<void>.delayed(Duration.zero);
      await handler.play(origin: PlayOrigin.userTap);
      session.interrupt(true);
      await Future<void>.delayed(Duration.zero);
      session.interrupt(false);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(handler.audioPlayer.playing, isTrue);
      expect(handler.automaticPlays, 1);
    },
  );

  test('legacy disconnect behavior also preserves an existing pause', () async {
    await Future<void>.delayed(Duration.zero);
    player.autoPauseOnDeviceDisconnect = false;
    session.noisy.add(null);
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(handler.audioPlayer.playing, isFalse);
    expect(handler.automaticPlays, 0);
  });

  test(
    'legacy disconnect pauses and resumes an actively playing song',
    () async {
      await Future<void>.delayed(Duration.zero);
      player.autoPauseOnDeviceDisconnect = false;
      handler.audioPlayer.setPlaying(true);
      session.noisy.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(handler.audioPlayer.playing, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(handler.audioPlayer.playing, isTrue);
      expect(handler.automaticPlays, 1);
    },
  );

  test(
    'block interruption keeps audio playing but disconnect still stops it',
    () async {
      await Future<void>.delayed(Duration.zero);
      player.audioInterruptionEnabled = false;
      handler.audioPlayer.setPlaying(true);
      session.interrupt(true);
      await Future<void>.delayed(Duration.zero);
      expect(handler.audioPlayer.playing, isTrue);
      session.noisy.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      session.interrupt(false);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(handler.audioPlayer.playing, isFalse);
      expect(handler.automaticPlays, 0);
    },
  );

  test(
    'controller pause while a call has already paused cancels recovery',
    () async {
      await Future<void>.delayed(Duration.zero);
      handler.audioPlayer.setPlaying(true);
      session.interrupt(true);
      await Future<void>.delayed(Duration.zero);
      await player.pause();
      session.interrupt(false);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(handler.audioPlayer.playing, isFalse);
      expect(handler.automaticPlays, 0);
    },
  );

  test('duck lowers volume and restores the exact previous level', () async {
    await Future<void>.delayed(Duration.zero);
    await handler.audioPlayer.setVolume(.8);
    handler.audioPlayer.setPlaying(true);
    session.interrupt(true, AudioInterruptionType.duck);
    await Future<void>.delayed(Duration.zero);
    expect(handler.audioPlayer.volume, .4);
    session.interrupt(false, AudioInterruptionType.duck);
    await Future<void>.delayed(Duration.zero);
    expect(handler.audioPlayer.volume, .8);
    expect(handler.automaticPlays, 0);
  });

  test('duck end does not overwrite a volume changed by the user', () async {
    await Future<void>.delayed(Duration.zero);
    session.interrupt(true, AudioInterruptionType.duck);
    await Future<void>.delayed(Duration.zero);
    await handler.audioPlayer.setVolume(.3);
    session.interrupt(false, AudioInterruptionType.duck);
    await Future<void>.delayed(Duration.zero);
    expect(handler.audioPlayer.volume, .3);
  });

  test(
    'unknown interruption end does not grant permission to resume',
    () async {
      await Future<void>.delayed(Duration.zero);
      handler.audioPlayer.setPlaying(true);
      session.interrupt(true, AudioInterruptionType.unknown);
      await Future<void>.delayed(Duration.zero);
      session.interrupt(false, AudioInterruptionType.unknown);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(handler.audioPlayer.playing, isFalse);
      expect(handler.automaticPlays, 0);
    },
  );

  const localA = Song(
    id: 'a',
    title: 'A',
    artist: 'Artist',
    hash: 'LOCAL_A',
    source: SongSource.netease,
  );
  const localB = Song(
    id: 'b',
    title: 'B',
    artist: 'Artist',
    hash: 'LOCAL_B',
    source: SongSource.netease,
  );

  const localC = Song(
    id: 'c',
    title: 'C',
    artist: 'Artist',
    hash: 'LOCAL_C',
    source: SongSource.netease,
  );

  test(
    'a newer cutover restores the volume muted by an older request',
    () async {
      await player.playSong(localA, queue: [localA, localB, localC]);
      await handler.audioPlayer.setVolume(.8);
      handler.sourceLoad = Completer<void>();
      final first = player.next();
      await Future<void>.delayed(Duration.zero);
      expect(handler.audioPlayer.volume, 0);

      // The outgoing song ends before the latest selection takes over.
      handler.audioPlayer.complete();
      final second = player.next();
      handler.sourceLoad!.complete();
      await Future.wait([first, second]);
      expect(handler.loadedSong, same(localC));
      expect(handler.audioPlayer.volume, .8);
    },
  );

  test(
    'switch mute and interruption ducking restore the base volume',
    () async {
      await player.playSong(localA, queue: [localA, localB]);
      await handler.audioPlayer.setVolume(.8);
      handler.sourceLoad = Completer<void>();
      final switching = player.next();
      await Future<void>.delayed(Duration.zero);
      expect(handler.audioPlayer.volume, 0);

      session.interrupt(true, AudioInterruptionType.duck);
      await Future<void>.delayed(Duration.zero);
      handler.sourceLoad!.complete();
      await switching;
      expect(handler.audioPlayer.volume, .4);

      session.interrupt(false, AudioInterruptionType.duck);
      await Future<void>.delayed(Duration.zero);
      expect(handler.audioPlayer.volume, .8);
    },
  );

  test(
    'permanent interruption restores ducked volume without a gain event',
    () async {
      await player.playSong(localA);
      await handler.audioPlayer.setVolume(.8);
      session.interrupt(true, AudioInterruptionType.duck);
      await Future<void>.delayed(Duration.zero);
      expect(handler.audioPlayer.volume, .4);

      session.interrupt(true, AudioInterruptionType.unknown);
      await Future<void>.delayed(Duration.zero);
      expect(handler.audioPlayer.playing, isFalse);
      expect(handler.audioPlayer.volume, .8);
    },
  );

  test(
    'consecutive completions advance after the previous start finishes',
    () async {
      await player.playSong(localA, queue: [localA, localB, localC]);
      final starting = Completer<void>();
      handler.pendingPlay = starting;
      handler.audioPlayer.complete();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(handler.loadedSong, same(localB));
      handler.audioPlayer.complete();

      handler.pendingPlay = null;
      starting.complete();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(handler.loadedSong, same(localC));
      expect(handler.automaticPlays, 3);
    },
  );

  testWidgets('home startup recommendation is marked as automatic', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = null;
    final startupPlayer = _HomePlayer();
    api.daily = Completer<DailyRecommend>();
    final cache = CacheService();
    final auth = AuthController(api, cache)..isRestoring = false;
    final theme = ThemeController();
    addTearDown(auth.dispose);
    addTearDown(theme.dispose);
    addTearDown(startupPlayer.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomePage(
            api: api,
            auth: auth,
            player: startupPlayer,
            cache: cache,
            theme: theme,
            downloads: _Downloads(),
            localMusic: _LocalMusic(),
          ),
        ),
      ),
    );

    api.daily!.complete(const DailyRecommend(title: '每日推荐', songs: [localA]));
    await tester.pump();
    // Run the real homepage's post-frame callback and Windows startup delay.
    await tester.pump(const Duration(milliseconds: 350));
    expect(startupPlayer.requestedSong, same(localA));
    expect(startupPlayer.requestedQueue, [localA]);
    expect(startupPlayer.requestedByUser, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 2));
  });

  test('automatic song request after disconnect stays paused', () async {
    await Future<void>.delayed(Duration.zero);
    session.noisy.add(null);
    await Future<void>.delayed(Duration.zero);
    await player.playSong(localA, userInitiated: false);
    expect(player.currentSong, same(localA));
    expect(player.errorMessage, isNull);
    expect(handler.audioPlayer.playing, isFalse);
    expect(handler.automaticPlays, 0);

    await player.playSong(localA);
    expect(handler.audioPlayer.playing, isTrue);
  });

  test('natural completion delay cannot unlock a later disconnect', () async {
    await Future<void>.delayed(Duration.zero);
    await player.playSong(localA, queue: [localA, localB]);
    final baselinePlays = handler.automaticPlays;
    handler.audioPlayer.complete();
    session.noisy.add(null);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(handler.audioPlayer.playing, isFalse);
    expect(handler.automaticPlays, baselinePlays);
    await player.playSong(localB);
    expect(
      handler.audioPlayer.playing,
      isTrue,
      reason: 'a later explicit request may unlock playback',
    );
  });

  test(
    'FM recommendation response cannot unlock a disconnect during the request',
    () async {
      await Future<void>.delayed(Duration.zero);
      await player.startPersonalFm(initialSongs: [localA]);
      final baselinePlays = handler.automaticPlays;
      api.recommendations = Completer<List<Song>>();
      handler.audioPlayer.complete();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      session.noisy.add(null);
      await Future<void>.delayed(Duration.zero);
      api.recommendations!.complete([localB]);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(handler.audioPlayer.playing, isFalse);
      expect(handler.automaticPlays, baselinePlays);
    },
  );

  test(
    'single-loop seek cannot unlock a disconnect while it is pending',
    () async {
      await Future<void>.delayed(Duration.zero);
      await player.playSong(localA);
      final baselinePlays = handler.automaticPlays;
      player.playbackMode = PlaybackMode.singleLoop;
      handler.pendingSeek = Completer<void>();
      handler.audioPlayer.complete();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      session.noisy.add(null);
      await Future<void>.delayed(Duration.zero);
      handler.pendingSeek!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(handler.audioPlayer.playing, isFalse);
      expect(handler.automaticPlays, baselinePlays);
    },
  );

  test(
    'source load completion does not grant a new manual play intent',
    () async {
      await Future<void>.delayed(Duration.zero);
      handler.sourceLoad = Completer<void>();
      final pending = player.playSong(localA);
      await Future<void>.delayed(Duration.zero);
      session.noisy.add(null);
      await Future<void>.delayed(Duration.zero);
      handler.sourceLoad!.complete();
      await pending;
      expect(handler.audioPlayer.playing, isFalse);
      expect(handler.automaticPlays, 0);
    },
  );

  test(
    'startup restore auto-play cannot bypass a disconnect during loading',
    () async {
      await Future<void>.delayed(Duration.zero);
      player.currentSong = localA;
      handler.sourceLoad = Completer<void>();
      final pending = player.prepareRestoredSong(autoPlay: true);
      await Future<void>.delayed(Duration.zero);
      session.noisy.add(null);
      await Future<void>.delayed(Duration.zero);
      handler.sourceLoad!.complete();
      await pending;
      expect(handler.audioPlayer.playing, isFalse);
      expect(handler.automaticPlays, 0);
    },
  );

  test('restoring a song releases a superseded switch mute', () async {
    await player.playSong(localA, queue: [localA, localB, localC]);
    await handler.audioPlayer.setVolume(.8);
    final loading = Completer<void>();
    handler.sourceLoad = loading;
    final switching = player.next();
    await Future<void>.delayed(Duration.zero);
    expect(handler.audioPlayer.volume, 0);

    final restoring = player.prepareRestoredSong(
      autoPlay: true,
      expectedSong: localB,
    );
    loading.complete();
    await Future.wait([switching, restoring]);
    expect(handler.loadedSong, same(localB));
    expect(handler.audioPlayer.volume, .8);

    handler.audioPlayer.complete();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(handler.loadedSong, same(localC));
  });

  test('a delayed quality reload preserves a later song selection', () async {
    final networkSong = player.currentSong!;
    const initialUrl = PlayUrl(
      url: 'https://example.test/standard.mp3',
      hash: 'HASH',
    );
    api.url = Completer<PlayUrl>()..complete(initialUrl);
    await player.playSong(networkSong, queue: [networkSong, localB]);
    final qualityUrl = Completer<PlayUrl>();
    api.url = qualityUrl;
    final reloading = player.setAudioQuality(
      AudioQuality.high,
      reloadCurrent: true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(player.isPreparing, isTrue);

    await player.next();
    qualityUrl.complete(
      const PlayUrl(url: 'https://example.test/high.mp3', hash: 'HASH'),
    );
    await reloading;
    expect(player.currentSong, same(localB));
    expect(handler.loadedSong, same(localB));
    expect(handler.automaticPlays, 2);
  });

  test(
    'quality reload does not resume after a disconnect during URL resolution',
    () async {
      await Future<void>.delayed(Duration.zero);
      handler.audioPlayer.setPlaying(true);
      api.url = Completer<PlayUrl>();
      final pending = player.setAudioQuality(
        AudioQuality.high,
        reloadCurrent: true,
      );
      await Future<void>.delayed(Duration.zero);
      session.noisy.add(null);
      await Future<void>.delayed(Duration.zero);
      api.url!.complete(
        PlayUrl(url: 'https://example.test/audio.mp3', hash: 'HASH'),
      );
      await pending;
      expect(handler.audioPlayer.playing, isFalse);
      expect(handler.automaticPlays, 0);
    },
  );

  test(
    'source load completion waits while a pause interruption is active',
    () async {
      await Future<void>.delayed(Duration.zero);
      handler.sourceLoad = Completer<void>();
      final pending = player.playSong(localA);
      await Future<void>.delayed(Duration.zero);
      session.interrupt(true);
      await Future<void>.delayed(Duration.zero);
      handler.sourceLoad!.complete();
      await pending;
      expect(handler.audioPlayer.playing, isFalse);
      expect(handler.automaticPlays, 0);
    },
  );

  test('duck allows an explicit song change to start playing', () async {
    await Future<void>.delayed(Duration.zero);
    handler.audioPlayer.setPlaying(true);
    session.interrupt(true, AudioInterruptionType.duck);
    await Future<void>.delayed(Duration.zero);
    await player.playSong(localB);
    expect(handler.audioPlayer.playing, isTrue);
    expect(player.currentSong, same(localB));
  });

  test(
    'a song loaded during a call resumes only after the call ends',
    () async {
      await Future<void>.delayed(Duration.zero);
      handler.sourceLoad = Completer<void>();
      final pending = player.playSong(localA);
      await Future<void>.delayed(Duration.zero);
      session.interrupt(true);
      await Future<void>.delayed(Duration.zero);
      handler.sourceLoad!.complete();
      await pending;
      expect(handler.audioPlayer.playing, isFalse);
      session.interrupt(false);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(handler.audioPlayer.playing, isTrue);
      expect(handler.automaticPlays, 1);
    },
  );

  test(
    'disabled auto-resume revokes a source that finishes after the call',
    () async {
      await Future<void>.delayed(Duration.zero);
      player.autoResumeAfterInterruption = false;
      handler.sourceLoad = Completer<void>();
      final pending = player.playSong(localA);
      await Future<void>.delayed(Duration.zero);
      session.interrupt(true);
      await Future<void>.delayed(Duration.zero);
      session.interrupt(false);
      await Future<void>.delayed(Duration.zero);
      handler.sourceLoad!.complete();
      await pending;
      expect(handler.audioPlayer.playing, isFalse);
      expect(handler.automaticPlays, 0);
    },
  );

  test('unknown end revokes a source that is still loading', () async {
    await Future<void>.delayed(Duration.zero);
    handler.sourceLoad = Completer<void>();
    final pending = player.playSong(localA);
    await Future<void>.delayed(Duration.zero);
    session.interrupt(true, AudioInterruptionType.unknown);
    await Future<void>.delayed(Duration.zero);
    session.interrupt(false, AudioInterruptionType.unknown);
    await Future<void>.delayed(Duration.zero);
    handler.sourceLoad!.complete();
    await pending;
    expect(handler.audioPlayer.playing, isFalse);
    expect(handler.automaticPlays, 0);
  });

  // ============================================================
  // C3 路由层：设备移除兜底 / 恢复路由校验 / 连接自动播放收紧。
  // 路由监听只在移动平台启动，这组用例局部覆盖为 android。
  // ============================================================
  group('route-aware playback', () {
    late _Session routeSession;
    late _Handler routeHandler;
    late PlayerController routePlayer;

    setUp(() {
      // 路由监听只在移动平台启动；PlayerController 的会话装配发生在
      // 构造期，因此先覆盖平台再自建独立的 player（不复用全局 windows
      // 环境下构造的那个）。
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      routeSession = _Session();
      routeHandler = _Handler();
      routePlayer = PlayerController(
        api,
        routeHandler,
        audioSessionProvider: () async => routeSession,
      );
      routePlayer.currentSong = const Song(
        id: '1',
        title: 'Route',
        artist: 'Artist',
        hash: 'ROUTE',
      );
    });

    tearDown(() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await Future<void>.delayed(Duration.zero);
      routePlayer.dispose();
      await routeSession.close();
    });

    test('设备移除且无 becomingNoisy 时兜底暂停（B2）', () async {
      await Future<void>.delayed(Duration.zero);
      routeSession.addBluetoothMediaDevice();
      routeHandler.audioPlayer.setPlaying(true);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // 只有设备移除事件，不发 noisy 广播。
      routeSession.removeExternalDevices();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(routeHandler.audioPlayer.playing, isFalse);

      // 兜底暂停后不得自动恢复（扬声器上绝不续播）。
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(routeHandler.audioPlayer.playing, isFalse);
      expect(routeHandler.automaticPlays, 0);
    });

    test('断连暂停后重连耳机自动恢复（I1）', () async {
      await Future<void>.delayed(Duration.zero);
      routeSession.addBluetoothMediaDevice();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      routeHandler.audioPlayer.setPlaying(true);
      routeSession.noisy.add(null);
      await Future<void>.delayed(Duration.zero);
      expect(routeHandler.audioPlayer.playing, isFalse);

      // 蓝牙耳机重新连接并确认路由生效。
      routeSession.addBluetoothMediaDevice();
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(routeHandler.audioPlayer.playing, isTrue);
      expect(routeHandler.automaticPlays, 1);
    });

    test('通话结束后路由未回耳机不恢复，回连后唤醒（B4）', () async {
      await Future<void>.delayed(Duration.zero);
      routeSession.addBluetoothMediaDevice();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      routeHandler.audioPlayer.setPlaying(true);

      // 通话开始（此时路由还在蓝牙耳机上）。
      routeSession.interrupt(true);
      await Future<void>.delayed(Duration.zero);
      expect(routeHandler.audioPlayer.playing, isFalse);

      // 通话中耳机断开（A2DP 让位给通话/被关闭）。
      routeSession.removeExternalDevices();
      await Future<void>.delayed(const Duration(milliseconds: 150));

      // 通话结束：路由还在扬声器 → 恢复被 defer，不得外放。
      routeSession.interrupt(false);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(routeHandler.audioPlayer.playing, isFalse);

      // 耳机回连：被推迟的恢复唤醒。
      routeSession.addBluetoothMediaDevice();
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(routeHandler.audioPlayer.playing, isTrue);
      expect(routeHandler.automaticPlays, 1);
    });

    test('只连通话通道的蓝牙不触发自动播放（B5）', () async {
      await Future<void>.delayed(Duration.zero);
      routePlayer.autoPlayOnDeviceConnected = true;

      // SCO 设备出现：不算媒体输出，不产生 ready 信号。
      routeSession.addScoOnlyDevice();
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(routeHandler.audioPlayer.playing, isFalse);
      expect(routeHandler.automaticPlays, 0);
    });

    test('连接确认后的蓝牙设备可自动播放（B5 正向）', () async {
      await Future<void>.delayed(Duration.zero);
      routePlayer.autoPlayOnDeviceConnected = true;

      routeSession.addBluetoothMediaDevice();
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expect(routeHandler.audioPlayer.playing, isTrue);
      expect(routeHandler.automaticPlays, 1);
    });

    test('断连挂起时深链播放被闸门拒绝，用户显式播放放行（B3）',
        () async {
      await Future<void>.delayed(Duration.zero);
      routeSession.addBluetoothMediaDevice();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      routeHandler.audioPlayer.setPlaying(true);
      routeSession.noisy.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(routeHandler.audioPlayer.playing, isFalse);

      // 深链 toggle：externalLink 来源 + 断连挂起 + 路由落回扬声器 → defer。
      await routePlayer.togglePlay(origin: PlayOrigin.externalLink);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(routeHandler.audioPlayer.playing, isFalse);

      // 用户在 App 内显式播放：userTap 解锁放行。
      await routePlayer.play();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(routeHandler.audioPlayer.playing, isTrue);
    });

    test('断连暂停跨重启：恢复自启动不自动播放（B6）', () async {
      await Future<void>.delayed(Duration.zero);
      routeSession.addBluetoothMediaDevice();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      routeHandler.audioPlayer.setPlaying(true);
      routeSession.noisy.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(routeHandler.audioPlayer.playing, isFalse);

      // 断连标记已持久化。
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getBool('playback.paused_by_disconnect'),
        isTrue,
        reason: '断连暂停必须落盘，重启后才能禁止自启动外放',
      );

      // 模拟重启：新建 player（同一 prefs），上次歌曲恢复自启动流程。
      final rebootHandler = _Handler();
      final rebootSession = _Session();
      routePlayer.dispose();
      routePlayer = PlayerController(
        api,
        rebootHandler,
        audioSessionProvider: () async => rebootSession,
      );
      routePlayer.currentSong = const Song(
        id: '1',
        title: 'Route',
        artist: 'Artist',
        hash: 'ROUTE',
        source: SongSource.netease,
      );
      await Future<void>.delayed(Duration.zero);

      // 恢复上次播放列表（autoPlay）：读到断连标记 → 降级为仅预加载。
      await routePlayer.prepareRestoredSong(autoPlay: true);
      expect(rebootHandler.audioPlayer.playing, isFalse);
      expect(rebootHandler.automaticPlays, 0);

      // 用户显式播放清除断连标记并正常起播。
      await routePlayer.play();
      expect(rebootHandler.audioPlayer.playing, isTrue);
    });
  });
}
