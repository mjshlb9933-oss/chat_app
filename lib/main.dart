import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

void main() => runApp(const ChatApp());

class ChatApp extends StatefulWidget {
  const ChatApp({super.key});
  @override
  State<ChatApp> createState() => _ChatAppState();
}

class _ChatAppState extends State<ChatApp> {
  ThemeMode _themeMode = ThemeMode.light;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final isDark = prefs.getBool('darkMode') ?? false;
    if (mounted) {
      setState(() => _themeMode = isDark ? ThemeMode.dark : ThemeMode.light);
    }
  }

  Future<void> toggleTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final newMode = _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    await prefs.setBool('darkMode', newMode == ThemeMode.dark);
    if (mounted) setState(() => _themeMode = newMode);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'الدردشة',
      theme: ThemeData(
        primarySwatch: Colors.teal,
        brightness: Brightness.light,
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.teal.shade700,
          foregroundColor: Colors.white,
        ),
      ),
      darkTheme: ThemeData(
        primarySwatch: Colors.teal,
        brightness: Brightness.dark,
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.teal.shade900,
          foregroundColor: Colors.white,
        ),
      ),
      themeMode: _themeMode,
      home: ChatScreen(
        isDark: _themeMode == ThemeMode.dark,
        onToggleTheme: toggleTheme,
      ),
      debugShowCheckedModeBanner: false,
    );
  }
}

class ChatScreen extends StatefulWidget {
  final bool isDark;
  final VoidCallback onToggleTheme;
  const ChatScreen({super.key, required this.isDark, required this.onToggleTheme});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _msgCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final ImagePicker _picker = ImagePicker();

  List<dynamic> _messages = [];
  Timer? _timer;
  bool _loading = true;
  bool _sending = false;
  bool _uploading = false;
  String _myName = '';
  int _lastId = 0;

  final String _baseUrl = 'http://192.168.0.102:8080/chat';

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _initApp() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString('userName') ?? '';
    if (name.isEmpty) {
      _showNameDialog();
    } else {
      _myName = name;
      _loadMessages();
      _startPolling();
    }
  }

  Future<void> _showNameDialog() async {
    final ctrl = TextEditingController();
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('👤 اسمك'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('أدخل اسمك للبدء في الدردشة'),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              textAlign: TextAlign.center,
              decoration: const InputDecoration(
                hintText: 'اسمك',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () async {
              final name = ctrl.text.trim();
              if (name.isEmpty) return;
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('userName', name);
              if (!mounted) return;
              setState(() => _myName = name);
              Navigator.pop(ctx);
              _loadMessages();
              _startPolling();
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }

  void _startPolling() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      _loadMessages(silent: true);
    });
  }

  Future<void> _loadMessages({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final url = Uri.parse('$_baseUrl/get.php?since=$_lastId');
      final response = await http.get(url).timeout(const Duration(seconds: 10));
      final data = jsonDecode(utf8.decode(response.bodyBytes));

      if (data['success'] == true) {
        final newMessages = data['messages'] as List<dynamic>;
        if (newMessages.isNotEmpty) {
          setState(() {
            if (_lastId == 0) {
              _messages = newMessages;
            } else {
              _messages.addAll(newMessages);
            }
            if (newMessages.isNotEmpty) {
              _lastId = newMessages.last['id'] ?? _lastId;
            }
            _loading = false;
          });
          _scrollToBottom();
        } else {
          if (mounted) setState(() => _loading = false);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 200), () {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty || _sending) return;

    setState(() => _sending = true);

    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/send.php'),
        body: {
          'sender': _myName,
          'message': text,
        },
      ).timeout(const Duration(seconds: 10));

      final data = jsonDecode(utf8.decode(response.bodyBytes));
      if (data['success'] == true) {
        _msgCtrl.clear();
        await _loadMessages(silent: true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('خطأ: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickAndSendImage(ImageSource source) async {
    try {
      final XFile? image = await _picker.pickImage(
        source: source,
        maxWidth: 1200,
        imageQuality: 80,
      );

      if (image == null) return;

      setState(() => _uploading = true);

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_baseUrl/upload.php'),
      );
      request.files.add(
        await http.MultipartFile.fromPath('image', image.path),
      );

      final streamedResponse = await request.send().timeout(
            const Duration(seconds: 30),
          );
      final response = await http.Response.fromStream(streamedResponse);
      final data = jsonDecode(utf8.decode(response.bodyBytes));

      if (data['success'] == true) {
        final imagePath = data['image_path'];

        await http.post(
          Uri.parse('$_baseUrl/send.php'),
          body: {
            'sender': _myName,
            'message': '',
            'image_path': imagePath,
          },
        );

        await _loadMessages(silent: true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('خطأ في الرفع: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _showImageSourceDialog() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library, color: Colors.teal),
              title: const Text('من المعرض'),
              onTap: () {
                Navigator.pop(ctx);
                _pickAndSendImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt, color: Colors.teal),
              title: const Text('من الكاميرا'),
              onTap: () {
                Navigator.pop(ctx);
                _pickAndSendImage(ImageSource.camera);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              const CircleAvatar(
                backgroundColor: Colors.white,
                child: Icon(Icons.person, color: Colors.teal),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('الدردشة العامة',
                      style: TextStyle(fontSize: 18)),
                  Text('أنت: $_myName',
                      style: const TextStyle(fontSize: 12)),
                ],
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: Icon(isDark ? Icons.light_mode : Icons.dark_mode),
              onPressed: widget.onToggleTheme,
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () {
                _lastId = 0;
                _messages = [];
                _loadMessages();
              },
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _messages.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.chat_bubble_outline,
                                  size: 80, color: Colors.grey.shade400),
                              const SizedBox(height: 16),
                              Text('لا توجد رسائل بعد',
                                  style: TextStyle(
                                      fontSize: 18,
                                      color: Colors.grey.shade600)),
                              const SizedBox(height: 8),
                              Text('ابدأ بإرسال رسالة',
                                  style: TextStyle(
                                      fontSize: 14,
                                      color: Colors.grey.shade500)),
                            ],
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollCtrl,
                          padding: const EdgeInsets.all(12),
                          itemCount: _messages.length,
                          itemBuilder: (context, index) {
                            final msg = _messages[index];
                            final isMe = msg['sender'] == _myName;
                            return _buildMessageBubble(msg, isMe, isDark);
                          },
                        ),
            ),

            // شريط الإدخال
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E1E1E) : Colors.grey.shade100,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 5,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  // زر الصورة
                  IconButton(
                    onPressed: _uploading ? null : _showImageSourceDialog,
                    icon: _uploading
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.image, color: Colors.teal, size: 28),
                  ),

                  // حقل الكتابة
                  Expanded(
                    child: TextField(
                      controller: _msgCtrl,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                      decoration: InputDecoration(
                        hintText: 'اكتب رسالة...',
                        filled: true,
                        fillColor: isDark ? Colors.black26 : Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(25),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),

                  // زر الإرسال
                  const SizedBox(width: 8),
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: Colors.teal,
                    child: IconButton(
                      onPressed: _sending ? null : _sendMessage,
                      icon: _sending
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  color: Colors.white, strokeWidth: 2),
                            )
                          : const Icon(Icons.send, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(dynamic msg, bool isMe, bool isDark) {
    final message = msg['message'] as String? ?? '';
    final imagePath = msg['image_path'] as String?;
    final sender = msg['sender'] as String? ?? '';
    final time = _formatTime(msg['created_at'] as String? ?? '');

    final bubbleColor = isMe
        ? Colors.teal
        : (isDark ? Colors.grey.shade800 : Colors.white);
    final textColor = isMe ? Colors.white : null;

    return Align(
      alignment: isMe ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.start : CrossAxisAlignment.end,
          children: [
            // اسم المرسل (لغيري)
            if (!isMe)
              Padding(
                padding: const EdgeInsets.only(right: 12, bottom: 4),
                child: Text(
                  sender,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.teal.shade700,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),

            // الفقاعة
            Container(
              decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: BorderRadius.circular(15),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 3,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // الصورة
                  if (imagePath != null && imagePath.isNotEmpty)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(15),
                      child: Image.network(
                        '$_baseUrl/$imagePath',
                        width: 250,
                        fit: BoxFit.cover,
                        loadingBuilder: (context, child, progress) {
                          if (progress == null) return child;
                          return Container(
                            width: 250,
                            height: 200,
                            color: Colors.grey.shade300,
                            child: const Center(
                              child: CircularProgressIndicator(),
                            ),
                          );
                        },
                        errorBuilder: (context, error, stack) {
                          return Container(
                            width: 250,
                            height: 100,
                            color: Colors.grey.shade300,
                            child: const Center(
                              child: Icon(Icons.broken_image, size: 50),
                            ),
                          );
                        },
                      ),
                    ),

                  // النص
                  if (message.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      child: Text(
                        message,
                        style: TextStyle(
                          fontSize: 16,
                          color: textColor,
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // الوقت
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 8, left: 8),
              child: Text(
                time,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(String dateTime) {
    try {
      final dt = DateTime.parse(dateTime.replaceFirst(' ', 'T'));
      final now = DateTime.now();
      final diff = now.difference(dt);

      if (diff.inMinutes < 1) return 'الآن';
      if (diff.inHours < 1) return 'قبل ${diff.inMinutes} د';
      if (diff.inDays < 1) {
        return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      }
      return '${dt.day}/${dt.month}';
    } catch (e) {
      return '';
    }
  }
}
