import 'dart:async';
import 'dart:io';
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
  final List<String> reactions;
  @HiveField(6)
  final String type;
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
    this.reactions = const [],
    this.type = 'text',
    this.filePath,
    this.fileName,
    this.isRead = false,
  });
}

// ═══════════════════════════════════════════════════════════════════════════════
//  HIVE ADAPTERS
// ═══════════════════════════════════════════════════════════════════════════════

class ContactAdapter extends TypeAdapter<Contact> {
  @override
  final int typeId = 0;
  @override
  Contact read(BinaryReader reader) {
    return Contact(
      uniqueId: reader.readString(),
      displayName: reader.readString(),
      deviceAddress: reader.readString(),
      rsaPublicKey: reader.readString(),
      lastSeen: DateTime.fromMillisecondsSinceEpoch(reader.readInt()),
      isBlocked: reader.readBool(),
    );
  }
  @override
  void write(BinaryWriter writer, Contact obj) {
    writer.writeString(obj.uniqueId);
    writer.writeString(obj.displayName);
    writer.writeString(obj.deviceAddress ?? '');
    writer.writeString(obj.rsaPublicKey ?? '');
    writer.writeInt(obj.lastSeen.millisecondsSinceEpoch);
    writer.writeBool(obj.isBlocked);
  }
}

class ChatMessageAdapter extends TypeAdapter<ChatMessage> {
  @override
  final int typeId = 1;
  @override
  ChatMessage read(BinaryReader reader) {
    return ChatMessage(
      id: reader.readString(),
      contactId: reader.readString(),
      text: reader.readString(),
      isMine: reader.readBool(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(reader.readInt()),
      reactions: reader.readList().cast<String>(),
      type: reader.readString(),
      filePath: reader.readString(),
      fileName: reader.readString(),
      isRead: reader.readBool(),
    );
  }
  @override
  void write(BinaryWriter writer, ChatMessage obj) {
    writer.writeString(obj.id);
    writer.writeString(obj.contactId);
    writer.writeString(obj.text);
    writer.writeBool(obj.isMine);
    writer.writeInt(obj.timestamp.millisecondsSinceEpoch);
    writer.writeList(obj.reactions);
    writer.writeString(obj.type);
    writer.writeString(obj.filePath ?? '');
    writer.writeString(obj.fileName ?? '');
    writer.writeBool(obj.isRead);
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

  static Future<String> getMyDeviceId() async {
    String? id = await _storage.read(key: _myDeviceIdKey);
    if (id == null) {
      id = const Uuid().v4();
      await _storage.write(key: _myDeviceIdKey, value: id);
    }
    return id;
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

  static Future<String> decryptMessage(
    String encryptedMessage,
    String encryptedAESKey,
    String encryptedIV,
  ) async {
    final privateKey = await getMyPrivateKey();
    if (privateKey == null) throw Exception('No private key');
    return await Encryptify.decryptMessage(
      currentUserID: await getMyDeviceId(),
      senderID: 'sender',
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
  await Hive.openBox<Contact>('contacts');
  await Hive.openBox<ChatMessage>('messages');
  runApp(const WifiDirectApp());
}

class WifiDirectApp extends StatelessWidget {
  const WifiDirectApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wi-Fi Direct Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
//  HOME SCREEN — Unified Host/Client with flutter_p2p_connection v3
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

  // ── State ─────────────────────────────────────────────────────────────────
  P2pRole _role = P2pRole.none;
  bool _isConnected = false;
  String _status = 'Initializing...';
  String _myDeviceId = '';

  List<Contact> _contacts = [];
  List<ChatMessage> _messages = [];
  List<BleDiscoveredDevice> _discoveredHosts = [];
  List<P2pClientInfo> _groupClients = []; // host only: who joined
  Contact? _selectedContact;

  // Voice
  final FlutterSoundRecorder _audioRecorder = FlutterSoundRecorder();
  bool _isRecordingVoiceMessage = false;

  // Call state (placeholder)
  bool _isInCall = false;

  // Subscriptions
  StreamSubscription? _hostStateSub;
  StreamSubscription? _clientStateSub;
  StreamSubscription? _hostClientsSub;
  StreamSubscription? _hostTextSub;
  StreamSubscription? _clientTextSub;
  StreamSubscription? _clientListSub;
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
    // 1. Permissions
    await _requestPermissions();

    // 2. Hive
    _contactBox = Hive.box<Contact>('contacts');
    _messageBox = Hive.box<ChatMessage>('messages');
    _loadContacts();
    _loadMessages();

    // 3. Device ID & Keys
    _myDeviceId = await EncryptionService.getMyDeviceId();
    await EncryptionService.ensureKeys();

    // 4. Audio
    await _audioRecorder.openRecorder();

    // 5. Initialize both P2P instances (lightweight, no group created yet)
    await _host.initialize();
    await _client.initialize();

    setState(() => _status = 'Device ID: $_myDeviceId — Choose Host or Client');
  }

  Future<void> _requestPermissions() async {
    await Permission.microphone.request();
    await Permission.location.request();
    await Permission.nearbyWifiDevices.request();
    await Permission.storage.request();
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
    await Permission.bluetoothAdvertise.request();
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  HOST ROLE
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _startAsHost() async {
    setState(() => _status = 'Starting as Host...');

    // Ensure services are on
    if (!await _host.checkWifiEnabled()) await _host.enableWifiServices();
    if (!await _host.checkLocationEnabled()) await _host.enableLocationServices();
    if (!await _host.checkBluetoothEnabled()) await _host.enableBluetoothServices();

    // Request runtime permissions via plugin helpers
    if (!await _host.checkP2pPermissions()) await _host.askP2pPermissions();
    if (!await _host.checkBluetoothPermissions()) await _host.askBluetoothPermissions();

    // Create Wi-Fi Direct group + advertise via BLE so clients can find us
    final state = await _host.createGroup(advertise: true);
    debugPrint('HOST createGroup state: $state');

    _role = P2pRole.host;
    _listenAsHost();
    setState(() => _status = 'Host active — SSID: ${state.ssid ?? '...'}');
  }

  void _listenAsHost() {
    // Track hotspot state (active / failed)
    _hostStateSub = _host.streamHotspotState().listen((state) {
      debugPrint('HOST STATE: active=${state.isActive}, reason=${state.failureReason}');
      setState(() {
        _isConnected = state.isActive;
        if (!state.isActive && state.failureReason != null) {
          _status = 'Host failed: ${state.failureReason}';
        }
      });
    });

    // Track who joins the group
    _hostClientsSub = _host.streamClientList().listen((clients) {
      debugPrint('HOST CLIENTS: ${clients.length} connected');
      setState(() => _groupClients = clients);
      for (final c in clients) {
        _ensureContactFromClientInfo(c);
      }
    });

    // Receive text messages from clients
    _hostTextSub = _host.streamReceivedTexts().listen((text) {
      debugPrint('HOST RECEIVED: $text');
      _handleIncomingMessage(text, fromHost: false);
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  CLIENT ROLE
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _startAsClient() async {
    setState(() => _status = 'Starting as Client...');

    if (!await _client.checkWifiEnabled()) await _client.enableWifiServices();
    if (!await _client.checkLocationEnabled()) await _client.enableLocationServices();
    if (!await _client.checkBluetoothEnabled()) await _client.enableBluetoothServices();

    if (!await _client.checkP2pPermissions()) await _client.askP2pPermissions();
    if (!await _client.checkBluetoothPermissions()) await _client.askBluetoothPermissions();

    _role = P2pRole.client;
    _listenAsClient();

    // Start BLE scan for hosts
    _scanSub = await _client.startScan((devices) {
      debugPrint('CLIENT SCAN: ${devices.length} hosts found');
      setState(() => _discoveredHosts = devices);
    });

    setState(() => _status = 'Client scanning for hosts...');
  }

  void _listenAsClient() {
    // Track connection to host
    _clientStateSub = _client.streamHotspotState().listen((state) {
      debugPrint('CLIENT STATE: active=${state.isActive}, ssid=${state.hostSsid}');
      setState(() {
        _isConnected = state.isActive;
        _status = state.isActive
            ? 'Connected to ${state.hostSsid ?? 'host'}'
            : 'Disconnected / Scanning...';
      });
    });

    // Receive text messages from host / other clients
    _clientTextSub = _client.streamReceivedTexts().listen((text) {
      debugPrint('CLIENT RECEIVED: $text');
      _handleIncomingMessage(text, fromHost: true);
    });

    // Track group participants (optional, for UI)
    _clientListSub = _client.streamClientList().listen((clients) {
      debugPrint('CLIENT PEERS: ${clients.length} in group');
      for (final c in clients) {
        if (!c.isHost) _ensureContactFromClientInfo(c);
      }
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  CONNECTION (Client → Host)
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _connectToHost(BleDiscoveredDevice device) async {
    setState(() => _status = 'Connecting to ${device.name}...');
    try {
      await _client.connectWithDevice(device);
      // Create contact for this host
      final contact = Contact(
        uniqueId: device.macAddress ?? const Uuid().v4(),
        displayName: device.name ?? 'Host',
        deviceAddress: device.macAddress,
        lastSeen: DateTime.now(),
      );
      await _contactBox.put(contact.uniqueId, contact);
      _loadContacts();
      setState(() => _selectedContact = contact);
    } catch (e) {
      setState(() => _status = 'Connection failed: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  MESSAGING
  // ═══════════════════════════════════════════════════════════════════════════

  void _handleIncomingMessage(String text, {required bool fromHost}) {
    // Determine sender id
    final senderId = fromHost ? 'host' : 'client';
    final msg = ChatMessage(
      id: const Uuid().v4(),
      contactId: senderId,
      text: text,
      isMine: false,
      timestamp: DateTime.now(),
    );
    setState(() => _messages.add(msg));
    _messageBox.add(msg);
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    // Add to local UI immediately
    final msg = ChatMessage(
      id: const Uuid().v4(),
      contactId: _selectedContact?.uniqueId ?? 'broadcast',
      text: text,
      isMine: true,
      timestamp: DateTime.now(),
    );
    setState(() {
      _messages.add(msg);
      _textController.clear();
    });
    _messageBox.add(msg);

    // Broadcast over P2P
    try {
      if (_role == P2pRole.host) {
        await _host.broadcastText(text);
      } else if (_role == P2pRole.client) {
        await _client.broadcastText(text);
      }
    } catch (e) {
      debugPrint('SEND ERROR: $e');
      setState(() => _status = 'Send failed: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  VOICE
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _startRecordingVoiceMessage() async {
    if (_selectedContact == null) return;
    final tempDir = await getTemporaryDirectory();
    final path = '${tempDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.aac';
    await _audioRecorder.startRecorder(toFile: path, codec: Codec.aacADTS);
    setState(() => _isRecordingVoiceMessage = true);
  }

  Future<void> _stopRecordingAndSendVoiceMessage() async {
    if (!_isRecordingVoiceMessage) return;
    final path = await _audioRecorder.stopRecorder();
    setState(() => _isRecordingVoiceMessage = false);
    if (path != null) {
      // For now, send a text placeholder; file transfer can be added later
      final msg = ChatMessage(
        id: const Uuid().v4(),
        contactId: _selectedContact!.uniqueId,
        text: '🎤 Voice message',
        isMine: true,
        timestamp: DateTime.now(),
        type: 'voice',
        filePath: path,
      );
      setState(() => _messages.add(msg));
      _messageBox.add(msg);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  HELPERS
  // ═══════════════════════════════════════════════════════════════════════════

  void _ensureContactFromClientInfo(P2pClientInfo info) {
    final id = info.id;
    if (!_contactBox.containsKey(id)) {
      final contact = Contact(
        uniqueId: id,
        displayName: info.username ?? 'Peer $id',
        deviceAddress: id,
        lastSeen: DateTime.now(),
      );
      _contactBox.put(id, contact);
      _loadContacts();
    }
  }

  void _loadContacts() {
    setState(() => _contacts = _contactBox.values.toList());
  }

  void _loadMessages() {
    setState(() => _messages = _messageBox.values.toList());
  }

  void _toggleCall() {
    setState(() {
      _isInCall = !_isInCall;
      _status = _isInCall
          ? 'In call with ${_selectedContact?.displayName}'
          : 'Call ended';
    });
  }

  Future<void> _disconnect() async {
    if (_role == P2pRole.host) {
      await _host.removeGroup();
    } else if (_role == P2pRole.client) {
      await _client.disconnect();
    }
    setState(() {
      _isConnected = false;
      _role = P2pRole.none;
      _discoveredHosts.clear();
      _groupClients.clear();
      _selectedContact = null;
      _status = 'Disconnected';
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  UI BUILDERS
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildMessageBubble(ChatMessage msg) {
    return Align(
      alignment: msg.isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: msg.isMine ? Colors.deepPurple.shade700 : Colors.grey.shade800,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(msg.text, style: const TextStyle(fontSize: 15)),
            const SizedBox(height: 4),
            Text(
              '${msg.timestamp.hour.toString().padLeft(2, '0')}:${msg.timestamp.minute.toString().padLeft(2, '0')}',
              style: const TextStyle(fontSize: 10, color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRoleSelection() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.wifi_tethering, size: 80, color: Colors.deepPurple),
          const SizedBox(height: 24),
          const Text(
            'Wi-Fi Direct Chat',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'Device ID: $_myDeviceId',
            style: const TextStyle(fontSize: 12, color: Colors.white54),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 48),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _roleCard(
                icon: Icons.cloud_upload,
                label: 'HOST',
                color: Colors.blue,
                onTap: _startAsHost,
              ),
              const SizedBox(width: 24),
              _roleCard(
                icon: Icons.cloud_download,
                label: 'CLIENT',
                color: Colors.red,
                onTap: _startAsClient,
              ),
            ],
          ),
        ],
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
      child: Container(
        width: 140,
        height: 160,
        decoration: BoxDecoration(
          color: color.withOpacity(0.2),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withOpacity(0.5), width: 2),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 48, color: color),
            const SizedBox(height: 12),
            Text(label, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color)),
          ],
        ),
      ),
    );
  }

  Widget _buildHostClientList() {
    if (_groupClients.isEmpty) {
      return const Center(child: Text('Waiting for clients to join...'));
    }
    return ListView.builder(
      itemCount: _groupClients.length,
      itemBuilder: (_, i) {
        final c = _groupClients[i];
        return ListTile(
          leading: const Icon(Icons.phone_android),
          title: Text(c.username ?? 'Client ${c.id}'),
          subtitle: Text(c.id),
          trailing: ElevatedButton(
            onPressed: () {
              setState(() {
                _selectedContact = _contactBox.get(c.id) ??
                    Contact(
                      uniqueId: c.id,
                      displayName: c.username ?? 'Client',
                      deviceAddress: c.id,
                      lastSeen: DateTime.now(),
                    );
              });
            },
            child: const Text('Chat'),
          ),
        );
      },
    );
  }

  Widget _buildClientHostList() {
    if (_discoveredHosts.isEmpty) {
      return const Center(child: Text('Scanning for hosts via BLE...'));
    }
    return ListView.builder(
      itemCount: _discoveredHosts.length,
      itemBuilder: (_, i) {
        final h = _discoveredHosts[i];
        return ListTile(
          leading: const Icon(Icons.router),
          title: Text(h.name ?? 'Unknown Host'),
          subtitle: Text(h.macAddress ?? ''),
          trailing: ElevatedButton(
            onPressed: () => _connectToHost(h),
            child: const Text('Connect'),
          ),
        );
      },
    );
  }

  Widget _buildChatArea() {
    final filtered = _messages
        .where((m) => m.contactId == (_selectedContact?.uniqueId ?? 'broadcast'))
        .toList();

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            reverse: true,
            padding: const EdgeInsets.all(12),
            itemCount: filtered.length,
            itemBuilder: (_, i) => _buildMessageBubble(filtered[filtered.length - 1 - i]),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: Colors.black54,
          child: Row(
            children: [
              GestureDetector(
                onLongPressStart: (_) => _startRecordingVoiceMessage(),
                onLongPressEnd: (_) => _stopRecordingAndSendVoiceMessage(),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _isRecordingVoiceMessage ? Colors.red : Colors.grey,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _isRecordingVoiceMessage ? Icons.mic : Icons.mic_none,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _textController,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    hintText: 'Type a message...',
                    hintStyle: TextStyle(color: Colors.white54),
                    border: InputBorder.none,
                  ),
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.send),
                onPressed: _sendMessage,
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_selectedContact?.displayName ?? 'Wi-Fi Direct'),
        actions: [
          if (_isConnected)
            IconButton(
              icon: Icon(_isInCall ? Icons.call_end : Icons.call),
              onPressed: _toggleCall,
            ),
          if (_role != P2pRole.none)
            IconButton(
              icon: const Icon(Icons.logout),
              onPressed: _disconnect,
            ),
        ],
      ),
      body: Column(
        children: [
          // ── Status Bar ─────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: Colors.black26,
            child: Row(
              children: [
                Icon(
                  Icons.wifi,
                  color: _isConnected ? Colors.green : Colors.red,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _status,
                    style: const TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_isInCall)
                  const Text('📞', style: TextStyle(fontSize: 20)),
              ],
            ),
          ),

          // ── Main Content ────────────────────────────────────────────────────
          Expanded(
            child: _role == P2pRole.none
                ? _buildRoleSelection()
                : _isConnected && _selectedContact != null
                    ? _buildChatArea()
                    : _role == P2pRole.host
                        ? _buildHostClientList()
                        : _buildClientHostList(),
          ),
        ],
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
    _clientListSub?.cancel();
    _scanSub?.cancel();
    _host.dispose();
    _client.dispose();
    _audioRecorder.closeRecorder();
    _textController.dispose();
    super.dispose();
  }
}
