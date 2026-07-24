import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:wifi_direct_plugin/wifi_direct_plugin.dart';
import 'package:cupertino_liquid_glass/cupertino_liquid_glass.dart';
import 'package:nex_chat_reaction/nex_chat_reaction.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:encryptify/encryptify.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

// --- 新增语音相关导入 ---
import 'package:flutter_local_walkie_talkie/flutter_local_walkie_talkie.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'dart:typed_data';

// ... (之前的 Contact, ChatMessage, EncryptionService 等类保持不变) ...

// ============ 主应用与首页 ============
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

// ============ 首页状态管理 ============
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // --- 核心插件 ---
  final WifiDirectPlugin _wifiDirect = WifiDirectPlugin();
  final WalkieTalkie _walkieTalkie = WalkieTalkie(); // 实时语音引擎[reference:7]
  final FlutterSoundPlayer _audioPlayer = FlutterSoundPlayer(); // 语音消息播放
  final FlutterSoundRecorder _audioRecorder = FlutterSoundRecorder(); // 语音消息录制

  // --- 状态变量 ---
  final ReactionsController _reactionsController = ReactionsController(currentUserId: 'me');
  final TextEditingController _textController = TextEditingController();
  late Box<Contact> _contactBox;
  late Box<ChatMessage> _messageBox;
  
  List<Contact> _contacts = [];
  List<ChatMessage> _messages = [];
  List<WifiDirectDevice> _discoveredDevices = [];
  Contact? _selectedContact;
  bool _isConnected = false;
  String _status = 'Initializing...';
  String _myDeviceId = '';

  // --- 语音通话状态 ---
  bool _isInCall = false;
  bool _isEmergencyCall = false;
  bool _isTalking = false; // 用于实时通话的PTT
  bool _isRecordingVoiceMessage = false; // 用于语音消息

  // ============ 初始化 ============
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    // 请求权限
    await [
      Permission.microphone,
      Permission.location,
      Permission.nearbyWifiDevices,
      Permission.storage,
    ].request();

    // 初始化数据库
    _contactBox = Hive.box<Contact>('contacts');
    _messageBox = Hive.box<ChatMessage>('messages');
    _loadContacts();
    _loadMessages();

    // 生成设备ID和密钥
    _myDeviceId = await EncryptionService.getMyDeviceId();
    await EncryptionService.ensureKeys();
    setState(() => _status = 'Device ID: $_myDeviceId');

    // --- 初始化实时语音引擎 ---
    final deviceInfo = await DeviceInfoPlugin().androidInfo;
    await _walkieTalkie.init(deviceName: deviceInfo.model); // [reference:8]
    _walkieTalkie.startSearching(); // [reference:9]
    _walkieTalkie.discoveredDevices.listen((devices) {
      // 实时语音引擎发现的设备，可用来直接连接
    });

    // --- 初始化语音消息录制器 ---
    await _audioRecorder.openRecorder();
    await _audioPlayer.openPlayer();

    // --- 初始化Wi-Fi Direct ---
    await _wifiDirect.initialize();
    _wifiDirect.messageStream.listen((rawMessage) async {
      await _handleIncomingMessage(rawMessage);
    });
    _wifiDirect.fileReceiveStream.listen((fileData) async {
      // ... (处理文件接收，同之前) ...
    });
    _wifiDirect.connectionStream.listen((status) {
      setState(() {
        _isConnected = status == ConnectionStatus.connected;
        _status = _isConnected ? 'Connected to ${_selectedContact?.displayName ?? 'peer'}' : 'Disconnected';
      });
    });
    _wifiDirect.deviceStream.listen((devices) {
      setState(() => _discoveredDevices = devices);
    });
    _wifiDirect.startDiscovery();
  }

  // ============ 语音通话核心逻辑 ============
  // 发起实时通话（普通或紧急）
  Future<void> _startCall({required bool isEmergency}) async {
    if (_selectedContact == null) return;
    // 1. 通过Wi-Fi Direct发送通话请求信令
    final callType = isEmergency ? 'EMERGENCY_CALL' : 'CALL_REQUEST';
    _wifiDirect.sendMessage('$callType:${_myDeviceId}');
    
    // 2. 如果是紧急呼叫，或对方同意后，连接实时语音
    if (isEmergency) {
      _establishVoiceCall(isEmergency: true);
    } else {
      setState(() => _status = 'Waiting for ${_selectedContact!.displayName} to accept...');
      // 等待对方回复 'CALL_ACCEPT' 信令，在 _handleIncomingMessage 中处理
    }
  }

  // 建立实时语音连接
  void _establishVoiceCall({required bool isEmergency}) {
    // 获取对方IP (需要从Wi-Fi Direct连接信息中获取，此处简化)
    // 实际应从 WifiP2pInfo.groupOwnerAddress 获取
    final peerIp = _selectedContact?.deviceAddress ?? '192.168.49.1'; 
    final peer = WalkieTalkieDevice(
      id: _selectedContact!.uniqueId,
      name: _selectedContact!.displayName,
      ip: peerIp,
      port: 4545, // 默认端口[reference:10]
    );
    _walkieTalkie.connectToDevice(peer); // [reference:11]
    
    setState(() {
      _isInCall = true;
      _isEmergencyCall = isEmergency;
      _status = 'In ${isEmergency ? "Emergency " : ""}Call with ${_selectedContact!.displayName}';
    });
  }

  // 挂断通话
  void _endCall() {
    _walkieTalkie.stopTalking(); // [reference:12]
    // 发送挂断信令
    _wifiDirect.sendMessage('CALL_END:${_myDeviceId}');
    setState(() {
      _isInCall = false;
      _isEmergencyCall = false;
      _isTalking = false;
      _status = 'Call ended';
    });
  }

  // 实时通话的 Push-to-Talk
  void _startTalking() async {
    if (!_isInCall) return;
    setState(() => _isTalking = true);
    await _walkieTalkie.startTalking(); // [reference:13]
  }

  void _stopTalking() async {
    if (!_isInCall) return;
    setState(() => _isTalking = false);
    await _walkieTalkie.stopTalking(); // [reference:14]
  }

  // ============ 语音消息核心逻辑 ============
  // 开始录制语音消息
  void _startRecordingVoiceMessage() async {
    if (_selectedContact == null) return;
    try {
      final tempDir = await getTemporaryDirectory();
      final path = '${tempDir.path}/voice_message_${DateTime.now().millisecondsSinceEpoch}.aac';
      await _audioRecorder.startRecorder(
        toFile: path,
        codec: Codec.aacADTS, // 使用AAC编码以减小文件大小
      );
      setState(() => _isRecordingVoiceMessage = true);
    } catch (e) {
      print('录音启动失败: $e');
    }
  }

  // 停止录制并发送语音消息
  void _stopRecordingAndSendVoiceMessage() async {
    if (!_isRecordingVoiceMessage) return;
    try {
      final path = await _audioRecorder.stopRecorder();
      if (path != null) {
        final file = File(path);
        final bytes = await file.readAsBytes();
        // 加密音频数据 (使用与文本相同的加密方式)
        final publicKey = _selectedContact!.rsaPublicKey!;
        final encrypted = await EncryptionService.encryptMessage(
          base64Encode(bytes),
          publicKey,
        );
        // 发送带类型标记的语音消息
        _wifiDirect.sendMessage(jsonEncode({
          'type': 'voice_message',
          'data': encrypted,
        }));
        // 保存到本地消息列表
        final msg = ChatMessage(
          id: const Uuid().v4(),
          contactId: _selectedContact!.uniqueId,
          text: '🎤 Voice message sent',
          isMine: true,
          timestamp: DateTime.now(),
          type: 'voice',
        );
        await _messageBox.add(msg);
        _loadMessages();
      }
    } catch (e) {
      print('发送语音消息失败: $e');
    } finally {
      setState(() => _isRecordingVoiceMessage = false);
    }
  }

  // 播放接收到的语音消息
  void _playVoiceMessage(String encryptedDataBase64) async {
    try {
      // 解密
      final decryptedJson = await EncryptionService.decryptMessage(
        encryptedDataBase64, 
        '', // 加密结构需要调整，此处简化
        ''
      );
      // 实际应解析JSON获取音频数据
      final audioBytes = base64Decode(decryptedJson);
      final tempDir = await getTemporaryDirectory();
      final path = '${tempDir.path}/received_voice_${DateTime.now().millisecondsSinceEpoch}.aac';
      await File(path).writeAsBytes(audioBytes);
      await _audioPlayer.startPlayer(fromURI: path);
    } catch (e) {
      print('播放语音消息失败: $e');
    }
  }

  // ============ 处理接收到的消息 (增强) ============
  Future<void> _handleIncomingMessage(String raw) async {
    // --- 处理实时通话信令 ---
    if (raw.startsWith('CALL_REQUEST:')) {
      final callerId = raw.substring(13);
      // 显示来电对话框
      final accept = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Incoming Call'),
          content: Text('${_getContactName(callerId)} is calling...'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Decline')),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Accept')),
          ],
        ),
      ) ?? false;
      if (accept) {
        _wifiDirect.sendMessage('CALL_ACCEPT:${_myDeviceId}');
        // 建立通话
        final callerContact = _contacts.firstWhere((c) => c.uniqueId == callerId);
        setState(() => _selectedContact = callerContact);
        _establishVoiceCall(isEmergency: false);
      } else {
        _wifiDirect.sendMessage('CALL_REJECT:${_myDeviceId}');
      }
      return;
    }
    
    if (raw.startsWith('EMERGENCY_CALL:')) {
      // 紧急呼叫：直接建立通话，无需确认
      final callerId = raw.substring(15);
      final callerContact = _contacts.firstWhere((c) => c.uniqueId == callerId);
      setState(() => _selectedContact = callerContact);
      _establishVoiceCall(isEmergency: true);
      // 可以显示一个紧急呼叫中的提示
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('🚨 Emergency call incoming!'), backgroundColor: Colors.red),
      );
      return;
    }

    if (raw.startsWith('CALL_ACCEPT:')) {
      // 对方接受了通话请求
      _establishVoiceCall(isEmergency: false);
      return;
    }

    if (raw.startsWith('CALL_REJECT:')) {
      setState(() => _status = 'Call declined');
      return;
    }

    if (raw.startsWith('CALL_END:')) {
      _endCall();
      return;
    }

    // --- 处理语音消息 ---
    if (raw.startsWith('VOICE_MSG:')) {
      final encodedData = raw.substring(10);
      _playVoiceMessage(encodedData);
      // 保存到消息列表
      final msg = ChatMessage(
        id: const Uuid().v4(),
        contactId: _selectedContact?.uniqueId ?? 'unknown',
        text: '🎤 Voice message received',
        isMine: false,
        timestamp: DateTime.now(),
        type: 'voice',
      );
      await _messageBox.add(msg);
      _loadMessages();
      return;
    }

    // --- 处理普通加密消息 (文本/文件) ---
    // ... (同之前的实现) ...
  }

  String _getContactName(String id) {
    try {
      return _contacts.firstWhere((c) => c.uniqueId == id).displayName;
    } catch (e) {
      return 'Unknown';
    }
  }

  // ============ UI 构建 ============
  @override
  Widget build(BuildContext context) {
    return CupertinoLiquidGlassTheme(
      data: CupertinoLiquidGlassThemeData(
        blurSigma: 15,
        tintOpacity: 0.3,
        specularGradient: const LinearGradient(
          colors: [Colors.white24, Colors.transparent, Colors.white12],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Scaffold(
        // --- 应用栏 (包含语音功能入口) ---
        appBar: AppBar(
          title: Text(_selectedContact?.displayName ?? 'Wi-Fi Direct'),
          actions: [
            // 语音功能菜单
            PopupMenuButton<String>(
              icon: const Icon(Icons.phone),
              onSelected: (value) {
                if (value == 'call') _startCall(isEmergency: false);
                if (value == 'emergency') _startCall(isEmergency: true);
                if (value == 'end_call') _endCall();
              },
              itemBuilder: (context) => [
                if (!_isInCall) ...[
                  const PopupMenuItem(value: 'call', child: Row(
                    children: [Icon(Icons.call), SizedBox(width: 8), Text('Call')],
                  )),
                  const PopupMenuItem(value: 'emergency', child: Row(
                    children: [Icon(Icons.warning, color: Colors.red), SizedBox(width: 8), Text('Emergency Call')],
                  )),
                ],
                if (_isInCall) ...[
                  const PopupMenuItem(value: 'end_call', child: Row(
                    children: [Icon(Icons.call_end, color: Colors.red), SizedBox(width: 8), Text('End Call')],
                  )),
                ],
              ],
            ),
            IconButton(
              icon: const Icon(Icons.person),
              onPressed: () => _showProfileDialog(),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => _wifiDirect.startDiscovery(),
            ),
          ],
        ),
        body: Column(
          children: [
            // ---- 状态栏 (显示通话状态) ----
            CupertinoLiquidGlass(
              borderRadius: const BorderRadius.only(
                bottomLeft: Radius.circular(24),
                bottomRight: Radius.circular(24),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Row(
                  children: [
                    Icon(
                      _isInCall ? Icons.call : Icons.wifi,
                      color: _isInCall ? Colors.green : (_isConnected ? Colors.green : Colors.red),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(_status)),
                    if (_isInCall) ...[
                      if (_isEmergencyCall)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8.0),
                          child: Text('🚨', style: TextStyle(fontSize: 20)),
                        ),
                      // 实时通话的PTT按钮
                      GestureDetector(
                        onLongPressStart: (_) => _startTalking(),
                        onLongPressEnd: (_) => _stopTalking(),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: _isTalking ? Colors.red : Colors.deepPurple,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(_isTalking ? 'TALKING' : 'HOLD TO TALK'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // ---- 设备列表 / 消息列表 (与之前相同) ----
            if (!_isConnected)
              Expanded(
                child: ListView.builder(
                  itemCount: _discoveredDevices.length,
                  itemBuilder: (_, i) => CupertinoLiquidGlass(
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    borderRadius: BorderRadius.circular(16),
                    child: ListTile(
                      leading: const Icon(Icons.phone_android),
                      title: Text(_discoveredDevices[i].deviceName),
                      subtitle: Text(_discoveredDevices[i].deviceAddress),
                      trailing: ElevatedButton(
                        onPressed: () => _connectToDevice(_discoveredDevices[i]),
                        child: const Text('Connect'),
                      ),
                    ),
                  ),
                ),
              ),

            if (_isConnected && _selectedContact != null)
              Expanded(
                child: ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.all(12),
                  itemCount: _messages.where((m) => m.contactId == _selectedContact!.uniqueId).length,
                  itemBuilder: (_, i) {
                    final filtered = _messages.where((m) => m.contactId == _selectedContact!.uniqueId).toList();
                    final msg = filtered[filtered.length - 1 - i];
                    return _buildMessageBubble(msg);
                  },
                ),
              ),

            // ---- 输入栏 (增加语音消息按钮) ----
            if (_isConnected && _selectedContact != null)
              CupertinoLiquidGlass(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        // 语音消息按钮 (按住录音)
                        GestureDetector(
                          onLongPressStart: (_) => _startRecordingVoiceMessage(),
                          onLongPressEnd: (_) => _stopRecordingAndSendVoiceMessage(),
                          child: CupertinoLiquidGlass(
                            width: 50,
                            height: 50,
                            borderRadius: BorderRadius.circular(25),
                            child: Icon(
                              _isRecordingVoiceMessage ? Icons.mic : Icons.mic_none,
                              color: _isRecordingVoiceMessage ? Colors.red : Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // 文本输入框
                        Expanded(
                          child: CupertinoLiquidGlass(
                            borderRadius: BorderRadius.circular(25),
                            child: TextField(
                              controller: _textController,
                              style: const TextStyle(color: Colors.white),
                              decoration: const InputDecoration(
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(horizontal: 16),
                                hintText: 'Type a message...',
                                hintStyle: TextStyle(color: Colors.white54),
                              ),
                              onSubmitted: (_) => _sendMessage(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // 发送按钮
                        GestureDetector(
                          onTap: _sendMessage,
                          child: CupertinoLiquidGlass(
                            width: 50,
                            height: 50,
                            borderRadius: BorderRadius.circular(25),
                            child: const Icon(Icons.send, color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ... (其他辅助方法: _loadContacts, _loadMessages, _connectToDevice, _sendMessage, _buildMessageBubble, _showProfileDialog 等，与之前相同) ...
}