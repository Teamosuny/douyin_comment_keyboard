import 'dart:io';
import 'package:flutter/material.dart';
import 'keyboard/comment_keyboard.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        fontFamily: '.SF Pro Text',
      ),
      home: const CommentInputPage(),
    );
  }
}

/// 评论消息模型
class CommentMessage {
  final String text;
  final List<String> imagePaths;
  final DateTime timestamp;

  CommentMessage({
    required this.text,
    required this.imagePaths,
    required this.timestamp,
  });
}

/// 评论输入页：使用封装的 CommentKeyboard，上方为消息列表
class CommentInputPage extends StatefulWidget {
  const CommentInputPage({super.key});

  @override
  State<CommentInputPage> createState() => _CommentInputPageState();
}

class _CommentInputPageState extends State<CommentInputPage> {
  final ScrollController _scrollController = ScrollController();
  final List<CommentMessage> _messages = [];

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CommentKeyboard(
      hintText: '分享你此刻的想法',
      sendButtonText: '发送',
      onSend: _onSend,
      child: Container(
        color: Colors.white,
        child: _messages.isEmpty
            ? Center(
                child: Text(
                  '评论内容区域',
                  style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                ),
              )
            : ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  return _buildMessageItem(_messages[index]);
                },
              ),
      ),
    );
  }

  void _onSend(String text, List<String> imagePaths) {
    setState(() {
      _messages.add(
        CommentMessage(
          text: text,
          imagePaths: imagePaths,
          timestamp: DateTime.now(),
        ),
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Widget _buildMessageItem(CommentMessage message) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message.text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                message.text,
                style: const TextStyle(
                  fontSize: 15,
                  color: Color(0xFF333333),
                  height: 1.4,
                ),
              ),
            ),
          if (message.imagePaths.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: message.imagePaths.map((path) {
                return ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(
                    File(path),
                    width: 100,
                    height: 100,
                    fit: BoxFit.cover,
                  ),
                );
              }).toList(),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _formatTime(message.timestamp),
              style: const TextStyle(fontSize: 12, color: Color(0xFF999999)),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final difference = now.difference(time);

    if (difference.inMinutes < 1) {
      return '刚刚';
    } else if (difference.inHours < 1) {
      return '${difference.inMinutes}分钟前';
    } else if (difference.inDays < 1) {
      return '${difference.inHours}小时前';
    } else {
      return '${time.month}月${time.day}日 ${time.hour}:${time.minute.toString().padLeft(2, '0')}';
    }
  }
}
