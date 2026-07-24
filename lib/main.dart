import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:wifi_direct/wifi_direct.dart';          // ✅ new import
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:encryptify/encryptify.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:device_info_plus/device_info_plus.dart';

// ============ MODELS (unchanged) ============
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
  final String type; // text, file, voice
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

// ============ HIVE ADAPTERS (unchanged) ============
@HiveType(typeId: 0)
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

@HiveType(typeId: 1)
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

// ============ ENCRYPTION (fixed record access) ============
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
      // ✅ Record fields, not map keys
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
    // ✅ Record fields
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

// ============ MAIN ============
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
      theme: ThemeData.dark(useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

// ============ HOME SCREEN (using wifi_direct package) ============
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // ✅ WiFiDirect.instance is a singleton; no separate init needed.
  final WiFiDirect _wifiDirect = WiFiDirect.instance;
  final TextEditingController _textController = TextEditingController();

  late Box<Contact> _contactBox;
  late Box<ChatMessage> _messageBox;

  List<Contact> _contacts = [];
  List<ChatMessage> _messages = [];
  // ✅ DiscoveredPeer is the type from the wifi_direct package
  List<DiscoveredPeer> _discoveredDevices = [];
  Contact? _selectedContact;
  bool _isConnected = false;
  String _status = 'Initializing...';
  String _myDeviceId = '';

  // Voice
  final FlutterSoundRecorder _audioRecorder = FlutterSoundRecorder();
  bool _isRecordingVoiceMessage = false;

  // Call state (placeholder)
  bool _isInCall = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await [
      Permission.microphone,
      Permission.location,
      Permission.nearbyWifiDevices,
      Permission.storage,
    ].request();

    _contactBox = Hive.box<Contact>('contacts');
    _messageBox = Hive.box<ChatMessage>('messages');
    _loadContacts();
    _loadMessages();

    _myDeviceId = await EncryptionService.getMyDeviceId();
    await EncryptionService.ensureKeys();
    setState(() => _status = 'Device ID: $_myDeviceId');

    await _audioRecorder.openRecorder();

    // ✅ Wi-Fi Direct initialization is automatic; start peer discovery.
    _wifiDirect.startPeerDiscovery();

    // Listen for discovered peers
    _wifiDirect.onPeersChanged.listen((List<DiscoveredPeer> peers) {
      setState(() {
        _discoveredDevices = peers;
      });
    });

    // Listen for incoming data (messages)
    _wifiDirect.onDataReceived.listen((DataReceivedEvent event) {
      final message = event.data; // depending on the plugin, may be string or bytes
      setState(() {
        _messages.add(ChatMessage(
          id: const Uuid().v4(),
          contactId: _selectedContact?.uniqueId ?? 'unknown',
          text: message is String ? message : 'Binary data',
          isMine: false,
          timestamp: DateTime.now(),
        ));
      });
    });

    // Listen for connection state changes
    _wifiDirect.onConnectionStateChanged.listen((ConnectionState state) {
      final connected = state == ConnectionState.connected;
      setState(() {
        _isConnected = connected;
        _status = connected
            ? 'Connected to ${_selectedContact?.displayName ?? 'peer'}'
            : 'Disconnected';
      });
    });
  }

  void _loadContacts() {
    setState(() {
      _contacts = _contactBox.values.toList();
    });
  }

  void _loadMessages() {
    setState(() {
      _messages = _messageBox.values.toList();
    });
  }

  void _connectToDevice(DiscoveredPeer device) async {
    setState(() => _status = 'Connecting...');
    // Create a contact from the discovered peer
    final contact = Contact(
      uniqueId: const Uuid().v4(),
      displayName: device.name,        // ✅ name property
      deviceAddress: device.address,   // ✅ address property
      lastSeen: DateTime.now(),
    );
    await _contactBox.add(contact);
    _loadContacts();
    _selectedContact = contact;
    await _wifiDirect.connect(device); // ✅ connect method
  }

  void _sendMessage() {
    if (_textController.text.isEmpty || _selectedContact == null) return;
    final text = _textController.text;
    _wifiDirect.sendMessage(text);      // ✅ sendMessage still exists
    setState(() {
      _messages.add(ChatMessage(
        id: const Uuid().v4(),
        contactId: _selectedContact!.uniqueId,
        text: text,
        isMine: true,
        timestamp: DateTime.now(),
      ));
      _textController.clear();
    });
  }

  void _startRecordingVoiceMessage() async {
    if (_selectedContact == null) return;
    final tempDir = await getTemporaryDirectory();
    final path =
        '${tempDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.aac';
    await _audioRecorder.startRecorder(toFile: path, codec: Codec.aacADTS);
    setState(() => _isRecordingVoiceMessage = true);
  }

  void _stopRecordingAndSendVoiceMessage() async {
    if (!_isRecordingVoiceMessage) return;
    final path = await _audioRecorder.stopRecorder();
    if (path != null) {
      _wifiDirect.sendMessage('Voice message sent');
      setState(() {
        _messages.add(ChatMessage(
          id: const Uuid().v4(),
          contactId: _selectedContact!.uniqueId,
          text: '🎤 Voice message sent',
          isMine: true,
          timestamp: DateTime.now(),
          type: 'voice',
        ));
      });
    }
    setState(() => _isRecordingVoiceMessage = false);
  }

  void _toggleCall() {
    setState(() {
      _isInCall = !_isInCall;
      _status = _isInCall
          ? 'In call with ${_selectedContact?.displayName}'
          : 'Call ended';
    });
  }

  Widget _buildMessageBubble(ChatMessage msg) {
    return Align(
      alignment: msg.isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: msg.isMine ? Colors.blue.shade800 : Colors.grey.shade800,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(msg.text),
            const SizedBox(height: 4),
            Text(
              '${msg.timestamp.hour}:${msg.timestamp.minute.toString().padLeft(2, '0')}',
              style: const TextStyle(fontSize: 10, color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_selectedContact?.displayName ?? 'Wi-Fi Direct'),
        actions: [
          IconButton(
            icon: Icon(_isInCall ? Icons.call_end : Icons.call),
            onPressed: _toggleCall,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            // ✅ restart peer discovery
            onPressed: () => _wifiDirect.startPeerDiscovery(),
          ),
        ],
      ),
      body: Column(
        children: [
          // Status bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Colors.black26,
            child: Row(
              children: [
                Icon(Icons.wifi,
                    color: _isConnected ? Colors.green : Colors.red),
                const SizedBox(width: 8),
                Expanded(child: Text(_status)),
                if (_isInCall)
                  const Text('📞', style: TextStyle(fontSize: 20)),
              ],
            ),
          ),
          // Device list (if not connected)
          if (!_isConnected)
            Expanded(
              child: ListView.builder(
                itemCount: _discoveredDevices.length,
                itemBuilder: (_, i) => ListTile(
                  leading: const Icon(Icons.phone_android),
                  title: Text(_discoveredDevices[i].name),
                  subtitle: Text(_discoveredDevices[i].address),
                  trailing: ElevatedButton(
                    onPressed: () => _connectToDevice(_discoveredDevices[i]),
                    child: const Text('Connect'),
                  ),
                ),
              ),
            ),
          // Chat messages
          if (_isConnected && _selectedContact != null)
            Expanded(
              child: ListView.builder(
                reverse: true,
                padding: const EdgeInsets.all(12),
                itemCount: _messages
                    .where((m) => m.contactId == _selectedContact!.uniqueId)
                    .length,
                itemBuilder: (_, i) {
                  final filtered = _messages
                      .where((m) => m.contactId == _selectedContact!.uniqueId)
                      .toList();
                  final msg = filtered[filtered.length - 1 - i];
                  return _buildMessageBubble(msg);
                },
              ),
            ),
          // Input row
          if (_isConnected && _selectedContact != null)
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
                        color:
                            _isRecordingVoiceMessage ? Colors.red : Colors.grey,
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
      ),
    );
  }

  @override
  void dispose() {
    _wifiDirect.stopPeerDiscovery();   // ✅ clean up discovery
    _audioRecorder.closeRecorder();
    super.dispose();
  }
}
