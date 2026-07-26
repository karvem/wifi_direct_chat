import 'dart:async';
import 'dart:collection';
import 'dart:convert' hide Codec;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_p2p_connection/flutter_p2p_connection.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:encryptify/encryptify.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:file_picker/file_picker.dart';
import 'package:open_file/open_file.dart';
import 'package:share_plus/share_plus.dart';
import 'package:cross_file/cross_file.dart';

// ═══════════════════════════════════════════════════════════════════════════════
//  MODELS
// ═══════════════════════════════════════════════════════════════════════════════

@HiveType(typeId: 0)
class Contact {
  @HiveField(0)
  final String uniqueId;
  @HiveField(1)
  String displayName;
  @HiveField(2)
  String? deviceAddress;
  @HiveField(3)
  String? rsaPublicKey;
  @HiveField(4)
  DateTime lastSeen;
  @HiveField(5)
  bool isBlocked;
  @HiveField(6)
  String? avatarBase64;

  Contact({
    required this.uniqueId,
    required this.displayName,
    this.deviceAddress,
    this.rsaPublicKey,
    required this.lastSeen,
    this.isBlocked = false,
    this.avatarBase64,
  });
}

@HiveType(typeId: 1)
class ChatMessage {
  @HiveField(0)
  final String id;
  @HiveField(1)
  final String contactId;
  @HiveField(2)
  final String text;
  @HiveField(3)
  final bool isMine;
  @HiveField(4)
  final DateTime timestamp;
  @HiveField(5)
  List<String> reactions;
  @HiveField(6)
  final String type; // 'text' | 'voice' | 'file'
  @HiveField(7)
  final String? filePath;
  @HiveField(8)
  final String? fileName;
  @HiveField(9)
  bool isRead;
  @HiveField(10)
  String status; // 'sending', 'sent', 'delivered', 'read', 'pending'

  ChatMessage({
    required this.id,
    required this.contactId,
    required this.text,
    required this.isMine,
    required this.timestamp,
    List<String>? reactions,
    this.type = 'text',
    this.filePath,
    this.fileName,
    this.isRead = false,
    this.status = 'sending',
  }) : reactions = reactions ?? [];
}

// ═══════════════════════════════════════════════════════════════════════════════
//  HIVE ADAPTERS
// ═══════════════════════════════════════════════════════════════════════════════

class ContactAdapter extends TypeAdapter<Contact> {
  @override
  final int typeId = 0;

  @override
  Contact read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Contact(
      uniqueId: fields[0] as String,
      displayName: fields[1] as String,
      deviceAddress: fields[2] as String?,
      rsaPublicKey: fields[3] as String?,
      lastSeen: fields[4] as DateTime,
      isBlocked: fields[5] as bool? ?? false,
      avatarBase64: fields[6] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, Contact obj) {
    writer
      ..writeByte(7)
      ..writeByte(0)..write(obj.uniqueId)
      ..writeByte(1)..write(obj.displayName)
      ..writeByte(2)..write(obj.deviceAddress)
      ..writeByte(3)..write(obj.rsaPublicKey)
      ..writeByte(4)..write(obj.lastSeen)
      ..writeByte(5)..write(obj.isBlocked)
      ..writeByte(6)..write(obj.avatarBase64);
  }
}

class ChatMessageAdapter extends TypeAdapter<ChatMessage> {
  @override
  final int typeId = 1;

  @override
  ChatMessage read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ChatMessage(
      id: fields[0] as String,
      contactId: fields[1] as String,
      text: fields[2] as String,
      isMine: fields[3] as bool,
      timestamp: fields[4] as DateTime,
      reactions: (fields[5] as List?)?.cast<String>() ?? [],
      type: fields[6] as String? ?? 'text',
      filePath: fields[7] as String?,
      fileName: fields[8] as String?,
      isRead: fields[9] as bool? ?? false,
      status: fields[10] as String? ?? 'sending',
    );
  }

  @override
  void write(BinaryWriter writer, ChatMessage obj) {
    writer
      ..writeByte(11)
      ..writeByte(0)..write(obj.id)
      ..writeByte(1)..write(obj.contactId)
      ..writeByte(2)..write(obj.text)
      ..writeByte(3)..write(obj.isMine)
      ..writeByte(4)..write(obj.timestamp)
      ..writeByte(5)..write(obj.reactions)
      ..writeByte(6)..write(obj.type)
      ..writeByte(7)..write(obj.filePath)
      ..writeByte(8)..write(obj.fileName)
      ..writeByte(9)..write(obj.isRead)
      ..writeByte(10)..write(obj.status);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MESSAGE ENVELOPE
// ═══════════════════════════════════════════════════════════════════════════════

class Envelope {
  final String type;
  final String id;
  final String senderId;
  final String senderName;
  final String? to;
  final int timestamp;
  final Map<String, dynamic> data;

  Envelope({
    required this.type,
    String? id,
    required this.senderId,
    required this.senderName,
    this.to,
    int? timestamp,
    this.data = const {},
  })  : id = id ?? const Uuid().v4(),
        timestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch;

  String encode() => jsonEncode({
        'type': type,
        'id': id,
        'senderId': senderId,
        'senderName': senderName,
        'to': to,
        'timestamp': timestamp,
        'data': data,
      });

  static Envelope? tryDecode(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if (map['type'] == null || map['senderId'] == null) return null;
      return Envelope(
        type: map['type'] as String,
        id: map['id'] as String? ?? const Uuid().v4(),
        senderId: map['senderId'] as String,
        senderName: map['senderName'] as String? ?? 'Unknown',
        to: map['to'] as String?,
        timestamp: map['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch,
        data: (map['data'] as Map?)?.cast<String, dynamic>() ?? {},
      );
    } catch (_) {
      return null;
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  ENCRYPTION SERVICE
// ═══════════════════════════════════════════════════════════════════════════════

class EncryptionService {
  static final _storage = FlutterSecureStorage();
  static const String _myPrivateKeyKey = 'my_rsa_private_key';
  static const String _myPublicKeyKey = 'my_rsa_public_key';
  static const String _myDeviceIdKey = 'my_device_id';
  static const String _myDisplayNameKey = 'my_display_name';

  static Future<String> getMyDeviceId() async {
    String? id = await _storage.read(key: _myDeviceIdKey);
    if (id == null) {
      id = const Uuid().v4();
      await _storage.write(key: _myDeviceIdKey, value: id);
    }
    return id;
  }

  static Future<String> getMyDisplayName() async {
    final existing = await _storage.read(key: _myDisplayNameKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = await getMyDeviceId();
    final generated = 'Guest-${id.substring(0, math.min(4, id.length)).toUpperCase()}';
    await _storage.write(key: _myDisplayNameKey, value: generated);
    return generated;
  }

  static Future<void> setMyDisplayName(String name) async {
    await _storage.write(key: _myDisplayNameKey, value: name);
  }

  static Future<void> ensureKeys() async {
    String? privateKey = await _storage.read(key: _myPrivateKeyKey);
    if (privateKey == null) {
      await Encryptify.generateKeys();
      final keys = await Encryptify.returnKeys();
      await _storage.write(key: _myPublicKeyKey, value: keys.rsaPublicKey);
      await _storage.write(key: _myPrivateKeyKey, value: keys.rsaPrivateKey);
    }
  }

  static Future<String?> getMyPublicKey() async => await _storage.read(key: _myPublicKeyKey);
  static Future<String?> getMyPrivateKey() async => await _storage.read(key: _myPrivateKeyKey);

  static Future<Map<String, String>> encryptMessage(String plaintext, String recipientPublicKey) async {
    final result = await Encryptify.encryptMessage(message: plaintext, recipientRSAPublicKey: recipientPublicKey);
    return {
      'encryptedMessage': result.encryptedMessage,
      'encryptedAESKey': result.encryptedAesKey,
      'encryptedIV': result.encryptedIV,
    };
  }

  static Future<String> decryptMessage(
    String encryptedMessage,
    String encryptedAESKey,
    String encryptedIV,
    String senderId,
  ) async {
    final privateKey = await getMyPrivateKey();
    if (privateKey == null) throw Exception('No private key');
    return await Encryptify.decryptMessage(
      currentUserID: await getMyDeviceId(),
      senderID: senderId,
      encryptedMessage: encryptedMessage,
      recipientencryptedAESKey: encryptedAESKey,
      recipientencryptedIV: encryptedIV,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  NETWORK — self-reported LAN IP
// ═══════════════════════════════════════════════════════════════════════════════

class LanIp {
  static Future<String?> discover() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      String? fallback;
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          fallback ??= addr.address;
          if (addr.address.startsWith('192.168.49.')) return addr.address;
        }
      }
      return fallback;
    } catch (_) {
      return null;
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  SETTINGS
// ═══════════════════════════════════════════════════════════════════════════════

enum CallQuality { low, medium, high, stereoHd }

extension CallQualityX on CallQuality {
  String get label => switch (this) {
        CallQuality.low => 'Low · 16kHz mono',
        CallQuality.medium => 'Medium · 24kHz mono',
        CallQuality.high => 'High · 44.1kHz mono',
        CallQuality.stereoHd => 'Stereo HD · 48kHz stereo',
      };
  int get sampleRate => switch (this) {
        CallQuality.low => 16000,
        CallQuality.medium => 24000,
        CallQuality.high => 44100,
        CallQuality.stereoHd => 48000,
      };
  int get numChannels => this == CallQuality.stereoHd ? 2 : 1;
}

enum VoiceEffect { normal, minion, slowMo }

const List<List<Color>> kPalettes = [
  [Color(0xFF7C4DFF), Color(0xFF00E5FF), Color(0xFFFF4D8D)],
  [Color(0xFFFF9500), Color(0xFFFF3B30), Color(0xFFFFD60A)],
  [Color(0xFF34C759), Color(0xFF00E5FF), Color(0xFFAEEA00)],
  [Color(0xFF5E5CE6), Color(0xFFBF5AF2), Color(0xFF64D2FF)],
  [Color(0xFFFF375F), Color(0xFFFF9F0A), Color(0xFF7C4DFF)],
];
const List<String> kPaletteNames = ['Nebula', 'Sunset', 'Meadow', 'Aurora', 'Candy'];

class SettingsService {
  static final _storage = FlutterSecureStorage();

  static Future<bool> getIsDark() async => (await _storage.read(key: 'is_dark')) != 'false';
  static Future<void> setIsDark(bool v) => _storage.write(key: 'is_dark', value: v.toString());

  static Future<int> getPaletteIndex() async {
    final v = int.tryParse(await _storage.read(key: 'palette') ?? '0') ?? 0;
    return v.clamp(0, kPalettes.length - 1);
  }

  static Future<void> setPaletteIndex(int i) => _storage.write(key: 'palette', value: i.toString());
  static Future<String?> getAvatar() => _storage.read(key: 'avatar_b64');
  static Future<void> setAvatar(String b64) => _storage.write(key: 'avatar_b64', value: b64);

  static Future<CallQuality> getCallQuality() async {
    final v = await _storage.read(key: 'call_quality');
    return CallQuality.values.firstWhere((q) => q.name == v, orElse: () => CallQuality.medium);
  }

  static Future<void> setCallQuality(CallQuality q) => _storage.write(key: 'call_quality', value: q.name);
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MAIN
// ═══════════════════════════════════════════════════════════════════════════════

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  Hive.registerAdapter(ContactAdapter());
  Hive.registerAdapter(ChatMessageAdapter());
  try {
    await Hive.openBox<Contact>('contacts');
    await Hive.openBox<ChatMessage>('messages');
  } catch (_) {
    await Hive.deleteBoxFromDisk('contacts');
    await Hive.deleteBoxFromDisk('messages');
    await Hive.openBox<Contact>('contacts');
    await Hive.openBox<ChatMessage>('messages');
  }
  runApp(const WifiDirectApp());
}

class WifiDirectApp extends StatelessWidget {
  const WifiDirectApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Wi-Fi Direct Chat',
      debugShowCheckedModeBanner: false,
      home: HomeScreen(),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  GLASS SYSTEM
// ═══════════════════════════════════════════════════════════════════════════════

class GlassPanel extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final double blur;
  final double opacity;
  final EdgeInsetsGeometry? margin;
  final Color tint;
  final bool isDark;

  const GlassPanel({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.blur = 14,
    this.opacity = 0.16,
    this.margin,
    this.tint = Colors.white,
    this.isDark = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: borderRadius,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  tint.withOpacity((opacity + 0.08).clamp(0.0, 1.0)),
                  tint.withOpacity((opacity * 0.5).clamp(0.0, 1.0)),
                ],
              ),
              border: Border.all(color: Colors.white.withOpacity(isDark ? 0.22 : 0.6), width: 1),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(isDark ? 0.28 : 0.10), blurRadius: 20, offset: const Offset(0, 8)),
              ],
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class GlassLite extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final double opacity;
  final EdgeInsetsGeometry? margin;
  final Color tint;
  final bool isDark;

  const GlassLite({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.opacity = 0.14,
    this.margin,
    this.tint = Colors.white,
    this.isDark = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            tint.withOpacity((opacity + 0.10).clamp(0.0, 1.0)),
            tint.withOpacity((opacity * 0.55).clamp(0.0, 1.0)),
          ],
        ),
        border: Border.all(color: Colors.white.withOpacity(isDark ? 0.14 : 0.5), width: 1),
      ),
      child: child,
    );
  }
}

class PulseSignal extends ChangeNotifier {
  void fire() => notifyListeners();
}

class _AnimatedMeshBackground extends StatefulWidget {
  final PulseSignal pulseSignal;
  final List<Color> palette;
  final bool isDark;
  const _AnimatedMeshBackground({required this.pulseSignal, required this.palette, required this.isDark});

  @override
  State<_AnimatedMeshBackground> createState() => _AnimatedMeshBackgroundState();
}

class _AnimatedMeshBackgroundState extends State<_AnimatedMeshBackground> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) _controller.reverse();
    });
    widget.pulseSignal.addListener(_onPulse);
  }

  void _onPulse() {
    if (!mounted) return;
    _controller.forward(from: 0);
  }

  @override
  void didUpdateWidget(covariant _AnimatedMeshBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pulseSignal != widget.pulseSignal) {
      oldWidget.pulseSignal.removeListener(_onPulse);
      widget.pulseSignal.addListener(_onPulse);
    }
  }

  @override
  void dispose() {
    widget.pulseSignal.removeListener(_onPulse);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final bg = widget.isDark ? const Color(0xFF0A0A14) : const Color(0xFFF2F1F8);
    final colors = widget.palette;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final wobble = math.sin(math.pi * _controller.value);
          return Stack(
            children: [
              Container(color: bg),
              _blob(size.width * 0.25 + 30 * wobble, size.height * 0.18 - 20 * wobble, 260, colors[0]),
              _blob(size.width * 0.85 - 25 * wobble, size.height * 0.35 + 30 * wobble, 240, colors[1]),
              _blob(size.width * 0.3 + 25 * wobble, size.height * 0.82 - 15 * wobble, 280, colors[2]),
            ],
          );
        },
      ),
    );
  }

  Widget _blob(double x, double y, double diameter, Color color) {
    return Positioned(
      left: x - diameter / 2,
      top: y - diameter / 2,
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color.withOpacity(widget.isDark ? 0.55 : 0.35), color.withOpacity(0.0)]),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  HOME SCREEN
// ═══════════════════════════════════════════════════════════════════════════════

enum P2pRole { none, host, client }
enum CallPhase { idle, outgoingRinging, incomingRinging, active }
const int kCallPort = 45820;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _textController = TextEditingController();
  late Box<Contact> _contactBox;
  late Box<ChatMessage> _messageBox;

  final FlutterP2pHost _host = FlutterP2pHost();
  final FlutterP2pClient _client = FlutterP2pClient();

  String _myDeviceId = '';
  String? _myPublicKey;
  String _myDisplayName = '';
  String? _myAvatarBase64;
  String? _myLanIp;

  P2pRole _role = P2pRole.none;
  bool _isConnected = false;
  String _status = 'Initializing…';

  List<ChatMessage> _messages = [];
  List<dynamic> _discoveredHosts = [];
  List<P2pClientInfo> _groupClients = [];
  Contact? _selectedContact;

  final Set<String> _helloedTo = {};
  final Map<String, Envelope> _pendingFileNotices = {};
  final Map<String, ReceivableFileInfo> _pendingReceivableInfo = {};
  final Set<String> _handledFileIds = {};

  final FlutterSoundRecorder _audioRecorder = FlutterSoundRecorder();
  final FlutterSoundPlayer _audioPlayer = FlutterSoundPlayer();
  final FlutterSoundPlayer _callPlayer = FlutterSoundPlayer(); // legacy, not used for calls
  bool _isRecordingVoiceMessage = false;
  String? _playingMessageId;

  final PulseSignal _pulseSignal = PulseSignal();
  bool _isDark = true;
  int _paletteIndex = 0;
  List<Color> get _palette => kPalettes[_paletteIndex];
  Color get _fg => _isDark ? Colors.white : Colors.black87;
  Color get _fgDim => _isDark ? Colors.white54 : Colors.black45;
  Color get _fgFaint => _isDark ? Colors.white38 : Colors.black38;

  // Call state
  CallPhase _callPhase = CallPhase.idle;
  Contact? _callPeer;
  String _callId = '';
  CallQuality _callQuality = CallQuality.medium;
  CallQuality _activeCallQuality = CallQuality.medium;
  Timer? _ringTimer;
  Timer? _callTimeoutTimer;
  RawDatagramSocket? _callSocket;
  StreamSubscription? _callSocketSub;
  StreamController<Uint8List>? _micStreamController;
  StreamSubscription? _micStreamSub;
  bool _isPlaying = false;
  int _dbgMicPacketsSent = 0;
  int _dbgUdpPacketsRecv = 0;

  // flutter_pcm_sound drift-free playback
  bool _pcmSoundReady = false;
  final List<int> _pcmFeedBuffer = [];

  // Offline detection
  Timer? _heartbeatTimer;
  int _consecutivePingFailures = 0;
  static const int _maxPingFailures = 3;
  bool _isPeerOnline = false;

  // Typing indicator
  Timer? _typingDebounceTimer;
  bool _isTyping = false;
  VoiceEffect _voiceEffect = VoiceEffect.normal;

  // Pending messages
  final Map<String, ChatMessage> _pendingMessages = {};
  Timer? _offlineRetryTimer;

  // File transfer progress
  Map<String, double> _fileTransferProgress = {};
  Map<String, CancelToken> _fileTransferCancelTokens = {};

  StreamSubscription? _hostStateSub;
  StreamSubscription? _clientStateSub;
  StreamSubscription? _hostClientsSub;
  StreamSubscription? _hostTextSub;
  StreamSubscription? _clientTextSub;
  StreamSubscription? _hostFilesSub;
  StreamSubscription? _clientFilesSub;
  StreamSubscription? _scanSub;

  // ─────────────────────────────────────────────────────────────────────────────
  //  LIFECYCLE
  // ─────────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _requestPermissions();

    _contactBox = Hive.box<Contact>('contacts');
    _messageBox = Hive.box<ChatMessage>('messages');
    _loadMessages();

    _myDeviceId = await EncryptionService.getMyDeviceId();
    await EncryptionService.ensureKeys();
    _myPublicKey = await EncryptionService.getMyPublicKey();
    _myDisplayName = await EncryptionService.getMyDisplayName();
    _myAvatarBase64 = await SettingsService.getAvatar();
    _isDark = await SettingsService.getIsDark();
    _paletteIndex = await SettingsService.getPaletteIndex();
    _callQuality = await SettingsService.getCallQuality();

    await _audioRecorder.openRecorder();
    await _audioPlayer.openPlayer();
    await _callPlayer.openPlayer();

    await _host.initialize();
    await _client.initialize();

    setState(() => _status = 'Ready — choose Host or Join');
  }

  Future<void> _requestPermissions() async {
    await Permission.microphone.request();
  }

  // ─────────────────────────────────────────────────────────────────────────────
  //  HOST ROLE
  // ─────────────────────────────────────────────────────────────────────────────

  Future<void> _startAsHost() async {
    setState(() => _status = 'Starting as Host…');
    try {
      if (!await _host.checkP2pPermissions()) await _host.askP2pPermissions();
      if (!await _host.checkBluetoothPermissions()) await _host.askBluetoothPermissions();
      if (!await _host.checkStoragePermission()) await _host.askStoragePermission();
      if (!await _host.checkWifiEnabled()) await _host.enableWifiServices();
      if (!await _host.checkLocationEnabled()) await _host.enableLocationServices();
      if (!await _host.checkBluetoothEnabled()) await _host.enableBluetoothServices();

      final state = await _host.createGroup(advertise: true);
      _myLanIp = await LanIp.discover();
      setState(() {
        _role = P2pRole.host;
        _status = 'Host active — SSID: ${state.ssid ?? '…'}';
      });
      _listenAsHost();
    } catch (e) {
      setState(() => _status = 'Could not start host: $e');
    }
  }

  void _listenAsHost() {
    _hostStateSub = _host.streamHotspotState().listen((state) {
      setState(() {
        _isConnected = state.isActive;
        if (!state.isActive && state.failureReason != null) {
          _status = 'Host failed: ${state.failureReason}';
        } else if (state.isActive) {
          _status = 'Hosting — ${_contactBox.length} contact(s) known';
        }
      });
    });

    _hostClientsSub = _host.streamClientList().listen((clients) {
      final grew = clients.length > _groupClients.length;
      setState(() => _groupClients = clients);
      if (grew) _sendHello();
    });

    _hostTextSub = _host.streamReceivedTexts().listen(_onRawTextReceived);
    _hostFilesSub = _host.streamReceivedFilesInfo().listen(_onReceivedFilesInfo);
  }

  // ─────────────────────────────────────────────────────────────────────────────
  //  CLIENT ROLE
  // ─────────────────────────────────────────────────────────────────────────────

  Future<void> _startAsClient() async {
    setState(() => _status = 'Starting as Client…');
    try {
      if (!await _client.checkP2pPermissions()) await _client.askP2pPermissions();
      if (!await _client.checkBluetoothPermissions()) await _client.askBluetoothPermissions();
      if (!await _client.checkStoragePermission()) await _client.askStoragePermission();
      if (!await _client.checkWifiEnabled()) await _client.enableWifiServices();
      if (!await _client.checkLocationEnabled()) await _client.enableLocationServices();
      if (!await _client.checkBluetoothEnabled()) await _client.enableBluetoothServices();

      setState(() => _role = P2pRole.client);
      _listenAsClient();

      _scanSub = await _client.startScan((devices) {
        setState(() => _discoveredHosts = devices);
      });

      setState(() => _status = 'Scanning for hosts…');
    } catch (e) {
      setState(() => _status = 'Could not start client: $e');
    }
  }

  void _listenAsClient() {
    _clientStateSub = _client.streamHotspotState().listen((state) async {
      final wasConnected = _isConnected;
      setState(() {
        _isConnected = state.isActive;
        _status = state.isActive ? 'Connected to ${state.hostSsid ?? 'host'}' : 'Disconnected / Scanning…';
      });
      if (!wasConnected && state.isActive) {
        _myLanIp = await LanIp.discover();
        _sendHello();
      }
    });

    _clientTextSub = _client.streamReceivedTexts().listen(_onRawTextReceived);
    _clientFilesSub = _client.streamReceivedFilesInfo().listen(_onReceivedFilesInfo);
  }

  // ─────────────────────────────────────────────────────────────────────────────
  //  CONNECTION (Client → Host)
  // ─────────────────────────────────────────────────────────────────────────────

  Future<void> _connectToHost(dynamic device) async {
    final name = device?.deviceName?.toString() ?? device?.name?.toString() ?? 'Unknown Host';
    setState(() => _status = 'Connecting to $name…');
    try {
      await _client.connectWithDevice(device);
      setState(() => _status = 'Connected — exchanging device info…');
    } catch (e) {
      setState(() => _status = 'Connection failed: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────
  //  PROTOCOL — hello / handshake
  // ─────────────────────────────────────────────────────────────────────────────

  Future<void> _sendEnvelope(Envelope env) async {
    final raw = env.encode();
    if (_role == P2pRole.host) {
      await _host.broadcastText(raw);
    } else if (_role == P2pRole.client) {
      await _client.broadcastText(raw);
    }
  }

  Future<void> _sendHello() async {
    if (_myPublicKey == null) return;
    final env = Envelope(
      type: 'hello',
      senderId: _myDeviceId,
      senderName: _myDisplayName,
      data: {'publicKey': _myPublicKey, 'avatar': _myAvatarBase64, 'ip': _myLanIp},
    );
    try {
      await _sendEnvelope(env);
    } catch (e) {
      debugPrint('HELLO SEND ERROR: $e');
    }
  }

  Future<void> _handleHelloEnvelope(Envelope env) async {
    final publicKey = env.data['publicKey'] as String?;
    final avatar = env.data['avatar'] as String?;
    final ip = env.data['ip'] as String?;
    final existing = _contactBox.get(env.senderId);
    final contact = Contact(
      uniqueId: env.senderId,
      displayName: env.senderName,
      deviceAddress: ip ?? existing?.deviceAddress,
      rsaPublicKey: publicKey ?? existing?.rsaPublicKey,
      lastSeen: DateTime.now(),
      isBlocked: existing?.isBlocked ?? false,
      avatarBase64: avatar ?? existing?.avatarBase64,
    );
    await _contactBox.put(env.senderId, contact);
    _refresh();

    if (_selectedContact?.uniqueId == env.senderId) setState(() => _selectedContact = contact);
    if (_callPeer?.uniqueId == env.senderId) _callPeer = contact;

    if (!_helloedTo.contains(env.senderId)) {
      _helloedTo.add(env.senderId);
      await _sendHello();
    }

    if (_selectedContact?.uniqueId == env.senderId) {
      _startHeartbeat();
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────
  //  HEARTBEAT
  // ─────────────────────────────────────────────────────────────────────────────

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _consecutivePingFailures = 0;
    _isPeerOnline = true;
    _updateOfflineStatus();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) => _sendPing());
    debugPrint('Heartbeat started');
    _sendPing();
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _consecutivePingFailures = 0;
    _isPeerOnline = false;
    _updateOfflineStatus();
    debugPrint('Heartbeat stopped');
  }

  Future<void> _sendPing() async {
    if (_selectedContact == null) return;
    _consecutivePingFailures++;
    debugPrint('Ping attempt #$_consecutivePingFailures');
    if (_consecutivePingFailures > _maxPingFailures) {
      if (_isPeerOnline) {
        _isPeerOnline = false;
        _updateOfflineStatus();
        if (_callPhase != CallPhase.idle) {
          _endCall(reason: 'Peer went offline');
        }
        debugPrint('Peer marked OFFLINE after $_consecutivePingFailures failures');
      }
      return;
    }
    final env = Envelope(
      type: 'ping',
      senderId: _myDeviceId,
      senderName: _myDisplayName,
      to: _selectedContact!.uniqueId,
      data: {'timestamp': DateTime.now().millisecondsSinceEpoch},
    );
    try {
      await _sendEnvelope(env);
      debugPrint('Ping sent');
    } catch (e) {
      debugPrint('Failed to send ping: $e');
    }
  }

  void _handlePing(Envelope env) {
    final pong = Envelope(
      type: 'pong',
      senderId: _myDeviceId,
      senderName: _myDisplayName,
      to: env.senderId,
      data: {'timestamp': DateTime.now().millisecondsSinceEpoch},
    );
    _sendEnvelope(pong);
    debugPrint('Pong sent in reply to ping from ${env.senderId}');
  }

  void _handlePong(Envelope env) {
    if (_consecutivePingFailures > 0) {
      debugPrint('Pong received, resetting failure counter (was $_consecutivePingFailures)');
    }
    _consecutivePingFailures = 0;
    if (!_isPeerOnline) {
      _isPeerOnline = true;
      _updateOfflineStatus();
      _deliverPendingMessages();
      debugPrint('Peer back online');
    }
    _isPeerOnline = true;
  }

  void _updateOfflineStatus() {
    setState(() {});
    if (!_isPeerOnline && _callPhase != CallPhase.idle) {
      _endCall(reason: 'Peer went offline');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────
  //  TYPING INDICATOR
  // ─────────────────────────────────────────────────────────────────────────────

  void _onTextChanged(String text) {
    if (_selectedContact == null) return;
    _typingDebounceTimer?.cancel();
    if (text.isNotEmpty) {
      _sendTyping();
      _typingDebounceTimer = Timer(const Duration(seconds: 3), () => _sendTyping(stop: true));
    } else {
      _sendTyping(stop: true);
    }
  }

  Future<void> _sendTyping({bool stop = false}) async {
    if (_selectedContact == null) return;
    final env = Envelope(
      type: 'typing',
      senderId: _myDeviceId,
      senderName: _myDisplayName,
      to: _selectedContact!.uniqueId,
      data: {'typing': !stop},
    );
    try {
      await _sendEnvelope(env);
    } catch (_) {}
  }

  void _handleTyping(Envelope env) {
    final typing = env.data['typing'] as bool? ?? false;
    setState(() {
      _isTyping = typing;
    });
  }

  // ─────────────────────────────────────────────────────────────────────────────
  //  PENDING MESSAGES (offline queue)
  // ─────────────────────────────────────────────────────────────────────────────

  Future<void> _enqueuePendingMessage(ChatMessage msg) async {
    _pendingMessages[msg.id] = msg;
    msg.status = 'pending';
    await _messageBox.put(msg.id, msg);
    setState(() {});
    _offlineRetryTimer?.cancel();
    _offlineRetryTimer = Timer(const Duration(seconds: 10), _trySendPending);
  }

  Future<void> _trySendPending() async {
    if (_isPeerOnline && _selectedContact != null) {
      final pending = _pendingMessages.values.toList();
      for (final msg in pending) {
        final env = Envelope(
          type: 'text',
          senderId: _myDeviceId,
          senderName: _myDisplayName,
          to: _selectedContact!.uniqueId,
          data: {'enc': false, 'text': msg.text},
        );
        try {
          await _sendEnvelope(env);
          msg.status = 'sent';
          await _messageBox.put(msg.id, msg);
          _pendingMessages.remove(msg.id);
          setState(() {});
        } catch (_) {}
      }
      _pulseSignal.fire();
    }
  }

  Future<void> _deliverPendingMessages() async {
    await _trySendPending();
  }

  // ─────────────────────────────────────────────────────────────────────────────
  //  PROTOCOL — dispatch
  // ─────────────────────────────────────────────────────────────────────────────

  void _onRawTextReceived(String raw) {
    final env = Envelope.tryDecode(raw);
    if (env == null || env.senderId == _myDeviceId) return;

    final knownSender = _contactBox.get(env.senderId);
    if (knownSender != null && knownSender.isBlocked && env.type != 'hello') return;

    switch (env.type) {
      case 'hello':
        _handleHelloEnvelope(env);
        break;
      case 'ping':
        _handlePing(env);
        break;
      case 'pong':
        _handlePong(env);
        break;
      case 'typing':
        _handleTyping(env);
        break;
      case 'text':
        _handleTextEnvelope(env);
        break;
      case 'reaction':
        _handleReactionEnvelope(env);
        break;
      case 'read_receipt':
        _handleReadReceiptEnvelope(env);
        break;
      case 'delivery_receipt':
        _handleDeliveryReceipt(env);
        break;
      case 'file_notice':
        _handleFileNoticeEnvelope(env);
        break;
      case 'call_invite':
        _handleCallInvite(env);
        break;
      case 'call_accept':
        _handleCallAccept(env);
        break;
      case 'call_reject':
        _handleCallReject(env);
        break;
      case 'call_end':
        _handleCallEnd(env);
        break;
      case 'call_force_start':
        _handleCallForceStart(env);
        break;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────
  //  TEXT MESSAGES – SEND & RECEIVE
  // ─────────────────────────────────────────────────────────────────────────────

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _selectedContact == null) return;
    final peer = _selectedContact!;

    Map<String, dynamic> data;
    if (peer.rsaPublicKey != null && peer.rsaPublicKey!.isNotEmpty) {
      try {
        final enc = await EncryptionService.encryptMessage(text, peer.rsaPublicKey!);
        data = {'enc': true, ...enc};
      } catch (e) {
        data = {'enc': false, 'text': text};
      }
    } else {
      data = {'enc': false, 'text': text};
    }

    final env = Envelope(type: 'text', senderId: _myDeviceId, senderName: _myDisplayName, to: peer.uniqueId, data: data);
    final msg = ChatMessage(
      id: env.id,
      contactId: peer.uniqueId,
      text: text,
      isMine: true,
      timestamp: DateTime.fromMillisecondsSinceEpoch(env.timestamp),
      status: _isPeerOnline ? 'sending' : 'pending',
    );
    setState(() {
      _messages.add(msg);
      _textController.clear();
    });
    await _messageBox.put(msg.id, msg);
    _pulseSignal.fire();

    if (_isPeerOnline) {
      try {
        await _sendEnvelope(env);
        msg.status = 'sent';
        await _messageBox.put(msg.id, msg);
        final idx = _messages.indexWhere((m) => m.id == msg.id);
        if (idx != -1) setState(() => _messages[idx] = msg);
        _pulseSignal.fire();
      } catch (e) {
        setState(() => _status = 'Send failed: $e');
        msg.status = 'pending';
        await _messageBox.put(msg.id, msg);
        _pendingMessages[msg.id] = msg;
        _offlineRetryTimer?.cancel();
        _offlineRetryTimer = Timer(const Duration(seconds: 10), _trySendPending);
      }
    } else {
      _pendingMessages[msg.id] = msg;
      _offlineRetryTimer?.cancel();
      _offlineRetryTimer = Timer(const Duration(seconds: 10), _trySendPending);
    }
  }

  Future<void> _handleTextEnvelope(Envelope env) async {
    if (env.to != null && env.to != _myDeviceId) return;

    String plainText;
    if (env.data['enc'] == true) {
      try {
        plainText = await EncryptionService.decryptMessage(
          env.data['encryptedMessage'] as String,
          env.data['encryptedAESKey'] as String,
          env.data['encryptedIV'] as String,
          env.senderId,
        );
      } catch (e) {
        plainText = '🔒 Could not decrypt this message';
      }
    } else {
      plainText = env.data['text'] as String? ?? '';
    }

    final msg = ChatMessage(
      id: env.id,
      contactId: env.senderId,
      text: plainText,
      isMine: false,
      timestamp: DateTime.fromMillisecondsSinceEpoch(env.timestamp),
      isRead: false,
      status: 'delivered',
    );
    setState(() => _messages.add(msg));
    await _messageBox.put(msg.id, msg);
    _pulseSignal.fire();

    final receipt = Envelope(
      type: 'delivery_receipt',
      senderId: _myDeviceId,
      senderName: _myDisplayName,
      to: env.senderId,
      data: {'messageId': env.id},
    );
    try {
      await _sendEnvelope(receipt);
    } catch (_) {}

    if (_selectedContact?.uniqueId == env.senderId) await _markThreadRead(env.senderId);
  }

  void _handleDeliveryReceipt(Envelope env) {
    final msgId = env.data['messageId'] as String?;
    if (msgId == null) return;
    final stored = _messageBox.get(msgId);
    if (stored == null || stored.contactId != env.senderId) return;
    if (stored.isMine && stored.status == 'sent') {
      stored.status = 'delivered';
      _messageBox.put(msgId, stored);
      final idx = _messages.indexWhere((m) => m.id == msgId);
      if (idx != -1) setState(() => _messages[idx] = stored);
    }
  }

  void _handleReadReceiptEnvelope(Envelope env) {
    final upTo = env.data['upTo'] as int?;
    if (upTo == null) return;
    final cutoff = DateTime.fromMillisecondsSinceEpoch(upTo);
    var changed = false;
    for (final m in _messages) {
      if (m.contactId == env.senderId && m.isMine && !m.isRead && !m.timestamp.isAfter(cutoff)) {
        m.isRead = true;
        m.status = 'read';
        _messageBox.put(m.id, m);
        changed = true;
      }
    }
    if (changed) setState(() {});
  }

  Future<void> _markThreadRead(String contactId) async {
    final toUpdate = _messages.where((m) => m.contactId == contactId && !m.isMine && !m.isRead).toList();
    if (toUpdate.isEmpty) return;
    for (final m in toUpdate) {
      m.isRead = true;
      await _messageBox.put(m.id, m);
    }
    setState(() {});
    final env = Envelope(
      type: 'read_receipt',
      senderId: _myDeviceId,
      senderName: _myDisplayName,
      to: contactId,
      data: {'upTo': DateTime.now().millisecondsSinceEpoch},
    );
    try {
      await _sendEnvelope(env);
    } catch (_) {}
  }

  // ─────────────────────────────────────────────────────────────────────────────
  //  REACTIONS
  // ─────────────────────────────────────────────────────────────────────────────

  OverlayEntry? _reactionOverlay;

  void _handleReactionEnvelope(Envelope env) {
    final messageId = env.data['messageId'] as String?;
    final emoji = env.data['emoji'] as String?;
    if (messageId == null || emoji == null) return;
    final stored = _messageBox.get(messageId);
    if (stored == null) return;
    stored.reactions.add(emoji);
    _messageBox.put(messageId, stored);
    final idx = _messages.indexWhere((m) => m.id == messageId);
    setState(() {
      if (idx != -1) _messages[idx] = stored;
    });
  }

  void _showReactionPicker(ChatMessage msg, Offset anchor) {
    _reactionOverlay?.remove();
    final screen = MediaQuery.of(context).size;
    const panelWidth = 260.0;
    const panelHeight = 64.0;
    double left = (anchor.dx - panelWidth / 2).clamp(12.0, screen.width - panelWidth - 12.0);
    double top = anchor.dy - panelHeight - 16;
    if (top < 40) top = anchor.dy + 16;

    _reactionOverlay = OverlayEntry(
      builder: (ctx) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: _dismissReactionPicker,
              behavior: HitTestBehavior.translucent,
              child: Container(color: Colors.transparent),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            width: panelWidth,
            child: GlassPanel(
              borderRadius: BorderRadius.circular(24),
              opacity: 0.3,
              isDark: _isDark,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: ['👍', '❤️', '😂', '😮', '😢', '🙏'].map((emoji) {
                    return GestureDetector(
                      onTap: () {
                        _dismissReactionPicker();
                        _addReaction(msg, emoji);
                      },
                      child: Text(emoji, style: const TextStyle(fontSize: 26)),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    Overlay.of(context).insert(_reactionOverlay!);
  }

  void _dismissReactionPicker() {
    _reactionOverlay?.remove();
    _reactionOverlay = null;
  }

  Future<void> _addReaction(ChatMessage msg, String emoji) async {
    final stored = _messageBox.get(msg.id) ?? msg;
    stored.reactions.add(emoji);
    await _messageBox.put(msg.id, stored);
    final idx = _messages.indexWhere((m) => m.id == msg.id);
    setState(() {
      if (idx != -1) _messages[idx] = stored;
    });
    final env = Envelope(
      type: 'reaction',
      senderId: _myDeviceId,
      senderName: _myDisplayName,
      to: msg.contactId,
      data: {'messageId': msg.id, 'emoji': emoji},
    );
    try {
      await _sendEnvelope(env);
    } catch (_) {}
  }

  // ─────────────────────────────────────────────────────────────────────────────
  //  VOICE NOTES
  // ─────────────────────────────────────────────────────────────────────────────

  Future<void> _startRecordingVoiceMessage() async {
    if (_selectedContact == null || _callPhase != CallPhase.idle) return;
    final tempDir = await getTemporaryDirectory();
    final ext = _voiceEffect == VoiceEffect.normal ? 'aac' : 'wav';
    final path = '${tempDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final codec = _voiceEffect == VoiceEffect.normal ? Codec.aacADTS : Codec.pcm16WAV;
    await _audioRecorder.startRecorder(toFile: path, codec: codec);
    setState(() => _isRecordingVoiceMessage = true);
  }

  Future<void> _cancelRecording() async {
    if (!_isRecordingVoiceMessage) return;
    await _audioRecorder.stopRecorder();
    setState(() => _isRecordingVoiceMessage = false);
  }

  Future<void> _stopRecordingAndSendVoiceMessage() async {
    if (!_isRecordingVoiceMessage) return;
    final path = await _audioRecorder.stopRecorder();
    setState(() => _isRecordingVoiceMessage = false);
    if (path == null || _selectedContact == null) return;

    String finalPath = path;
    if (_voiceEffect != VoiceEffect.normal) {
      final processed = await _applyVoiceEffect(path, _voiceEffect);
      if (processed != null) finalPath = processed;
    }

    final peer = _selectedContact!;
    final msg = ChatMessage(
      id: const Uuid().v4(),
      contactId: peer.uniqueId,
      text: _voiceEffect == VoiceEffect.normal
          ? '🎤 Voice message'
          : (_voiceEffect == VoiceEffect.minion ? '🐿️ Minion voice' : '🐢 Slow-mo voice'),
      isMine: true,
      timestamp: DateTime.now(),
      type: 'voice',
      filePath: finalPath,
    );
    setState(() => _messages.add(msg));
    await _messageBox.put(msg.id, msg);
    _pulseSignal.fire();

    try {
      final file = File(finalPath);
      final info = _role == P2pRole.host ? await _host.broadcastFile(file) : await _client.broadcastFile(file);
      if (info == null) {
        setState(() => _status = 'Voice note failed to send — check the debug console for the real exception');
        return;
      }
      final env = Envelope(
        type: 'file_notice',
        senderId: _myDeviceId,
        senderName: _myDisplayName,
        to: peer.uniqueId,
        data: {'fileId': info.id, 'kind': 'voice'},
      );
      await _sendEnvelope(env);
    } catch (e) {
      debugPrint('VOICE SEND ERROR: $e');
      setState(() => _status = 'Voice note failed: $e');
    }
  }

  Future<String?> _applyVoiceEffect(String wavPath, VoiceEffect effect) async {
    try {
      final file = File(wavPath);
      final bytes = await file.readAsBytes();
      if (bytes.length < 44) return null;

      final bb = bytes.buffer.asByteData();
      final originalRate = bb.getUint32(24, Endian.little);

      int newRate;
      switch (effect) {
        case VoiceEffect.minion:
          newRate = (originalRate * 1.8).round();
          break;
        case VoiceEffect.slowMo:
          newRate = (originalRate * 0.55).round();
          break;
        default:
          return wavPath;
      }

      final patched = Uint8List.fromList(bytes);
      final pbb = patched.buffer.asByteData();
      pbb.setUint32(24, newRate, Endian.little);

      final numChannels = pbb.getUint16(22, Endian.little);
      final bitsPerSample = pbb.getUint16(34, Endian.little);
      final byteRate = newRate * numChannels * (bitsPerSample ~/ 8);
      pbb.setUint32(28, byteRate, Endian.little);

      final dir = await getTemporaryDirectory();
      final outPath = '${dir.path}/voice_fx_${DateTime.now().millisecondsSinceEpoch}.wav';
      await File(outPath).writeAsBytes(patched);
      return outPath;
    } catch (e) {
      debugPrint('VOICE FX ERROR: $e');
      return null;
    }
  }

  Future<void> _togglePlayVoice(ChatMessage msg) async {
    if (msg.filePath == null) return;
    if (_playingMessageId == msg.id) {
      await _audioPlayer.stopPlayer();
      setState(() => _playingMessageId = null);
      return;
    }
    if (_playingMessageId != null) await _audioPlayer.stopPlayer();
    setState(() => _playingMessageId = msg.id);

    void onDone() {
      if (mounted) setState(() => _playingMessageId = null);
    }

    try {
      await _audioPlayer.startPlayer(fromURI: msg.filePath, codec: Codec.aacADTS, whenFinished: onDone);
    } catch (e) {
      debugPrint('PLAYBACK ERROR (codec aacADTS): $e — retrying without explicit codec');
      try {
        await _audioPlayer.startPlayer(fromURI: msg.filePath, whenFinished: onDone);
      } catch (e2) {
        debugPrint('PLAYBACK ERROR (fallback): $e2');
        if (mounted) {
          setState(() => _playingMessageId = null);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This device could not play that voice message.')));
        }
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────
  //  FILE SHARING
  // ─────────────────────────────────────────────────────────────────────────────

  Future<void> _pickAndSendFile() async {
    if (_selectedContact == null) return;
    if (!_isPeerOnline) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Peer is offline. Please wait until they reconnect.')),
      );
      return;
    }
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.single.path == null) return;
    final peer = _selectedContact!;
    final file = File(result.files.single.path!);
    final name = result.files.single.name;

    final msg = ChatMessage(
      id: const Uuid().v4(),
      contactId: peer.uniqueId,
      text: name,
      isMine: true,
      timestamp: DateTime.now(),
      type: 'file',
      filePath: file.path,
      fileName: name,
      status: 'sending',
    );
    setState(() => _messages.add(msg));
    await _messageBox.put(msg.id, msg);
    _pulseSignal.fire();

    final cancelToken = CancelToken();
    _fileTransferCancelTokens[msg.id] = cancelToken;
    _fileTransferProgress[msg.id] = 0.0;

    try {
      int progress = 0;
      Timer.periodic(const Duration(milliseconds: 100), (timer) {
        if (cancelToken.isCancelled) {
          timer.cancel();
          return;
        }
        progress += 5;
        if (progress >= 100) {
          progress = 100;
          timer.cancel();
          setState(() {
            _fileTransferProgress[msg.id] = 1.0;
          });
        } else {
          setState(() {
            _fileTransferProgress[msg.id] = progress / 100;
          });
        }
      });

      final info = _role == P2pRole.host ? await _host.broadcastFile(file) : await _client.broadcastFile(file);
      if (info == null) {
        setState(() {
          _fileTransferProgress.remove(msg.id);
          _fileTransferCancelTokens.remove(msg.id);
        });
        return;
      }

      final env = Envelope(
        type: 'file_notice',
        senderId: _myDeviceId,
        senderName: _myDisplayName,
        to: peer.uniqueId,
        data: {'fileId': info.id, 'kind': 'file'},
      );
      await _sendEnvelope(env);

      msg.status = 'sent';
      await _messageBox.put(msg.id, msg);
      setState(() {
        _fileTransferProgress.remove(msg.id);
        _fileTransferCancelTokens.remove(msg.id);
        final idx = _messages.indexWhere((m) => m.id == msg.id);
        if (idx != -1) _messages[idx] = msg;
      });
      _pulseSignal.fire();

    } catch (e) {
      setState(() {
        _fileTransferProgress.remove(msg.id);
        _fileTransferCancelTokens.remove(msg.id);
        _status = 'File failed: $e';
      });
    }
  }

  void _cancelFileTransfer(String msgId) {
    final token = _fileTransferCancelTokens[msgId];
    token?.cancel();
    _fileTransferCancelTokens.remove(msgId);
    _fileTransferProgress.remove(msgId);
  }

  Future<void> _retrySendPending(ChatMessage msg) async {
    if (_isPeerOnline) {
      final env = Envelope(
        type: 'text',
        senderId: _myDeviceId,
        senderName: _myDisplayName,
        to: _selectedContact!.uniqueId,
        data: {'enc': false, 'text': msg.text},
      );
      try {
        await _sendEnvelope(env);
        msg.status = 'sent';
        await _messageBox.put(msg.id, msg);
        _pendingMessages.remove(msg.id);
        setState(() {});
      } catch (e) {}
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Peer is still offline.')),
      );
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────
  //  FILE RECEIVE
  // ─────────────────────────────────────────────────────────────────────────────

  Future<void> _handleFileNoticeEnvelope(Envelope env) async {
    final fileId = env.data['fileId'] as String?;
    if (fileId == null) return;
    _pendingFileNotices[fileId] = env;
    await _tryResolvePendingFile(fileId);
  }

  void _onReceivedFilesInfo(List<ReceivableFileInfo> files) {
    for (final f in files) {
      final id = f.info.id;
      if (_handledFileIds.contains(id)) continue;
      _pendingReceivableInfo[id] = f;
      _tryResolvePendingFile(id);
    }
  }

  Future<void> _tryResolvePendingFile(String fileId) async {
    final notice = _pendingFileNotices[fileId];
    final info = _pendingReceivableInfo[fileId];
    if (notice == null || info == null || _handledFileIds.contains(fileId)) return;
    _handledFileIds.add(fileId);

    try {
      final dir = (await getTemporaryDirectory()).path;
      final ok = _role == P2pRole.host ? await _host.downloadFile(fileId, dir) : await _client.downloadFile(fileId, dir);
      if (ok != true) return;

      final savedPath = '$dir/${info.info.name}';
      final kind = notice.data['kind'] as String? ?? 'file';

      final msg = ChatMessage(
        id: const Uuid().v4(),
        contactId: notice.senderId,
        text: kind == 'voice' ? '🎤 Voice message' : info.info.name,
        isMine: false,
        timestamp: DateTime.fromMillisecondsSinceEpoch(notice.timestamp),
        type: kind == 'voice' ? 'voice' : 'file',
        filePath: savedPath,
        fileName: info.info.name,
        isRead: false,
        status: 'delivered',
      );
      setState(() => _messages.add(msg));
      await _messageBox.put(msg.id, msg);
      _pulseSignal.fire();
      if (_selectedContact?.uniqueId == notice.senderId) await _markThreadRead(notice.senderId);
    } catch (e) {
      debugPrint('FILE DOWNLOAD ERROR: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────
  //  FILE INTERACTION
  // ─────────────────────────────────────────────────────────────────────────────

  bool _isImageFile(String path) {
    final ext = path.split('.').last.toLowerCase();
    return ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp'].contains(ext);
  }

  void _showImagePreview(String path) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: GestureDetector(
          onTap: () => Navigator.pop(ctx),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              image: DecorationImage(image: FileImage(File(path)), fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _saveFileToDownloads(ChatMessage msg) async {
    try {
      final file = File(msg.filePath!);
      if (!await file.exists()) throw Exception('File not found');
      await Share.shareXFiles([XFile(msg.filePath!)], text: 'Save file: ${msg.fileName ?? 'file'}');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose a save location in the share sheet.')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  Future<void> _handleFileTap(ChatMessage msg) async {
    if (msg.filePath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File not found locally.')),
      );
      return;
    }
    final file = File(msg.filePath!);
    if (!await file.exists()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The file is no longer available.')),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Theme(
        data: ThemeData(
          brightness: _isDark ? Brightness.dark : Brightness.light,
          dialogBackgroundColor: _isDark ? const Color(0xFF1E1E2E) : Colors.white,
          textTheme: TextTheme(bodyLarge: TextStyle(color: _fg)),
        ),
        child: GlassPanel(
          borderRadius: BorderRadius.circular(24),
          isDark: _isDark,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  msg.fileName ?? 'File',
                  style: TextStyle(color: _fg, fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 12),
                if (_isImageFile(msg.filePath!))
                  ListTile(
                    leading: Icon(Icons.image, color: _fg),
                    title: Text('Preview image', style: TextStyle(color: _fg)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _showImagePreview(msg.filePath!);
                    },
                  ),
                ListTile(
                  leading: Icon(Icons.open_in_browser, color: _fg),
                  title: Text('Open with default app', style: TextStyle(color: _fg)),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final result = await OpenFile.open(msg.filePath!);
                    if (result.type != ResultType.done) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Could not open file: ${result.message}')),
                      );
                    }
                  },
                ),
                ListTile(
                  leading: Icon(Icons.share, color: _fg),
                  title: Text('Share', style: TextStyle(color: _fg)),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await Share.shareXFiles([XFile(msg.filePath!)],
                        text: 'Shared file: ${msg.fileName ?? 'file'}');
                  },
                ),
                ListTile(
                  leading: Icon(Icons.save_alt, color: _fg),
                  title: Text('Save to Downloads', style: TextStyle(color: _fg)),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _saveFileToDownloads(msg);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  //  LIVE VOICE CALLS (flutter_pcm_sound for drift-free playback)
  // ─────────────────────────────────────────────────────────────────────────────

  Future<void> _startCall(Contact peer) async {
    if (_callPhase != CallPhase.idle) return;
    if (!_isPeerOnline) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Peer is offline. Cannot start call.')),
      );
      return;
    }
    if (peer.deviceAddress == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Don't have this device's network address yet — wait a moment and try again.")),
      );
      return;
    }
    _callPeer = peer;
    _callId = const Uuid().v4();
    _activeCallQuality = _callQuality;
    setState(() => _callPhase = CallPhase.outgoingRinging);
    final env = Envelope(
      type: 'call_invite',
      senderId: _myDeviceId,
      senderName: _myDisplayName,
      to: peer.uniqueId,
      data: {
        'callId': _callId,
        'sampleRate': _activeCallQuality.sampleRate,
        'numChannels': _activeCallQuality.numChannels,
      },
    );
    try {
      await _sendEnvelope(env);
    } catch (e) {
      _endCallLocal();
      return;
    }
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = Timer(const Duration(seconds: 30), () {
      if (_callPhase == CallPhase.outgoingRinging) _endCall(reason: 'No answer');
    });
  }

  Future<void> _handleCallInvite(Envelope env) async {
    if (_callPhase != CallPhase.idle) {
      final reject = Envelope(
        type: 'call_reject',
        senderId: _myDeviceId,
        senderName: _myDisplayName,
        to: env.senderId,
        data: {'callId': env.data['callId'], 'reason': 'busy'},
      );
      try {
        await _sendEnvelope(reject);
      } catch (_) {}
      return;
    }
    final contact = _contactBox.get(env.senderId);
    if (contact == null) return;

    final sampleRate = env.data['sampleRate'] as int? ?? CallQuality.medium.sampleRate;
    final numChannels = env.data['numChannels'] as int? ?? CallQuality.medium.numChannels;
    _activeCallQuality = CallQuality.values.firstWhere(
      (q) => q.sampleRate == sampleRate && q.numChannels == numChannels,
      orElse: () => CallQuality.medium,
    );

    _callPeer = contact;
    _callId = env.data['callId'] as String? ?? const Uuid().v4();
    setState(() => _callPhase = CallPhase.incomingRinging);
    _ringTimer?.cancel();
    _ringTimer = Timer.periodic(const Duration(milliseconds: 1400), (_) => HapticFeedback.heavyImpact());
    _callTimeoutTimer?.cancel();
    _callTimeoutTimer = Timer(const Duration(seconds: 30), () {
      if (_callPhase == CallPhase.incomingRinging) _declineCall();
    });
  }

  Future<void> _acceptCall() async {
    if (_callPhase != CallPhase.incomingRinging || _callPeer == null) return;
    _ringTimer?.cancel();
    _callTimeoutTimer?.cancel();
    final env = Envelope(
      type: 'call_accept',
      senderId: _myDeviceId,
      senderName: _myDisplayName,
      to: _callPeer!.uniqueId,
      data: {
        'callId': _callId,
        'sampleRate': _activeCallQuality.sampleRate,
        'numChannels': _activeCallQuality.numChannels,
      },
    );
    setState(() => _callPhase = CallPhase.active);
    try {
      await _sendEnvelope(env);
    } catch (_) {}
    await _startRealtimeAudio();
  }

  Future<void> _declineCall() async {
    if (_callPeer == null) return;
    _ringTimer?.cancel();
    _callTimeoutTimer?.cancel();
    final env = Envelope(type: 'call_reject', senderId: _myDeviceId, senderName: _myDisplayName, to: _callPeer!.uniqueId, data: {'callId': _callId, 'reason': 'declined'});
    try {
      await _sendEnvelope(env);
    } catch (_) {}
    _endCallLocal();
  }

  Future<void> _handleCallAccept(Envelope env) async {
    if (_callPhase != CallPhase.outgoingRinging || env.data['callId'] != _callId) return;
    _callTimeoutTimer?.cancel();

    final sampleRate = env.data['sampleRate'] as int? ?? _callQuality.sampleRate;
    final numChannels = env.data['numChannels'] as int? ?? _callQuality.numChannels;
    _activeCallQuality = CallQuality.values.firstWhere(
      (q) => q.sampleRate == sampleRate && q.numChannels == numChannels,
      orElse: () => _callQuality,
    );

    setState(() => _callPhase = CallPhase.active);
    await _startRealtimeAudio();
  }

  void _handleCallReject(Envelope env) {
    if (env.data['callId'] != _callId) return;
    final reason = env.data['reason'] as String? ?? 'declined';
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Call $reason')));
    _endCallLocal();
  }

  void _handleCallEnd(Envelope env) {
    if (env.data['callId'] != _callId) return;
    _endCallLocal();
  }

  Future<void> _handleCallForceStart(Envelope env) async {
    if (env.data['callId'] != _callId) return;
    _ringTimer?.cancel();
    _callTimeoutTimer?.cancel();

    final sampleRate = env.data['sampleRate'] as int? ?? _callQuality.sampleRate;
    final numChannels = env.data['numChannels'] as int? ?? _callQuality.numChannels;
    _activeCallQuality = CallQuality.values.firstWhere(
      (q) => q.sampleRate == sampleRate && q.numChannels == numChannels,
      orElse: () => _callQuality,
    );

    setState(() => _callPhase = CallPhase.active);
    await _startRealtimeAudio();
  }

  Future<void> _emergencyForceStart() async {
    if (_callPhase != CallPhase.outgoingRinging || _callPeer == null) return;
    _callTimeoutTimer?.cancel();
    final env = Envelope(
      type: 'call_force_start',
      senderId: _myDeviceId,
      senderName: _myDisplayName,
      to: _callPeer!.uniqueId,
      data: {
        'callId': _callId,
        'sampleRate': _activeCallQuality.sampleRate,
        'numChannels': _activeCallQuality.numChannels,
      },
    );
    setState(() => _callPhase = CallPhase.active);
    try {
      await _sendEnvelope(env);
    } catch (_) {}
    await _startRealtimeAudio();
  }

  Future<void> _endCall({String? reason}) async {
    if (_callPeer != null) {
      final env = Envelope(type: 'call_end', senderId: _myDeviceId, senderName: _myDisplayName, to: _callPeer!.uniqueId, data: {'callId': _callId});
      try {
        await _sendEnvelope(env);
      } catch (_) {}
    }
    if (reason != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(reason)));
    _endCallLocal();
  }

  void _endCallLocal() {
    _ringTimer?.cancel();
    _callTimeoutTimer?.cancel();
    _stopRealtimeAudio();
    setState(() {
      _callPhase = CallPhase.idle;
      _callPeer = null;
      _callId = '';
      _activeCallQuality = _callQuality;
    });
  }
  // ─────────────────────────────────────────────────────────────────────────────
  //  REALTIME AUDIO – flutter_pcm_sound (drift-free callback-based playback)
  // ─────────────────────────────────────────────────────────────────────────────

  Future<void> _startRealtimeAudio() async {
    final targetIp = _callPeer?.deviceAddress;
    if (targetIp == null) {
      _endCall(reason: "Missing peer network address — can't start audio");
      return;
    }
    debugPrint('CALL AUDIO: targetIp=$targetIp port=$kCallPort');
    _dbgMicPacketsSent = 0;
    _dbgUdpPacketsRecv = 0;
    try {
      _callSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, kCallPort, reuseAddress: true);
      debugPrint('CALL AUDIO: socket bound on ${_callSocket!.address.address}:${_callSocket!.port}');
    } catch (e) {
      debugPrint('CALL SOCKET BIND ERROR: $e');
      _endCall(reason: 'Could not open the call audio socket: $e');
      return;
    }

    // ── Negotiated audio format ──
    final int sampleRate = _activeCallQuality.sampleRate;
    final int numChannels = _activeCallQuality.numChannels;
    final int bytesPerFrame = numChannels * 2; // PCM 16-bit

    // ── Setup flutter_pcm_sound (event-based, drift-free) ──
    _pcmFeedBuffer.clear();
    try {
      await FlutterPcmSound.setLogLevel(LogLevel.error);
      await FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: numChannels);
      await FlutterPcmSound.setFeedThreshold((sampleRate * 0.05).round()); // 50ms
      FlutterPcmSound.setFeedCallback(_onPcmFeed);
      _isPlaying = true; // must be true BEFORE start(), which fires the first feed event immediately
      await FlutterPcmSound.start();
      _pcmSoundReady = true;
    } catch (e) {
      debugPrint('PCM SOUND SETUP ERROR: $e');
      _endCall(reason: 'Could not start PCM audio output: $e');
      return;
    }

    // ── Microphone → UDP (flutter_sound for recording) ──
    _micStreamController = StreamController<Uint8List>();
    _micStreamSub = _micStreamController!.stream.listen((data) {
      final ip = _callPeer?.deviceAddress;
      if (ip == null || _callSocket == null) return;
      try {
        _callSocket!.send(data, InternetAddress(ip), kCallPort);
        _dbgMicPacketsSent++;
        if (_dbgMicPacketsSent == 1 || _dbgMicPacketsSent % 40 == 0) {
          debugPrint('CALL AUDIO: mic->UDP sent packet #$_dbgMicPacketsSent (${data.length} bytes) to $ip:$kCallPort');
        }
      } catch (e) {
        debugPrint('CALL AUDIO: mic send FAILED: $e');
      }
    });

    try {
      await _audioRecorder.startRecorder(
        toStream: _micStreamController!.sink,
        codec: Codec.pcm16,
        numChannels: numChannels,
        sampleRate: sampleRate,
        bufferSize: 8192,
      );
      debugPrint('CALL AUDIO: mic recorder started ($sampleRate Hz, $numChannels ch)');
    } catch (e) {
      debugPrint('CALL MIC START ERROR: $e — retrying at safe mono 16kHz');
      try {
        await _audioRecorder.startRecorder(
          toStream: _micStreamController!.sink,
          codec: Codec.pcm16,
          numChannels: 1,
          sampleRate: 16000,
          bufferSize: 8192,
        );
      } catch (e2) {
        _endCall(reason: 'This device could not start the microphone stream: $e2');
        return;
      }
    }

    // ── UDP → flutter_pcm_sound buffer ──
    _callSocketSub = _callSocket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = _callSocket!.receive();
      if (dg == null || dg.data.isEmpty) return;

      _dbgUdpPacketsRecv++;
      if (_dbgUdpPacketsRecv == 1 || _dbgUdpPacketsRecv % 40 == 0) {
        debugPrint('CALL AUDIO: UDP<-network recv packet #$_dbgUdpPacketsRecv (${dg.data.length} bytes) from ${dg.address.address}:${dg.port}, buffer now ${_pcmFeedBuffer.length} bytes');
      }

      _pcmFeedBuffer.addAll(dg.data);

      // Prevent memory bloat: cap at ~500ms (trim amount rounded down to a
      // whole number of frames so we never split a 16-bit sample in half)
      final maxBytes = (sampleRate * bytesPerFrame * 0.5).round();
      if (_pcmFeedBuffer.length > maxBytes) {
        int trim = _pcmFeedBuffer.length - maxBytes;
        trim -= trim % bytesPerFrame;
        if (trim > 0) _pcmFeedBuffer.removeRange(0, trim);
      }
    });
  }

  // Converts raw little-endian PCM16 bytes (as produced by flutter_sound /
  // received over the socket) into actual 16-bit sample values. This is
  // required because PcmArrayInt16.fromList expects one *sample* per list
  // entry (-32768..32767), not one raw byte per entry.
  List<int> _bytesToInt16Samples(Uint8List bytes) {
    final int sampleCount = bytes.length ~/ 2;
    final byteData = ByteData.sublistView(bytes);
    final samples = List<int>.filled(sampleCount, 0);
    for (int i = 0; i < sampleCount; i++) {
      samples[i] = byteData.getInt16(i * 2, Endian.little);
    }
    return samples;
  }

  int _dbgFeedCalls = 0;

  void _onPcmFeed(int remainingFrames) async {
    _dbgFeedCalls++;
    if (_dbgFeedCalls == 1 || _dbgFeedCalls % 40 == 0) {
      debugPrint('CALL AUDIO: _onPcmFeed called #$_dbgFeedCalls remainingFrames=$remainingFrames isPlaying=$_isPlaying phase=$_callPhase bufferedBytes=${_pcmFeedBuffer.length}');
    }
    if (!_isPlaying || _callPhase != CallPhase.active) return;

    final int bytesPerFrame = _activeCallQuality.numChannels * 2;
    final int bytesNeeded = remainingFrames * bytesPerFrame;

    if (_pcmFeedBuffer.length >= bytesNeeded && bytesNeeded > 0) {
      final chunk = Uint8List.fromList(_pcmFeedBuffer.sublist(0, bytesNeeded));
      _pcmFeedBuffer.removeRange(0, bytesNeeded);
      try {
        await FlutterPcmSound.feed(PcmArrayInt16.fromList(_bytesToInt16Samples(chunk)));
      } catch (e) {
        debugPrint('PCM FEED ERROR: $e');
      }
    } else if (_pcmFeedBuffer.isNotEmpty) {
      final haveBytes = _pcmFeedBuffer.length;
      final chunk = Uint8List(bytesNeeded);
      if (haveBytes > 0) {
        chunk.setRange(0, haveBytes, Uint8List.fromList(_pcmFeedBuffer));
        _pcmFeedBuffer.clear();
      }
      try {
        await FlutterPcmSound.feed(PcmArrayInt16.fromList(_bytesToInt16Samples(chunk)));
      } catch (e) {
        debugPrint('PCM FEED ERROR: $e');
      }
    } else {
      if (bytesNeeded > 0) {
        try {
          await FlutterPcmSound.feed(PcmArrayInt16.fromList(List<int>.filled(bytesNeeded ~/ 2, 0)));
        } catch (e) {
          debugPrint('PCM SILENCE FEED ERROR: $e');
        }
      }
    }
  }

  Future<void> _stopRealtimeAudio() async {
    _isPlaying = false;
    _pcmSoundReady = false;
    _pcmFeedBuffer.clear();

    try {
      await FlutterPcmSound.release();
    } catch (_) {}

    try {
      await _audioRecorder.stopRecorder();
    } catch (_) {}

    try {
      await _callPlayer.stopPlayer();
    } catch (_) {}

    await _micStreamSub?.cancel();
    _micStreamSub = null;
    await _micStreamController?.close();
    _micStreamController = null;
    await _callSocketSub?.cancel();
    _callSocketSub = null;
    _callSocket?.close();
    _callSocket = null;
  }

  // ─────────────────────────────────────────────────────────────────────────────
  //  BLOCKING / MISC
  // ─────────────────────────────────────────────────────────────────────────────

  Future<void> _toggleBlockContact(Contact c) async {
    c.isBlocked = !c.isBlocked;
    await _contactBox.put(c.uniqueId, c);
    if (_selectedContact?.uniqueId == c.uniqueId && c.isBlocked) {
      setState(() => _selectedContact = null);
    } else {
      _refresh();
    }
  }

  Future<void> _disconnect() async {
    if (_callPhase != CallPhase.idle) await _endCall();
    try {
      if (_role == P2pRole.host) {
        await _host.removeGroup();
      } else if (_role == P2pRole.client) {
        await _client.disconnect();
      }
    } catch (e) {
      debugPrint('DISCONNECT ERROR: $e');
    }
    await _hostStateSub?.cancel();
    await _clientStateSub?.cancel();
    await _hostClientsSub?.cancel();
    await _hostTextSub?.cancel();
    await _clientTextSub?.cancel();
    await _hostFilesSub?.cancel();
    await _clientFilesSub?.cancel();
    await _scanSub?.cancel();
    _stopHeartbeat();
    setState(() {
      _isConnected = false;
      _role = P2pRole.none;
      _discoveredHosts.clear();
      _groupClients.clear();
      _selectedContact = null;
      _helloedTo.clear();
      _status = 'Disconnected';
      _isPeerOnline = false;
    });
  }

  Future<void> _promptForDisplayName() async {
    final controller = TextEditingController(text: _myDisplayName);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _isDark ? const Color(0xFF17172A) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text('Your display name', style: TextStyle(color: _fg)),
        content: TextField(controller: controller, autofocus: true, style: TextStyle(color: _fg), decoration: const InputDecoration(hintText: 'Enter a name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      setState(() => _myDisplayName = result);
      await EncryptionService.setMyDisplayName(result);
    }
  }

  Future<void> _pickAvatar() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    if (result == null || result.files.single.bytes == null) return;
    final bytes = result.files.single.bytes!;
    if (bytes.length > 180 * 1024) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pick an image under ~180 KB — it travels over the chat channel itself.')),
        );
      }
      return;
    }
    final b64 = base64Encode(bytes);
    setState(() => _myAvatarBase64 = b64);
    await SettingsService.setAvatar(b64);
    if (_role != P2pRole.none) await _sendHello();
  }

  void _loadMessages() {
    setState(() => _messages = _messageBox.values.toList());
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  String _formatTime(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  ImageProvider? _avatarImage(String? b64) => b64 == null ? null : MemoryImage(base64Decode(b64));

  // ═══════════════════════════════════════════════════════════════════════════════
  //  UI
  // ═══════════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: _AnimatedMeshBackground(pulseSignal: _pulseSignal, palette: _palette, isDark: _isDark)),
          SafeArea(
            child: Column(
              children: [
                _buildTopBar(),
                Expanded(child: _buildMainContent()),
              ],
            ),
          ),
          if (_isRecordingVoiceMessage) _buildRecordingOverlay(),
          if (_callPhase != CallPhase.idle) _buildCallOverlay(),
        ],
      ),
    );
  }

  Widget _buildMainContent() {
    if (_role == P2pRole.none) return _buildRoleSelection();
    if (_selectedContact != null) return _buildChatArea();
    if (_role == P2pRole.client && !_isConnected) return _buildClientHostList();
    return _buildContactsList();
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  //  TOP BAR
  // ═══════════════════════════════════════════════════════════════════════════════

  Widget _buildTopBar() {
    final peer = _selectedContact;
    final isOffline = peer != null && !_isPeerOnline;
    return GlassPanel(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      borderRadius: BorderRadius.circular(24),
      opacity: 0.16,
      isDark: _isDark,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          children: [
            if (peer != null)
              IconButton(
                icon: Icon(Icons.arrow_back_ios_new, color: _fg, size: 18),
                onPressed: () {
                  setState(() => _selectedContact = null);
                  _stopHeartbeat();
                },
              )
            else const SizedBox(width: 8),
            if (peer != null)
              CircleAvatar(
                radius: 16,
                backgroundImage: _avatarImage(peer.avatarBase64),
                backgroundColor: _fgDim.withOpacity(0.2),
                child: peer.avatarBase64 == null
                    ? Text(peer.displayName.isNotEmpty ? peer.displayName[0] : '?', style: TextStyle(color: _fg, fontSize: 12))
                    : null,
              ),
            if (peer != null) const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    peer?.displayName ?? 'Wi-Fi Direct',
                    style: TextStyle(color: _fg, fontWeight: FontWeight.w700, fontSize: 17),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    isOffline ? 'Offline' : (_isTyping ? 'Typing…' : _status),
                    style: TextStyle(color: isOffline ? Colors.redAccent : _fgDim, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (peer != null && !isOffline)
              IconButton(
                icon: Icon(Icons.call_outlined, color: _fg, size: 20),
                onPressed: () => _startCall(peer),
              ),
            if (_role != P2pRole.none)
              IconButton(icon: Icon(Icons.logout, color: _fg, size: 20), onPressed: _disconnect),
            IconButton(icon: Icon(Icons.tune_rounded, color: _fgDim, size: 18), onPressed: _openSettingsSheet),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  //  SETTINGS SHEET
  // ═══════════════════════════════════════════════════════════════════════════════

  void _openSettingsSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: GlassPanel(
              borderRadius: BorderRadius.circular(28),
              opacity: 0.3,
              isDark: _isDark,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        GestureDetector(
                          onTap: _pickAvatar,
                          child: CircleAvatar(
                            radius: 26,
                            backgroundColor: _fgDim.withOpacity(0.2),
                            backgroundImage: _avatarImage(_myAvatarBase64),
                            child: _myAvatarBase64 == null ? Icon(Icons.add_a_photo_outlined, color: _fg, size: 20) : null,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: GestureDetector(
                            onTap: _promptForDisplayName,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(_myDisplayName, style: TextStyle(color: _fg, fontWeight: FontWeight.w700)),
                                Text('Tap to rename', style: TextStyle(color: _fgFaint, fontSize: 11)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Text('Appearance', style: TextStyle(color: _fgDim, fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: _pillToggle('Dark', _isDark, () async {
                          setState(() => _isDark = true);
                          setSheetState(() {});
                          await SettingsService.setIsDark(true);
                        })),
                        const SizedBox(width: 8),
                        Expanded(child: _pillToggle('Light', !_isDark, () async {
                          setState(() => _isDark = false);
                          setSheetState(() {});
                          await SettingsService.setIsDark(false);
                        })),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text('Particle colors', style: TextStyle(color: _fgDim, fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: List.generate(kPalettes.length, (i) {
                        final selected = i == _paletteIndex;
                        return GestureDetector(
                          onTap: () async {
                            setState(() => _paletteIndex = i);
                            setSheetState(() {});
                            await SettingsService.setPaletteIndex(i);
                            _pulseSignal.fire();
                          },
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: selected ? _fg : Colors.transparent, width: 2)),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: kPalettes[i]
                                  .map((c) => Container(width: 12, height: 12, margin: const EdgeInsets.symmetric(horizontal: 1), decoration: BoxDecoration(color: c, shape: BoxShape.circle)))
                                  .toList(),
                            ),
                          ),
                        );
                      }),
                    ),
                    const SizedBox(height: 16),
                    Text('Call quality', style: TextStyle(color: _fgDim, fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    ...CallQuality.values.map((q) {
                      final selected = q == _callQuality;
                      return GestureDetector(
                        onTap: () async {
                          setState(() => _callQuality = q);
                          setSheetState(() {});
                          await SettingsService.setCallQuality(q);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off, color: selected ? const Color(0xFF64D2FF) : _fgDim, size: 18),
                              const SizedBox(width: 10),
                              Text(q.label, style: TextStyle(color: _fg, fontSize: 13)),
                            ],
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pillToggle(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: selected ? const Color(0xFF7C4DFF).withOpacity(0.5) : _fgDim.withOpacity(0.08), borderRadius: BorderRadius.circular(14)),
        child: Text(label, style: TextStyle(color: _fg, fontSize: 13, fontWeight: FontWeight.w600)),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  //  ROLE SELECTION
  // ═══════════════════════════════════════════════════════════════════════════════

  Widget _buildRoleSelection() {
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_tethering, size: 72, color: _fg.withOpacity(0.9)),
            const SizedBox(height: 20),
            Text('Wi-Fi Direct Chat', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: _fg)),
            const SizedBox(height: 6),
            Text(_myDisplayName, style: TextStyle(fontSize: 12, color: _fgDim)),
            const SizedBox(height: 44),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _roleCard(icon: Icons.wifi_tethering_rounded, label: 'HOST', color: const Color(0xFF64D2FF), onTap: _startAsHost),
                const SizedBox(width: 20),
                _roleCard(icon: Icons.search_rounded, label: 'JOIN', color: const Color(0xFFFF6FA5), onTap: _startAsClient),
              ],
            ),
            const SizedBox(height: 28),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 40), child: Text(_status, style: TextStyle(color: _fgFaint, fontSize: 12), textAlign: TextAlign.center)),
          ],
        ),
      ),
    );
  }

  Widget _roleCard({required IconData icon, required String label, required Color color, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: GlassPanel(
        borderRadius: BorderRadius.circular(26),
        tint: color,
        opacity: 0.22,
        isDark: _isDark,
        child: SizedBox(
          width: 140,
          height: 160,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 44, color: color),
              const SizedBox(height: 12),
              Text(label, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: color, letterSpacing: 1.2)),
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  //  CLIENT HOST LIST
  // ═══════════════════════════════════════════════════════════════════════════════

  Widget _buildClientHostList() {
    if (_discoveredHosts.isEmpty) return _loadingPanel('Scanning for hosts nearby…');
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _discoveredHosts.length,
      itemBuilder: (_, i) {
        final h = _discoveredHosts[i];
        final name = h?.deviceName?.toString() ?? h?.name?.toString() ?? 'Unknown Host';
        final address = h?.deviceAddress?.toString() ?? h?.macAddress?.toString() ?? h?.id?.toString() ?? '';
        return RepaintBoundary(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: GlassLite(
              borderRadius: BorderRadius.circular(20),
              opacity: 0.14,
              isDark: _isDark,
              child: ListTile(
                leading: Icon(Icons.router_rounded, color: _fgDim),
                title: Text(name, style: TextStyle(color: _fg, fontWeight: FontWeight.w600)),
                subtitle: Text(address, style: TextStyle(color: _fgFaint, fontSize: 11)),
                trailing: TextButton(onPressed: () => _connectToHost(h), child: const Text('Connect', style: TextStyle(color: Color(0xFF64D2FF)))),
              ),
            ),
          ),
        );
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  //  CONTACTS LIST
  // ═══════════════════════════════════════════════════════════════════════════════

  Widget _buildContactsList() {
    final contacts = _contactBox.values.toList()..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    final pending = (_groupClients.length - contacts.length).clamp(0, 999);

    if (contacts.isEmpty) return _loadingPanel(_role == P2pRole.host ? 'Waiting for someone to join…' : 'Connecting…');

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: contacts.length + (pending > 0 ? 1 : 0),
      itemBuilder: (_, i) {
        if (i == contacts.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(child: Text('$pending more device(s) connecting…', style: TextStyle(color: _fgFaint, fontSize: 12))),
          );
        }
        final c = contacts[i];
        final unread = _messages.where((m) => m.contactId == c.uniqueId && !m.isMine && !m.isRead).length;
        return RepaintBoundary(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: GlassLite(
              borderRadius: BorderRadius.circular(20),
              opacity: 0.14,
              isDark: _isDark,
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: _fgDim.withOpacity(0.2),
                  backgroundImage: _avatarImage(c.avatarBase64),
                  child: c.avatarBase64 == null ? Text(c.displayName.isNotEmpty ? c.displayName[0].toUpperCase() : '?', style: TextStyle(color: _fg)) : null,
                ),
                title: Text(c.displayName, style: TextStyle(color: _fg, fontWeight: FontWeight.w600)),
                subtitle: Text(c.isBlocked ? 'Blocked' : (c.rsaPublicKey != null ? 'Encrypted' : 'Connected'), style: TextStyle(color: c.isBlocked ? Colors.redAccent : _fgDim, fontSize: 12)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (unread > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: const Color(0xFF7C4DFF), borderRadius: BorderRadius.circular(12)),
                        child: Text('$unread', style: const TextStyle(color: Colors.white, fontSize: 11)),
                      ),
                    IconButton(icon: Icon(c.isBlocked ? Icons.block : Icons.more_vert, color: _fgDim, size: 20), onPressed: () => _toggleBlockContact(c)),
                  ],
                ),
                onTap: c.isBlocked
                    ? null
                    : () {
                        setState(() => _selectedContact = c);
                        _markThreadRead(c.uniqueId);
                        _startHeartbeat();
                      },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _loadingPanel(String label) {
    return Center(
      child: GlassPanel(
        opacity: 0.16,
        borderRadius: BorderRadius.circular(24),
        isDark: _isDark,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.4, color: _fgDim)),
              const SizedBox(height: 14),
              Text(label, style: TextStyle(color: _fgDim)),
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  //  CHAT AREA
  // ═══════════════════════════════════════════════════════════════════════════════

  Widget _buildChatArea() {
    final contactId = _selectedContact!.uniqueId;
    final filtered = _messages.where((m) => m.contactId == contactId).toList()..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            reverse: true,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: filtered.length,
            itemBuilder: (_, i) => RepaintBoundary(child: _buildMessageBubble(filtered[filtered.length - 1 - i])),
          ),
        ),
        _buildComposer(),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  //  MESSAGE BUBBLE
  // ═══════════════════════════════════════════════════════════════════════════════

  Widget _buildMessageBubble(ChatMessage msg) {
    final isVoice = msg.type == 'voice';
    final isFile = msg.type == 'file';
    return Align(
      alignment: msg.isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPressStart: (details) => _showReactionPicker(msg, details.globalPosition),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.76),
          child: GlassLite(
            margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            borderRadius: BorderRadius.circular(20),
            tint: msg.isMine ? const Color(0xFF7C4DFF) : (_isDark ? Colors.white : Colors.black),
            opacity: msg.isMine ? 0.32 : 0.14,
            isDark: _isDark,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isVoice)
                    _buildVoiceRow(msg)
                  else if (isFile)
                    _buildFileRow(msg)
                  else
                    Text(msg.text, style: TextStyle(fontSize: 15, color: _fg, height: 1.3)),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_formatTime(msg.timestamp), style: TextStyle(fontSize: 10, color: _fgDim)),
                      if (msg.isMine) ...[
                        const SizedBox(width: 4),
                        if (msg.status == 'sending')
                          SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: _fgDim))
                        else if (msg.status == 'pending')
                          Icon(Icons.schedule, size: 13, color: Colors.orange)
                        else if (msg.status == 'sent')
                          Icon(Icons.check, size: 13, color: _fgDim)
                        else if (msg.status == 'delivered')
                          Icon(Icons.done_all, size: 13, color: _fgDim)
                        else if (msg.status == 'read')
                          Icon(Icons.done_all, size: 13, color: const Color(0xFF64D2FF)),
                      ],
                      if (isFile && _fileTransferProgress.containsKey(msg.id)) ...[
                        const SizedBox(width: 6),
                        Text('${(_fileTransferProgress[msg.id]! * 100).round()}%', style: TextStyle(fontSize: 10, color: _fgDim)),
                      ],
                    ],
                  ),
                  if (msg.reactions.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(spacing: 4, children: msg.reactions.map((r) => Text(r, style: const TextStyle(fontSize: 14))).toList()),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVoiceRow(ChatMessage msg) {
    final isPlaying = _playingMessageId == msg.id;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: () => _togglePlayVoice(msg),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(shape: BoxShape.circle, color: _fgDim.withOpacity(0.25)),
            child: Icon(isPlaying ? Icons.pause : Icons.play_arrow, color: _fg, size: 20),
          ),
        ),
        const SizedBox(width: 10),
        Icon(Icons.graphic_eq, color: _fgDim, size: 18),
        const SizedBox(width: 6),
        Text('Voice message', style: TextStyle(color: _fg, fontSize: 13)),
      ],
    );
  }

  Widget _buildFileRow(ChatMessage msg) {
    final isSending = _fileTransferProgress.containsKey(msg.id);
    final isPending = msg.status == 'pending';
    return GestureDetector(
      onTap: (isSending || isPending) ? null : () => _handleFileTap(msg),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isSending ? Icons.hourglass_empty : (isPending ? Icons.schedule : Icons.insert_drive_file_outlined),
              color: _fgDim, size: 22),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              msg.fileName ?? msg.text,
              style: TextStyle(color: _fg, fontSize: 13, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isSending)
            IconButton(
              icon: Icon(Icons.cancel, color: Colors.redAccent, size: 18),
              onPressed: () => _cancelFileTransfer(msg.id),
            ),
          if (isPending)
            IconButton(
              icon: Icon(Icons.refresh, color: _fgDim, size: 18),
              onPressed: () => _retrySendPending(msg),
            ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  //  COMPOSER (with voice FX toggle)
  // ═══════════════════════════════════════════════════════════════════════════════

  Widget _buildComposer() {
    return GlassPanel(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      borderRadius: BorderRadius.circular(28),
      opacity: 0.18,
      isDark: _isDark,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            IconButton(
              icon: Icon(Icons.attach_file_rounded, color: _fgDim, size: 20),
              onPressed: _pickAndSendFile,
            ),

            // FX toggle
            GestureDetector(
              onTap: () {
                setState(() {
                  _voiceEffect = VoiceEffect.values[(_voiceEffect.index + 1) % VoiceEffect.values.length];
                });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: _voiceEffect == VoiceEffect.normal
                      ? Colors.transparent
                      : const Color(0xFF7C4DFF).withOpacity(0.35),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _voiceEffect == VoiceEffect.normal ? Colors.transparent : const Color(0xFF7C4DFF),
                    width: 1,
                  ),
                ),
                child: Text(
                  _voiceEffect == VoiceEffect.normal
                      ? 'FX'
                      : (_voiceEffect == VoiceEffect.minion ? '🐿️' : '🐢'),
                  style: TextStyle(
                    color: _fg,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),

            GestureDetector(
              onLongPressStart: (_) => _startRecordingVoiceMessage(),
              onLongPressEnd: (_) => _stopRecordingAndSendVoiceMessage(),
              onLongPressCancel: _cancelRecording,
              child: CircleAvatar(
                radius: 19,
                backgroundColor: _isRecordingVoiceMessage ? Colors.redAccent : _fgDim.withOpacity(0.16),
                child: Icon(_isRecordingVoiceMessage ? Icons.mic : Icons.mic_none, color: _fg, size: 19),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _textController,
                style: TextStyle(color: _fg),
                decoration: InputDecoration(hintText: 'Message', hintStyle: TextStyle(color: _fgFaint), border: InputBorder.none),
                onChanged: _onTextChanged,
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
            const SizedBox(width: 6),
            CircleAvatar(
              radius: 19,
              backgroundColor: const Color(0xFF7C4DFF),
              child: IconButton(icon: const Icon(Icons.arrow_upward, color: Colors.white, size: 18), onPressed: _sendMessage),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  //  RECORDING OVERLAY
  // ═══════════════════════════════════════════════════════════════════════════════

  Widget _buildRecordingOverlay() {
    return Positioned(
      left: 24,
      right: 24,
      bottom: 90,
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 200),
          builder: (context, v, child) => Opacity(opacity: v, child: child),
          child: GlassPanel(
            borderRadius: BorderRadius.circular(20),
            opacity: 0.3,
            tint: Colors.redAccent,
            isDark: _isDark,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _pulsingDot(),
                  const SizedBox(width: 10),
                  Text('Recording — release to send', style: TextStyle(color: _fg, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pulsingDot() {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.4, end: 1),
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeInOut,
      builder: (context, v, _) => Opacity(opacity: v, child: Container(width: 10, height: 10, decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle))),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  //  CALL OVERLAY
  // ═══════════════════════════════════════════════════════════════════════════════

  Widget _buildCallOverlay() {
    final peer = _callPeer;
    return Positioned.fill(
      child: GlassPanel(
        borderRadius: BorderRadius.zero,
        opacity: 0.55,
        isDark: _isDark,
        child: SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const SizedBox(height: 40),
              Column(
                children: [
                  CircleAvatar(
                    radius: 54,
                    backgroundColor: _fgDim.withOpacity(0.2),
                    backgroundImage: _avatarImage(peer?.avatarBase64),
                    child: peer?.avatarBase64 == null
                        ? Text(peer?.displayName.isNotEmpty == true ? peer!.displayName[0].toUpperCase() : '?', style: TextStyle(color: _fg, fontSize: 36))
                        : null,
                  ),
                  const SizedBox(height: 18),
                  Text(peer?.displayName ?? 'Unknown', style: TextStyle(color: _fg, fontSize: 24, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Text(_callStatusLabel(), style: TextStyle(color: _fgDim, fontSize: 14)),
                  if (_callPhase == CallPhase.active) ...[
                    const SizedBox(height: 4),
                    Text('Live · ${_activeCallQuality.label}', style: TextStyle(color: _fgFaint, fontSize: 11)),
                  ],
                ],
              ),
              Padding(padding: const EdgeInsets.only(bottom: 48), child: _buildCallControls()),
            ],
          ),
        ),
      ),
    );
  }

  String _callStatusLabel() {
    switch (_callPhase) {
      case CallPhase.outgoingRinging:
        return 'Ringing…';
      case CallPhase.incomingRinging:
        return 'Incoming call…';
      case CallPhase.active:
        return 'On call';
      case CallPhase.idle:
        return '';
    }
  }

  Widget _buildCallControls() {
    if (_callPhase == CallPhase.incomingRinging) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _callButton(icon: Icons.call_end, color: Colors.redAccent, onTap: _declineCall),
          const SizedBox(width: 28),
          _callButton(icon: Icons.call, color: Colors.greenAccent.shade400, onTap: _acceptCall),
        ],
      );
    }
    if (_callPhase == CallPhase.outgoingRinging) {
      return Column(
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [_callButton(icon: Icons.call_end, color: Colors.redAccent, onTap: () => _endCall())]),
          const SizedBox(height: 18),
          TextButton.icon(
            onPressed: _emergencyForceStart,
            icon: const Icon(Icons.warning_amber_rounded, color: Colors.orangeAccent, size: 18),
            label: const Text('Emergency Call (connect without waiting)', style: TextStyle(color: Colors.orangeAccent)),
          ),
        ],
      );
    }
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [_callButton(icon: Icons.call_end, color: Colors.redAccent, onTap: () => _endCall())]);
  }

  Widget _callButton({required IconData icon, required Color color, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(width: 64, height: 64, decoration: BoxDecoration(shape: BoxShape.circle, color: color), child: Icon(icon, color: Colors.white, size: 28)),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════════
  //  DISPOSE
  // ═══════════════════════════════════════════════════════════════════════════════

  @override
  void dispose() {
    _dismissReactionPicker();
    _ringTimer?.cancel();
    _callTimeoutTimer?.cancel();
    _stopRealtimeAudio();
    _heartbeatTimer?.cancel();
    _typingDebounceTimer?.cancel();
    _offlineRetryTimer?.cancel();
    _hostStateSub?.cancel();
    _clientStateSub?.cancel();
    _hostClientsSub?.cancel();
    _hostTextSub?.cancel();
    _clientTextSub?.cancel();
    _hostFilesSub?.cancel();
    _clientFilesSub?.cancel();
    _scanSub?.cancel();
    _host.dispose();
    _client.dispose();
    _audioRecorder.closeRecorder();
    _audioPlayer.closePlayer();
    _callPlayer.closePlayer();
    _textController.dispose();
    super.dispose();
  }
}

class CancelToken {
  bool _cancelled = false;
  void cancel() => _cancelled = true;
  bool get isCancelled => _cancelled;
}
