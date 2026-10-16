// DIBUAT OTOMATIS oleh protocol/codegen/generate.mjs — JANGAN DIEDIT.
// Sumber: protocol/schema/decky-v1.json (protokol v1)
// Regenerate: node protocol/codegen/generate.mjs

// ignore_for_file: constant_identifier_names, non_constant_identifier_names

import 'dart:typed_data';

Uint8List _bytes(Object? v) =>
    v is Uint8List ? v : Uint8List.fromList((v as List).cast<int>());

enum MessageType {
  ping('ping'),
  pong('pong'),
  error('error'),
  welcome('welcome'),
  deckLayout('deck_layout'),
  deckState('deck_state'),
  deckProfiles('deck_profiles'),
  monitorTick('monitor_tick'),
  mediaState('media_state'),
  lyrics('lyrics'),
  blob('blob'),
  deckPress('deck_press'),
  deckRelease('deck_release'),
  deckSwitchProfile('deck_switch_profile'),
  pointerMove('pointer_move'),
  pointerButton('pointer_button'),
  scroll('scroll'),
  key('key'),
  text('text'),
  monitorSub('monitor_sub'),
  monitorUnsub('monitor_unsub'),
  mediaCmd('media_cmd'),
  wantBlob('want_blob');

  const MessageType(this.wire);
  final String wire;
  static MessageType fromWire(String w) =>
      MessageType.values.firstWhere((e) => e.wire == w);
}

enum Capability {
  deck('deck'),
  input('input'),
  monitor('monitor'),
  monitorCpuTemp('monitor.cpu_temp'),
  monitorGpu('monitor.gpu'),
  monitorGpuTemp('monitor.gpu_temp'),
  media('media'),
  mediaSeek('media.seek'),
  lyrics('lyrics'),
  obs('obs');

  const Capability(this.wire);
  final String wire;
  static Capability fromWire(String w) =>
      Capability.values.firstWhere((e) => e.wire == w);
}

enum ErrorCode {
  protoVersion('proto_version'),
  authFailed('auth_failed'),
  pairExpired('pair_expired'),
  pairThrottled('pair_throttled'),
  unknownAction('unknown_action'),
  actionFailed('action_failed'),
  capMissing('cap_missing'),
  internal('internal');

  const ErrorCode(this.wire);
  final String wire;
  static ErrorCode fromWire(String w) =>
      ErrorCode.values.firstWhere((e) => e.wire == w);
}

enum HelloMode {
  pair('pair'),
  session('session');

  const HelloMode(this.wire);
  final String wire;
  static HelloMode fromWire(String w) =>
      HelloMode.values.firstWhere((e) => e.wire == w);
}

enum HelloPlatform {
  android('android'),
  ios('ios'),
  web('web');

  const HelloPlatform(this.wire);
  final String wire;
  static HelloPlatform fromWire(String w) =>
      HelloPlatform.values.firstWhere((e) => e.wire == w);
}

enum WelcomeOs {
  windows('windows'),
  macos('macos'),
  linux('linux');

  const WelcomeOs(this.wire);
  final String wire;
  static WelcomeOs fromWire(String w) =>
      WelcomeOs.values.firstWhere((e) => e.wire == w);
}

enum ButtonStyle {
  normal('normal'),
  toggle('toggle');

  const ButtonStyle(this.wire);
  final String wire;
  static ButtonStyle fromWire(String w) =>
      ButtonStyle.values.firstWhere((e) => e.wire == w);
}

enum LyricsSource {
  lrcFile('lrc_file'),
  cache('cache'),
  online('online');

  const LyricsSource(this.wire);
  final String wire;
  static LyricsSource fromWire(String w) =>
      LyricsSource.values.firstWhere((e) => e.wire == w);
}

enum BlobMime {
  imagePng('image/png'),
  imageJpeg('image/jpeg'),
  imageWebp('image/webp'),
  imageSvgXml('image/svg+xml');

  const BlobMime(this.wire);
  final String wire;
  static BlobMime fromWire(String w) =>
      BlobMime.values.firstWhere((e) => e.wire == w);
}

enum MonitorSubWantItem {
  cpu('cpu'),
  cpuPerCore('cpu_per_core'),
  mem('mem'),
  net('net'),
  disk('disk'),
  gpu('gpu'),
  temp('temp');

  const MonitorSubWantItem(this.wire);
  final String wire;
  static MonitorSubWantItem fromWire(String w) =>
      MonitorSubWantItem.values.firstWhere((e) => e.wire == w);
}

enum MediaCmdCmd {
  toggle('toggle'),
  play('play'),
  pause('pause'),
  next('next'),
  prev('prev'),
  seek('seek');

  const MediaCmdCmd(this.wire);
  final String wire;
  static MediaCmdCmd fromWire(String w) =>
      MediaCmdCmd.values.firstWhere((e) => e.wire == w);
}

class Envelope {
  const Envelope({
    required this.v,
    required this.t,
    this.id,
    required this.d,
  });

  /// versi protokol
  final int v;
  final MessageType t;
  /// hanya untuk pola request/response
  final int? id;
  /// payload, bentuknya ditentukan oleh t
  final Map<String, dynamic> d;

  factory Envelope.fromMap(Map<String, dynamic> m) => Envelope(
        v: m['v'] as int,
        t: MessageType.fromWire(m['t'] as String),
        id: m['id'] as int?,
        d: m['d'] as Map<String, dynamic>,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'v': v,
        't': t.wire,
        if (id != null) 'id': id,
        'd': d,
      };
}

/// Frame plaintext pertama dari client, SEBELUM handshake Noise.
class Hello {
  const Hello({
    required this.v,
    required this.mode,
    required this.clientId,
    this.name,
    this.platform,
    this.appVersion,
  });

  final int v;
  final HelloMode mode;
  final String clientId;
  /// nama device untuk ditampilkan di host
  final String? name;
  final HelloPlatform? platform;
  final String? appVersion;

  factory Hello.fromMap(Map<String, dynamic> m) => Hello(
        v: m['v'] as int,
        mode: HelloMode.fromWire(m['mode'] as String),
        clientId: m['client_id'] as String,
        name: m['name'] as String?,
        platform: m['platform'] == null ? null : HelloPlatform.fromWire(m['platform'] as String),
        appVersion: m['app_version'] as String?,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'v': v,
        'mode': mode.wire,
        'client_id': clientId,
        if (name != null) 'name': name,
        if (platform != null) 'platform': platform?.wire,
        if (appVersion != null) 'app_version': appVersion,
      };
}

/// Balasan plaintext host atas Hello.
class HelloAck {
  const HelloAck({
    required this.v,
    required this.ok,
    this.noise,
    this.code,
  });

  final int v;
  final bool ok;
  final String? noise;
  final ErrorCode? code;

  factory HelloAck.fromMap(Map<String, dynamic> m) => HelloAck(
        v: m['v'] as int,
        ok: m['ok'] as bool,
        noise: m['noise'] as String?,
        code: m['code'] == null ? null : ErrorCode.fromWire(m['code'] as String),
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'v': v,
        'ok': ok,
        if (noise != null) 'noise': noise,
        if (code != null) 'code': code?.wire,
      };
}

class Ping {
  const Ping({
    required this.ts,
  });

  /// monotonic ms pengirim
  final int ts;

  factory Ping.fromMap(Map<String, dynamic> m) => Ping(
        ts: m['ts'] as int,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'ts': ts,
      };
}

class Error {
  const Error({
    required this.code,
    required this.msg,
  });

  final ErrorCode code;
  final String msg;

  factory Error.fromMap(Map<String, dynamic> m) => Error(
        code: ErrorCode.fromWire(m['code'] as String),
        msg: m['msg'] as String,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'code': code.wire,
        'msg': msg,
      };
}

class Welcome {
  const Welcome({
    required this.hostName,
    required this.os,
    required this.hostId,
    required this.proto,
    required this.caps,
    this.token,
  });

  final String hostName;
  final WelcomeOs os;
  final String hostId;
  final int proto;
  final List<Capability> caps;
  /// token pairing 32 byte; HANYA dikirim sekali, pada koneksi mode=pair yang sukses
  final Uint8List? token;

  factory Welcome.fromMap(Map<String, dynamic> m) => Welcome(
        hostName: m['host_name'] as String,
        os: WelcomeOs.fromWire(m['os'] as String),
        hostId: m['host_id'] as String,
        proto: m['proto'] as int,
        caps: (m['caps'] as List).map((e) => Capability.fromWire(e as String)).toList(),
        token: m['token'] == null ? null : _bytes(m['token']),
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'host_name': hostName,
        'os': os.wire,
        'host_id': hostId,
        'proto': proto,
        'caps': caps.map((e) => e.wire).toList(),
        if (token != null) 'token': token,
      };
}

class Button {
  const Button({
    required this.idx,
    required this.label,
    this.iconId,
    this.color,
    this.style,
    this.actionHint,
  });

  final int idx;
  final String label;
  /// blob_id ikon; client cache by id
  final String? iconId;
  final String? color;
  final ButtonStyle? style;
  /// teks deskriptif untuk aksesibilitas; BUKAN definisi aksi
  final String? actionHint;

  factory Button.fromMap(Map<String, dynamic> m) => Button(
        idx: m['idx'] as int,
        label: m['label'] as String,
        iconId: m['icon_id'] as String?,
        color: m['color'] as String?,
        style: m['style'] == null ? null : ButtonStyle.fromWire(m['style'] as String),
        actionHint: m['action_hint'] as String?,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'idx': idx,
        'label': label,
        if (iconId != null) 'icon_id': iconId,
        if (color != null) 'color': color,
        if (style != null) 'style': style?.wire,
        if (actionHint != null) 'action_hint': actionHint,
      };
}

class DeckLayout {
  const DeckLayout({
    required this.profileId,
    required this.name,
    required this.cols,
    required this.rows,
    required this.buttons,
  });

  final String profileId;
  final String name;
  final int cols;
  final int rows;
  final List<Button> buttons;

  factory DeckLayout.fromMap(Map<String, dynamic> m) => DeckLayout(
        profileId: m['profile_id'] as String,
        name: m['name'] as String,
        cols: m['cols'] as int,
        rows: m['rows'] as int,
        buttons: (m['buttons'] as List).map((e) => Button.fromMap((e as Map).cast<String, dynamic>())).toList(),
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'profile_id': profileId,
        'name': name,
        'cols': cols,
        'rows': rows,
        'buttons': buttons.map((e) => e.toMap()).toList(),
      };
}

class DeckState {
  const DeckState({
    required this.idx,
    required this.active,
  });

  final int idx;
  final bool active;

  factory DeckState.fromMap(Map<String, dynamic> m) => DeckState(
        idx: m['idx'] as int,
        active: m['active'] as bool,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'idx': idx,
        'active': active,
      };
}

class DeckProfiles {
  const DeckProfiles({
    required this.profiles,
    required this.active,
  });

  final List<Map<String, dynamic>> profiles;
  final String active;

  factory DeckProfiles.fromMap(Map<String, dynamic> m) => DeckProfiles(
        profiles: (m['profiles'] as List).map((e) => e as Map<String, dynamic>).toList(),
        active: m['active'] as String,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'profiles': profiles,
        'active': active,
      };
}

class Gpu {
  const Gpu({
    required this.name,
    this.util,
    this.memUsed,
    this.memTotal,
    this.temp,
  });

  final String name;
  final double? util;
  final int? memUsed;
  final int? memTotal;
  /// derajat Celsius
  final double? temp;

  factory Gpu.fromMap(Map<String, dynamic> m) => Gpu(
        name: m['name'] as String,
        util: (m['util'] as num?)?.toDouble(),
        memUsed: m['mem_used'] as int?,
        memTotal: m['mem_total'] as int?,
        temp: (m['temp'] as num?)?.toDouble(),
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'name': name,
        if (util != null) 'util': util,
        if (memUsed != null) 'mem_used': memUsed,
        if (memTotal != null) 'mem_total': memTotal,
        if (temp != null) 'temp': temp,
      };
}

class MonitorTick {
  const MonitorTick({
    required this.ts,
    required this.cpu,
    this.cpuPerCore,
    required this.memUsed,
    required this.memTotal,
    required this.netRx,
    required this.netTx,
    required this.diskR,
    required this.diskW,
    this.cpuTemp,
    this.gpu,
  });

  final int ts;
  final double cpu;
  final List<double>? cpuPerCore;
  final int memUsed;
  final int memTotal;
  /// byte/detik sejak tick sebelumnya
  final int netRx;
  final int netTx;
  final int diskR;
  final int diskW;
  /// hanya ada kalau cap monitor.cpu_temp diumumkan
  final double? cpuTemp;
  final Gpu? gpu;

  factory MonitorTick.fromMap(Map<String, dynamic> m) => MonitorTick(
        ts: m['ts'] as int,
        cpu: (m['cpu'] as num).toDouble(),
        cpuPerCore: m['cpu_per_core'] == null ? null : (m['cpu_per_core'] as List).map((e) => (e as num).toDouble()).toList(),
        memUsed: m['mem_used'] as int,
        memTotal: m['mem_total'] as int,
        netRx: m['net_rx'] as int,
        netTx: m['net_tx'] as int,
        diskR: m['disk_r'] as int,
        diskW: m['disk_w'] as int,
        cpuTemp: (m['cpu_temp'] as num?)?.toDouble(),
        gpu: m['gpu'] == null ? null : Gpu.fromMap((m['gpu'] as Map).cast<String, dynamic>()),
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'ts': ts,
        'cpu': cpu,
        if (cpuPerCore != null) 'cpu_per_core': cpuPerCore,
        'mem_used': memUsed,
        'mem_total': memTotal,
        'net_rx': netRx,
        'net_tx': netTx,
        'disk_r': diskR,
        'disk_w': diskW,
        if (cpuTemp != null) 'cpu_temp': cpuTemp,
        if (gpu != null) 'gpu': gpu?.toMap(),
      };
}

class MediaState {
  const MediaState({
    required this.playing,
    required this.title,
    required this.artist,
    this.album,
    required this.durationMs,
    required this.positionMs,
    required this.posAt,
    this.artId,
    this.app,
  });

  final bool playing;
  final String title;
  final String artist;
  final String? album;
  final int durationMs;
  final int positionMs;
  /// monotonic host ms saat position_ms diambil; client ekstrapolasi dari sini
  final int posAt;
  /// blob_id album art
  final String? artId;
  /// aplikasi sumber, mis. Spotify
  final String? app;

  factory MediaState.fromMap(Map<String, dynamic> m) => MediaState(
        playing: m['playing'] as bool,
        title: m['title'] as String,
        artist: m['artist'] as String,
        album: m['album'] as String?,
        durationMs: m['duration_ms'] as int,
        positionMs: m['position_ms'] as int,
        posAt: m['pos_at'] as int,
        artId: m['art_id'] as String?,
        app: m['app'] as String?,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'playing': playing,
        'title': title,
        'artist': artist,
        if (album != null) 'album': album,
        'duration_ms': durationMs,
        'position_ms': positionMs,
        'pos_at': posAt,
        if (artId != null) 'art_id': artId,
        if (app != null) 'app': app,
      };
}

class Lyrics {
  const Lyrics({
    required this.trackKey,
    required this.source,
    required this.lines,
  });

  /// hash artist+title; client buang lirik kalau track_key tidak cocok dengan media_state
  final String trackKey;
  final LyricsSource source;
  final List<Map<String, dynamic>> lines;

  factory Lyrics.fromMap(Map<String, dynamic> m) => Lyrics(
        trackKey: m['track_key'] as String,
        source: LyricsSource.fromWire(m['source'] as String),
        lines: (m['lines'] as List).map((e) => e as Map<String, dynamic>).toList(),
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'track_key': trackKey,
        'source': source.wire,
        'lines': lines,
      };
}

class Blob {
  const Blob({
    required this.blobId,
    required this.mime,
    required this.data,
  });

  /// hash konten; stabil, jadi client bisa cache permanen
  final String blobId;
  final BlobMime mime;
  /// byte mentah di MessagePack, base64 hanya saat direpresentasikan sebagai JSON
  final Uint8List data;

  factory Blob.fromMap(Map<String, dynamic> m) => Blob(
        blobId: m['blob_id'] as String,
        mime: BlobMime.fromWire(m['mime'] as String),
        data: _bytes(m['data']),
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'blob_id': blobId,
        'mime': mime.wire,
        'data': data,
      };
}

class DeckPress {
  const DeckPress({
    required this.idx,
  });

  final int idx;

  factory DeckPress.fromMap(Map<String, dynamic> m) => DeckPress(
        idx: m['idx'] as int,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'idx': idx,
      };
}

class DeckSwitchProfile {
  const DeckSwitchProfile({
    required this.profileId,
  });

  final String profileId;

  factory DeckSwitchProfile.fromMap(Map<String, dynamic> m) => DeckSwitchProfile(
        profileId: m['profile_id'] as String,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'profile_id': profileId,
      };
}

/// Delta relatif yang sudah di-coalesce. TIDAK PERNAH koordinat absolut.
class PointerMove {
  const PointerMove({
    required this.e,
    required this.dt,
  });

  /// pasangan [dx, dy]
  final List<List<int>> e;
  /// ms sejak batch sebelumnya; dipakai host untuk kurva akselerasi
  final int dt;

  factory PointerMove.fromMap(Map<String, dynamic> m) => PointerMove(
        e: (m['e'] as List).map((e) => (e as List).cast<int>()).toList(),
        dt: m['dt'] as int,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'e': e,
        'dt': dt,
      };
}

class PointerButton {
  const PointerButton({
    required this.btn,
    required this.down,
  });

  /// 0 kiri, 1 tengah, 2 kanan
  final int btn;
  final bool down;

  factory PointerButton.fromMap(Map<String, dynamic> m) => PointerButton(
        btn: m['btn'] as int,
        down: m['down'] as bool,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'btn': btn,
        'down': down,
      };
}

class Scroll {
  const Scroll({
    required this.dx,
    required this.dy,
  });

  final int dx;
  final int dy;

  factory Scroll.fromMap(Map<String, dynamic> m) => Scroll(
        dx: m['dx'] as int,
        dy: m['dy'] as int,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'dx': dx,
        'dy': dy,
      };
}

class Key {
  const Key({
    required this.code,
    required this.down,
    required this.mods,
  });

  /// nama W3C KeyboardEvent.code, mis. KeyA, Enter, ArrowLeft, F5
  final String code;
  final bool down;
  /// bitmask: 1 Shift, 2 Ctrl, 4 Alt, 8 Meta
  final int mods;

  factory Key.fromMap(Map<String, dynamic> m) => Key(
        code: m['code'] as String,
        down: m['down'] as bool,
        mods: m['mods'] as int,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'code': code,
        'down': down,
        'mods': mods,
      };
}

class Text {
  const Text({
    required this.s,
  });

  final String s;

  factory Text.fromMap(Map<String, dynamic> m) => Text(
        s: m['s'] as String,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        's': s,
      };
}

class MonitorSub {
  const MonitorSub({
    required this.intervalMs,
    this.want,
  });

  final int intervalMs;
  /// host kirim hanya yang diminta, untuk hemat bandwidth dan baterai
  final List<MonitorSubWantItem>? want;

  factory MonitorSub.fromMap(Map<String, dynamic> m) => MonitorSub(
        intervalMs: m['interval_ms'] as int,
        want: m['want'] == null ? null : (m['want'] as List).map((e) => MonitorSubWantItem.fromWire(e as String)).toList(),
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'interval_ms': intervalMs,
        if (want != null) 'want': want?.map((e) => e.wire).toList(),
      };
}

class MonitorUnsub {
  const MonitorUnsub();


  factory MonitorUnsub.fromMap(Map<String, dynamic> m) => MonitorUnsub(
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
      };
}

class MediaCmd {
  const MediaCmd({
    required this.cmd,
    this.arg,
  });

  final MediaCmdCmd cmd;
  /// posisi target dalam ms, hanya untuk seek
  final int? arg;

  factory MediaCmd.fromMap(Map<String, dynamic> m) => MediaCmd(
        cmd: MediaCmdCmd.fromWire(m['cmd'] as String),
        arg: m['arg'] as int?,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'cmd': cmd.wire,
        if (arg != null) 'arg': arg,
      };
}

class WantBlob {
  const WantBlob({
    required this.blobId,
  });

  final String blobId;

  factory WantBlob.fromMap(Map<String, dynamic> m) => WantBlob(
        blobId: m['blob_id'] as String,
      );

  Map<String, dynamic> toMap() => <String, dynamic>{
        'blob_id': blobId,
      };
}

/// Nama tipe pesan, persis seperti di kawat.
abstract final class MsgType {
  static const String ping = 'ping';
  static const String pong = 'pong';
  static const String error = 'error';
  static const String welcome = 'welcome';
  static const String deckLayout = 'deck_layout';
  static const String deckState = 'deck_state';
  static const String deckProfiles = 'deck_profiles';
  static const String monitorTick = 'monitor_tick';
  static const String mediaState = 'media_state';
  static const String lyrics = 'lyrics';
  static const String blob = 'blob';
  static const String deckPress = 'deck_press';
  static const String deckRelease = 'deck_release';
  static const String deckSwitchProfile = 'deck_switch_profile';
  static const String pointerMove = 'pointer_move';
  static const String pointerButton = 'pointer_button';
  static const String scroll = 'scroll';
  static const String key = 'key';
  static const String text = 'text';
  static const String monitorSub = 'monitor_sub';
  static const String monitorUnsub = 'monitor_unsub';
  static const String mediaCmd = 'media_cmd';
  static const String wantBlob = 'want_blob';
}

/// Payload yang dikirim host ke client.
const Set<String> hostToClientTypes = {'ping', 'pong', 'error', 'welcome', 'deck_layout', 'deck_state', 'deck_profiles', 'monitor_tick', 'media_state', 'lyrics', 'blob'};
/// Payload yang dikirim client ke host.
const Set<String> clientToHostTypes = {'ping', 'pong', 'error', 'deck_press', 'deck_release', 'deck_switch_profile', 'pointer_move', 'pointer_button', 'scroll', 'key', 'text', 'monitor_sub', 'monitor_unsub', 'media_cmd', 'want_blob'};

const int protocolVersion = 1;
const int defaultPort = 8787;
