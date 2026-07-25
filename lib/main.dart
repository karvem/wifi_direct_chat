import 'dart:async';
import 'dart:convert' hide Codec;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_p2p_connection/flutter_p2p_connection.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:encryptify/encryptify.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_sound/flutter_sound.dart';

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

  Contact({
    required this.uniqueId,
    required this.displayName,
    this.deviceAddress,
    this.rsaPublicKey,
    required this.lastSeen,
    this.isBlocked = false,
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
  final String type; // 'text' | 'voice'
  @HiveField(7)
  final String? filePath;
  @HiveField(8)
  final String? fileName;
  @HiveField(9)
  bool isRead;

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
  }) : reactions = reactions ?? [];
}

// ═══════════════════════════════════════════════════════════════════════════════
//  HIVE ADAPTERS
//  Standard field-count + generic write/read pattern (what hive_generator would
//  produce). This is what actually preserves the null/empty distinction that
//  the old hand-rolled version threw away, and it can tolerate schema changes.
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
    );
  }

  @override
  void write(BinaryWriter writer, Contact obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.uniqueId)
      ..writeByte(1)
      ..write(obj.displayName)
      ..writeByte(2)
      ..write(obj.deviceAddress)
      ..writeByte(3)
      ..write(obj.rsaPublicKey)
      ..writeByte(4)
      ..write(obj.lastSeen)
      ..writeByte(5)
      ..write(obj.isBlocked);
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
    );
  }

  @override
  void write(BinaryWriter writer, ChatMessage obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.contactId)
      ..writeByte(2)
      ..write(obj.text)
      ..writeByte(3)
      ..write(obj.isMine)
      ..writeByte(4)
      ..write(obj.timestamp)
      ..writeByte(5)
      ..write(obj.reactions)
      ..writeByte(6)
      ..write(obj.type)
      ..writeByte(7)
      ..write(obj.filePath)
      ..writeByte(8)
      ..write(obj.fileName)
      ..writeByte(9)
      ..write(obj.isRead);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  MESSAGE ENVELOPE — every string that goes over broadcastText() is one of these,
//  JSON-encoded. This is what solves two problems the raw plugin API can't:
//  1) streamReceivedTexts() never tells you WHO sent a message.
//  2) there was no structured way to carry reactions / read receipts / key
//     exchange / file linkage over a plain-text channel.
// ═══════════════════════════════════════════════════════════════════════════════

class Envelope {
  final String type; // hello | text | reaction | read_receipt | file_notice
  final String id;
  final String senderId;
  final String senderName;
  final String? to; // null = everyone, otherwise a specific deviceId
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

  static Future<String?> getMyPublicKey() async {
    return await _storage.read(key: _myPublicKeyKey);
  }

  static Future<String?> getMyPrivateKey() async {
    return await _storage.read(key: _myPrivateKeyKey);
  }

  static Future<Map<String, String>> encryptMessage(
    String plaintext,
    String recipientPublicKey,
  ) async {
    final result = await Encryptify.encryptMessage(
      message: plaintext,
      recipientRSAPublicKey: recipientPublicKey,
    );
    return {
      'encryptedMessage': result.encryptedMessage,
      'encryptedAESKey': result.encryptedAesKey,
      'encryptedIV': result.encryptedIV,
    };
  }

  // FIX: this used to hardcode senderID: 'sender', which meant decryption
  // context was always wrong for anyone but a single hardcoded peer. It now
  // takes the real sender's deviceId from the envelope.
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
    // Local data was written by the old, incompatible adapter format.
    // One-time reset so the app doesn't crash on launch.
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
    return MaterialApp(
      title: 'Wi-Fi Direct Chat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C4DFF),
          brightness: Brightness.dark,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  LIQUID GLASS PRIMITIVES
// ═══════════════════════════════════════════════════════════════════════════════

class GlassPanel extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final double blur;
  final double opacity;
  final EdgeInsetsGeometry? margin;
  final Color tint;

  const GlassPanel({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.blur = 22,
    this.opacity = 0.16,
    this.margin,
    this.tint = Colors.white,
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
              border: Border.all(color: Colors.white.withOpacity(0.22), width: 1),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.28), blurRadius: 24, offset: const Offset(0, 10)),
              ],
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _AnimatedMeshBackground extends StatefulWidget {
  const _AnimatedMeshBackground();
  @override
  State<_AnimatedMeshBackground> createState() => _AnimatedMeshBackgroundState();
}

class _AnimatedMeshBackgroundState extends State<_AnimatedMeshBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 20))..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value * 2 * math.pi;
        return Stack(
          children: [
            Container(color: const Color(0xFF0A0A14)),
            _blob(size.width * 0.25 + 40 * math.sin(t), size.height * 0.18 + 30 * math.cos(t), 260,
                const Color(0xFF7C4DFF)),
            _blob(size.width * 0.85 + 30 * math.cos(t * 1.3), size.height * 0.35 + 40 * math.sin(t * 1.1), 240,
                const Color(0xFF00E5FF)),
            _blob(size.width * 0.3 + 30 * math.sin(t * 0.7), size.height * 0.82 + 20 * math.cos(t * 0.9), 280,
                const Color(0xFFFF4D8D)),
          ],
        );
      },
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
          gradient: RadialGradient(colors: [color.withOpacity(0.55), color.withOpacity(0.0)]),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  HOME SCREEN
// ═══════════════════════════════════════════════════════════════════════════════

enum P2pRole { none, host, client }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // ── Controllers & Boxes ─────────────────────────────────────────────────────
  final TextEditingController _textController = TextEditingController();
  late Box<Contact> _contactBox;
  late Box<ChatMessage> _messageBox;

  // ── P2P Instances ─────────────────────────────────────────────────────────
  final FlutterP2pHost _host = FlutterP2pHost();
  final FlutterP2pClient _client = FlutterP2pClient();

  // ── Identity ─────────────────────────────────────────────────────────────
  String _myDeviceId = '';
  String? _myPublicKey;
  String _myDisplayName = '';

  // ── State ─────────────────────────────────────────────────────────────────
  P2pRole _role = P2pRole.none;
  bool _isConnected = false;
  String _status = 'Initializing…';

  List<ChatMessage> _messages = [];
  List<dynamic> _discoveredHosts = []; // BleDiscoveredDevice fields aren't fully documented
  List<P2pClientInfo> _groupClients = [];
  Contact? _selectedContact;

  // ── Handshake / protocol bookkeeping ────────────────────────────────────
  final Set<String> _helloedTo = {};
  final Map<String, Envelope> _pendingFileNotices = {};
  final Map<String, ReceivableFileInfo> _pendingReceivableInfo = {};
  final Set<String> _handledFileIds = {};

  // ── Voice ─────────────────────────────────────────────────────────────────
  final FlutterSoundRecorder _audioRecorder = FlutterSoundRecorder();
  final FlutterSoundPlayer _audioPlayer = FlutterSoundPlayer();
  bool _isRecordingVoiceMessage = false;
  String? _playingMessageId;

  // ── Subscriptions ────────────────────────────────────────────────────────
  StreamSubscription? _hostStateSub;
  StreamSubscription? _clientStateSub;
  StreamSubscription? _hostClientsSub;
  StreamSubscription? _hostTextSub;
  StreamSubscription? _clientTextSub;
  StreamSubscription? _hostFilesSub;
  StreamSubscription? _clientFilesSub;
  StreamSubscription? _scanSub;

  // ═══════════════════════════════════════════════════════════════════════════
  //  LIFECYCLE
  // ═══════════════════════════════════════════════════════════════════════════

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

    await _audioRecorder.openRecorder();
    await _audioPlayer.openPlayer();

    await _host.initialize();
    await _client.initialize();

    setState(() => _status = 'Ready — choose Host or Join');
  }

  // Only microphone here: the plugin's own checkP2pPermissions / askP2pPermissions,
  // checkBluetoothPermissions / askBluetoothPermissions and checkStoragePermission /
  // askStoragePermission (called inside _startAsHost/_startAsClient) already cover
  // location, nearby-Wi-Fi, Bluetooth and storage — asking again here just meant
  // double prompts.
  Future<void> _requestPermissions() async {
    await Permission.microphone.request();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  HOST ROLE
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _startAsHost() async {
    setState(() => _status = 'Starting as Host…');
    try {
      if (!await _host.checkStoragePermission()) await _host.askStoragePermission();
      if (!await _host.checkWifiEnabled()) await _host.enableWifiServices();
      if (!await _host.checkLocationEnabled()) await _host.enableLocationServices();
      if (!await _host.checkBluetoothEnabled()) await _host.enableBluetoothServices();
      if (!await _host.checkP2pPermissions()) await _host.askP2pPermissions();
      if (!await _host.checkBluetoothPermissions()) await _host.askBluetoothPermissions();

      final state = await _host.createGroup(advertise: true);
      debugPrint('HOST createGroup state: $state');

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
      debugPrint('HOST STATE: active=${state.isActive}, reason=${state.failureReason}');
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
      debugPrint('HOST CLIENTS: ${clients.length} connected');
      final grew = clients.length > _groupClients.length;
      setState(() => _groupClients = clients);
      if (grew) _sendHello();
    });

    _hostTextSub = _host.streamReceivedTexts().listen(_onRawTextReceived);
    _hostFilesSub = _host.streamReceivedFilesInfo().listen(_onReceivedFilesInfo);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  CLIENT ROLE
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _startAsClient() async {
    setState(() => _status = 'Starting as Client…');
    try {
      if (!await _client.checkStoragePermission()) await _client.askStoragePermission();
      if (!await _client.checkWifiEnabled()) await _client.enableWifiServices();
      if (!await _client.checkLocationEnabled()) await _client.enableLocationServices();
      if (!await _client.checkBluetoothEnabled()) await _client.enableBluetoothServices();
      if (!await _client.checkP2pPermissions()) await _client.askP2pPermissions();
      if (!await _client.checkBluetoothPermissions()) await _client.askBluetoothPermissions();

      setState(() => _role = P2pRole.client);
      _listenAsClient();

      _scanSub = await _client.startScan((devices) {
        debugPrint('CLIENT SCAN: ${devices.length} hosts found');
        setState(() => _discoveredHosts = devices);
      });

      setState(() => _status = 'Scanning for hosts…');
    } catch (e) {
      setState(() => _status = 'Could not start client: $e');
    }
  }

  void _listenAsClient() {
    _clientStateSub = _client.streamHotspotState().listen((state) {
      debugPrint('CLIENT STATE: active=${state.isActive}, ssid=${state.hostSsid}');
      final wasConnected = _isConnected;
      setState(() {
        _isConnected = state.isActive;
        _status = state.isActive
            ? 'Connected to ${state.hostSsid ?? 'host'}'
            : 'Disconnected / Scanning…';
      });
      if (!wasConnected && state.isActive) _sendHello();
    });

    _clientTextSub = _client.streamReceivedTexts().listen(_onRawTextReceived);
    _clientFilesSub = _client.streamReceivedFilesInfo().listen(_onReceivedFilesInfo);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  CONNECTION (Client → Host)
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _connectToHost(dynamic device) async {
    final name = device?.deviceName?.toString() ?? device?.name?.toString() ?? 'Unknown Host';
    setState(() => _status = 'Connecting to $name…');
    try {
      await _client.connectWithDevice(device);
      setState(() => _status = 'Connected — exchanging device info…');
      // The actual Contact for the host is created once their "hello" envelope
      // arrives (see _handleHelloEnvelope) — that's what carries their real,
      // persistent device id and public key, not the transient BLE identity.
    } catch (e) {
      setState(() => _status = 'Connection failed: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  PROTOCOL — hello / handshake
  // ═══════════════════════════════════════════════════════════════════════════

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
      data: {'publicKey': _myPublicKey},
    );
    try {
      await _sendEnvelope(env);
    } catch (e) {
      debugPrint('HELLO SEND ERROR: $e');
    }
  }

  Future<void> _handleHelloEnvelope(Envelope env) async {
    final publicKey = env.data['publicKey'] as String?;
    final existing = _contactBox.get(env.senderId);
    final contact = Contact(
      uniqueId: env.senderId,
      displayName: env.senderName,
      deviceAddress: existing?.deviceAddress,
      rsaPublicKey: publicKey ?? existing?.rsaPublicKey,
      lastSeen: DateTime.now(),
      isBlocked: existing?.isBlocked ?? false,
    );
    await _contactBox.put(env.senderId, contact);
    _refresh();

    if (_selectedContact?.uniqueId == env.senderId) {
      setState(() => _selectedContact = contact);
    }

    if (!_helloedTo.contains(env.senderId)) {
      _helloedTo.add(env.senderId);
      await _sendHello();
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  PROTOCOL — dispatch incoming text
  // ═══════════════════════════════════════════════════════════════════════════

  void _onRawTextReceived(String raw) {
    final env = Envelope.tryDecode(raw);
    if (env == null || env.senderId == _myDeviceId) return;

    final knownSender = _contactBox.get(env.senderId);
    if (knownSender != null && knownSender.isBlocked && env.type != 'hello') return;

    switch (env.type) {
      case 'hello':
        _handleHelloEnvelope(env);
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
      case 'file_notice':
        _handleFileNoticeEnvelope(env);
        break;
    }
  }

  Future<void> _handleTextEnvelope(Envelope env) async {
    if (env.to != null && env.to != _myDeviceId) return; // meant for someone else in the group

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
        debugPrint('DECRYPT ERROR: $e');
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
      isRead: _selectedContact?.uniqueId == env.senderId,
    );
    setState(() => _messages.add(msg));
    await _messageBox.put(msg.id, msg);

    if (_selectedContact?.uniqueId == env.senderId) {
      await _markThreadRead(env.senderId);
    }
  }

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

  void _handleReadReceiptEnvelope(Envelope env) {
    final upTo = env.data['upTo'] as int?;
    if (upTo == null) return;
    final cutoff = DateTime.fromMillisecondsSinceEpoch(upTo);
    var changed = false;
    for (final m in _messages) {
      if (m.contactId == env.senderId && m.isMine && !m.isRead && !m.timestamp.isAfter(cutoff)) {
        m.isRead = true;
        _messageBox.put(m.id, m);
        changed = true;
      }
    }
    if (changed) setState(() {});
  }

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
      final ok = _role == P2pRole.host
          ? await _host.downloadFile(fileId, dir)
          : await _client.downloadFile(fileId, dir);
      if (ok != true) return;

      final savedPath = '$dir/${info.info.name}';
      final msg = ChatMessage(
        id: const Uuid().v4(),
        contactId: notice.senderId,
        text: '🎤 Voice message',
        isMine: false,
        timestamp: DateTime.fromMillisecondsSinceEpoch(notice.timestamp),
        type: 'voice',
        filePath: savedPath,
        isRead: _selectedContact?.uniqueId == notice.senderId,
      );
      setState(() => _messages.add(msg));
      await _messageBox.put(msg.id, msg);
      if (_selectedContact?.uniqueId == notice.senderId) {
        await _markThreadRead(notice.senderId);
      }
    } catch (e) {
      debugPrint('FILE DOWNLOAD ERROR: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  SENDING — text
  // ═══════════════════════════════════════════════════════════════════════════

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
        debugPrint('ENCRYPT ERROR (falling back to plaintext): $e');
        data = {'enc': false, 'text': text};
      }
    } else {
      data = {'enc': false, 'text': text};
    }

    final env = Envelope(
      type: 'text',
      senderId: _myDeviceId,
      senderName: _myDisplayName,
      to: peer.uniqueId,
      data: data,
    );

    final msg = ChatMessage(
      id: env.id,
      contactId: peer.uniqueId,
      text: text,
      isMine: true,
      timestamp: DateTime.fromMillisecondsSinceEpoch(env.timestamp),
    );
    setState(() {
      _messages.add(msg);
      _textController.clear();
    });
    await _messageBox.put(msg.id, msg);

    try {
      await _sendEnvelope(env);
    } catch (e) {
      debugPrint('SEND ERROR: $e');
      setState(() => _status = 'Send failed: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  READ RECEIPTS
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _markThreadRead(String contactId) async {
    final toUpdate =
        _messages.where((m) => m.contactId == contactId && !m.isMine && !m.isRead).toList();
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

  // ═══════════════════════════════════════════════════════════════════════════
  //  REACTIONS
  // ═══════════════════════════════════════════════════════════════════════════

  void _showReactionPicker(ChatMessage msg) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(16),
        child: GlassPanel(
          borderRadius: BorderRadius.circular(28),
          opacity: 0.28,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Wrap(
              spacing: 16,
              runSpacing: 8,
              children: ['👍', '❤️', '😂', '😮', '😢', '🙏'].map((emoji) {
                return GestureDetector(
                  onTap: () {
                    Navigator.pop(context);
                    _addReaction(msg, emoji);
                  },
                  child: Text(emoji, style: const TextStyle(fontSize: 30)),
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
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

  // ═══════════════════════════════════════════════════════════════════════════
  //  VOICE NOTES — recording, real sending, playback
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _startRecordingVoiceMessage() async {
    if (_selectedContact == null) return;
    final tempDir = await getTemporaryDirectory();
    final path = '${tempDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.aac';
    await _audioRecorder.startRecorder(toFile: path, codec: Codec.aacADTS);
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

    final peer = _selectedContact!;
    final msg = ChatMessage(
      id: const Uuid().v4(),
      contactId: peer.uniqueId,
      text: '🎤 Voice message',
      isMine: true,
      timestamp: DateTime.now(),
      type: 'voice',
      filePath: path,
    );
    setState(() => _messages.add(msg));
    await _messageBox.put(msg.id, msg);

    try {
      final file = File(path);
      final info = _role == P2pRole.host
          ? await _host.broadcastFile(file)
          : await _client.broadcastFile(file);
      if (info == null) {
        setState(() => _status = 'Voice note failed to send');
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

  Future<void> _togglePlayVoice(ChatMessage msg) async {
    if (msg.filePath == null) return;
    if (_playingMessageId == msg.id) {
      await _audioPlayer.stopPlayer();
      setState(() => _playingMessageId = null);
      return;
    }
    if (_playingMessageId != null) {
      await _audioPlayer.stopPlayer();
    }
    setState(() => _playingMessageId = msg.id);
    try {
      await _audioPlayer.startPlayer(
        fromURI: msg.filePath,
        whenFinished: () {
          if (mounted) setState(() => _playingMessageId = null);
        },
      );
    } catch (e) {
      debugPrint('PLAYBACK ERROR: $e');
      if (mounted) setState(() => _playingMessageId = null);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  BLOCKING / CALL / MISC
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _toggleBlockContact(Contact c) async {
    c.isBlocked = !c.isBlocked;
    await _contactBox.put(c.uniqueId, c);
    if (_selectedContact?.uniqueId == c.uniqueId && c.isBlocked) {
      setState(() => _selectedContact = null);
    } else {
      _refresh();
    }
  }

  void _toggleCall() {
    // The plugin only exposes text and file transfer — there is no audio/video
    // streaming API to build a real call on top of, so this stays honest
    // instead of pretending to place a call.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Live calling isn't implemented — this plugin only supports text and file transfer."),
      ),
    );
  }

  Future<void> _disconnect() async {
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
    await _hostClientsSub?.cancel();
    await _hostTextSub?.cancel();
    await _hostFilesSub?.cancel();
    await _clientStateSub?.cancel();
    await _clientTextSub?.cancel();
    await _clientFilesSub?.cancel();
    await _scanSub?.cancel();
    setState(() {
      _isConnected = false;
      _role = P2pRole.none;
      _discoveredHosts.clear();
      _groupClients.clear();
      _selectedContact = null;
      _helloedTo.clear();
      _status = 'Disconnected';
    });
  }

  Future<void> _promptForDisplayName() async {
    final controller = TextEditingController(text: _myDisplayName);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF17172A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Your display name', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(hintText: 'Enter a name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      setState(() => _myDisplayName = result);
      await EncryptionService.setMyDisplayName(result);
    }
  }

  void _loadMessages() {
    setState(() => _messages = _messageBox.values.toList());
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  String _formatTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  // ═══════════════════════════════════════════════════════════════════════════
  //  UI
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          const Positioned.fill(child: _AnimatedMeshBackground()),
          SafeArea(
            child: Column(
              children: [
                _buildTopBar(),
                Expanded(child: _buildMainContent()),
              ],
            ),
          ),
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

  Widget _buildTopBar() {
    return GlassPanel(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      borderRadius: BorderRadius.circular(24),
      opacity: 0.16,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          children: [
            if (_selectedContact != null)
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 18),
                onPressed: () => setState(() => _selectedContact = null),
              )
            else
              const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _selectedContact?.displayName ?? 'Wi-Fi Direct',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 17),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _status,
                    style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (_selectedContact != null)
              IconButton(
                icon: const Icon(Icons.call_outlined, color: Colors.white, size: 20),
                onPressed: _toggleCall,
              ),
            if (_role != P2pRole.none)
              IconButton(
                icon: const Icon(Icons.logout, color: Colors.white, size: 20),
                onPressed: _disconnect,
              ),
            IconButton(
              icon: const Icon(Icons.edit_outlined, color: Colors.white54, size: 18),
              onPressed: _promptForDisplayName,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRoleSelection() {
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_tethering, size: 72, color: Colors.white.withOpacity(0.9)),
            const SizedBox(height: 20),
            const Text(
              'Wi-Fi Direct Chat',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white),
            ),
            const SizedBox(height: 6),
            Text(
              _myDisplayName,
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
            const SizedBox(height: 44),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _roleCard(
                  icon: Icons.wifi_tethering_rounded,
                  label: 'HOST',
                  color: const Color(0xFF64D2FF),
                  onTap: _startAsHost,
                ),
                const SizedBox(width: 20),
                _roleCard(
                  icon: Icons.search_rounded,
                  label: 'JOIN',
                  color: const Color(0xFFFF6FA5),
                  onTap: _startAsClient,
                ),
              ],
            ),
            const SizedBox(height: 28),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                _status,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _roleCard({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: GlassPanel(
        borderRadius: BorderRadius.circular(26),
        tint: color,
        opacity: 0.22,
        child: SizedBox(
          width: 140,
          height: 160,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 44, color: color),
              const SizedBox(height: 12),
              Text(
                label,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: color, letterSpacing: 1.2),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildClientHostList() {
    if (_discoveredHosts.isEmpty) {
      return _loadingPanel('Scanning for hosts nearby…');
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _discoveredHosts.length,
      itemBuilder: (_, i) {
        final h = _discoveredHosts[i];
        final name = h?.deviceName?.toString() ?? h?.name?.toString() ?? 'Unknown Host';
        final address = h?.deviceAddress?.toString() ?? h?.macAddress?.toString() ?? h?.id?.toString() ?? '';
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: GlassPanel(
            borderRadius: BorderRadius.circular(20),
            opacity: 0.14,
            child: ListTile(
              leading: const Icon(Icons.router_rounded, color: Colors.white70),
              title: Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              subtitle: Text(address, style: const TextStyle(color: Colors.white38, fontSize: 11)),
              trailing: TextButton(
                onPressed: () => _connectToHost(h),
                child: const Text('Connect', style: TextStyle(color: Color(0xFF64D2FF))),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildContactsList() {
    final contacts = _contactBox.values.toList()..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    final pending = (_groupClients.length - contacts.length).clamp(0, 999);

    if (contacts.isEmpty) {
      return _loadingPanel(
        _role == P2pRole.host ? 'Waiting for someone to join…' : 'Connecting…',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: contacts.length + (pending > 0 ? 1 : 0),
      itemBuilder: (_, i) {
        if (i == contacts.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Text('$pending more device(s) connecting…',
                  style: const TextStyle(color: Colors.white38, fontSize: 12)),
            ),
          );
        }
        final c = contacts[i];
        final unread = _messages.where((m) => m.contactId == c.uniqueId && !m.isMine && !m.isRead).length;
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: GlassPanel(
            borderRadius: BorderRadius.circular(20),
            opacity: 0.14,
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.white.withOpacity(0.18),
                child: Text(
                  c.displayName.isNotEmpty ? c.displayName[0].toUpperCase() : '?',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
              title: Text(c.displayName,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              subtitle: Text(
                c.isBlocked ? 'Blocked' : (c.rsaPublicKey != null ? 'Encrypted' : 'Connected'),
                style: TextStyle(color: c.isBlocked ? Colors.redAccent : Colors.white54, fontSize: 12),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (unread > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration:
                          BoxDecoration(color: const Color(0xFF7C4DFF), borderRadius: BorderRadius.circular(12)),
                      child: Text('$unread', style: const TextStyle(color: Colors.white, fontSize: 11)),
                    ),
                  IconButton(
                    icon: Icon(c.isBlocked ? Icons.block : Icons.more_vert, color: Colors.white54, size: 20),
                    onPressed: () => _toggleBlockContact(c),
                  ),
                ],
              ),
              onTap: c.isBlocked
                  ? null
                  : () {
                      setState(() => _selectedContact = c);
                      _markThreadRead(c.uniqueId);
                    },
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
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white70),
              ),
              const SizedBox(height: 14),
              Text(label, style: const TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChatArea() {
    final contactId = _selectedContact!.uniqueId;
    final filtered = _messages.where((m) => m.contactId == contactId).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            reverse: true,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: filtered.length,
            itemBuilder: (_, i) => _buildMessageBubble(filtered[filtered.length - 1 - i]),
          ),
        ),
        _buildComposer(),
      ],
    );
  }

  Widget _buildMessageBubble(ChatMessage msg) {
    final isVoice = msg.type == 'voice';
    return Align(
      alignment: msg.isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _showReactionPicker(msg),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.76),
          child: GlassPanel(
            margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            borderRadius: BorderRadius.circular(20),
            tint: msg.isMine ? const Color(0xFF7C4DFF) : Colors.white,
            opacity: msg.isMine ? 0.32 : 0.14,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isVoice)
                    _buildVoiceRow(msg)
                  else
                    Text(msg.text, style: const TextStyle(fontSize: 15, color: Colors.white, height: 1.3)),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_formatTime(msg.timestamp),
                          style: TextStyle(fontSize: 10, color: Colors.white.withOpacity(0.55))),
                      if (msg.isMine) ...[
                        const SizedBox(width: 4),
                        Icon(
                          msg.isRead ? Icons.done_all : Icons.done,
                          size: 13,
                          color: msg.isRead ? const Color(0xFF64D2FF) : Colors.white.withOpacity(0.55),
                        ),
                      ],
                    ],
                  ),
                  if (msg.reactions.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 4,
                      children: msg.reactions.map((r) => Text(r, style: const TextStyle(fontSize: 14))).toList(),
                    ),
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
            decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withOpacity(0.25)),
            child: Icon(isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white, size: 20),
          ),
        ),
        const SizedBox(width: 10),
        const Icon(Icons.graphic_eq, color: Colors.white70, size: 18),
        const SizedBox(width: 6),
        const Text('Voice message', style: TextStyle(color: Colors.white, fontSize: 13)),
      ],
    );
  }

  Widget _buildComposer() {
    return GlassPanel(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      borderRadius: BorderRadius.circular(28),
      opacity: 0.18,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            GestureDetector(
              onLongPressStart: (_) => _startRecordingVoiceMessage(),
              onLongPressEnd: (_) => _stopRecordingAndSendVoiceMessage(),
              onLongPressCancel: _cancelRecording,
              child: CircleAvatar(
                radius: 19,
                backgroundColor: _isRecordingVoiceMessage ? Colors.redAccent : Colors.white.withOpacity(0.16),
                child: Icon(_isRecordingVoiceMessage ? Icons.mic : Icons.mic_none, color: Colors.white, size: 19),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _textController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Message',
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
                  border: InputBorder.none,
                ),
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
            const SizedBox(width: 6),
            CircleAvatar(
              radius: 19,
              backgroundColor: const Color(0xFF7C4DFF),
              child: IconButton(
                icon: const Icon(Icons.arrow_upward, color: Colors.white, size: 18),
                onPressed: _sendMessage,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  DISPOSE
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  void dispose() {
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
    _textController.dispose();
    super.dispose();
  }
}
