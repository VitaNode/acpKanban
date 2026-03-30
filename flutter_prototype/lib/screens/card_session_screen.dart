import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/project_service.dart';
import '../models/kanban_card.dart';
import '../models/card_message.dart';

class CardSessionScreen extends StatefulWidget {
  final KanbanCard card;

  const CardSessionScreen({super.key, required this.card});

  @override
  State<CardSessionScreen> createState() => _CardSessionScreenState();
}

class _CardSessionScreenState extends State<CardSessionScreen> {
  final _projectService = ProjectService();
  final _textController = TextEditingController();
  List<CardMessage> _messages = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadSession();
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _loadSession() async {
    setState(() => _isLoading = true);
    try {
      final response = await _projectService.getSessionHistory(widget.card.id);
      if (response != null && mounted) {
        final List<dynamic> msgData = response['messages'] ?? [];
        setState(() => _messages = msgData.map((m) => CardMessage.fromJson(m)).toList());
      }
    } catch (e) {
      debugPrint('Load session error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _messages.add(CardMessage(
        id: 'temp_${DateTime.now().millisecondsSinceEpoch}',
        cardId: widget.card.id,
        role: 'user',
        content: text,
        createdAt: DateTime.now().toIso8601String(),
      ));
      _textController.clear();
      _isLoading = true;
    });

    try {
      await _projectService.addSessionMessage(widget.card.id, 'user', text);
      await _loadSession();
    } catch (e) {
      debugPrint('Send message error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.card.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadSession,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _isLoading && _messages.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _messages.isEmpty
                    ? const Center(
                        child: Text(
                          'No conversation yet.\nStart chatting with the AI!',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final item = _messages[index];
                          final isUser = item.isUser;
                          return Align(
                            alignment: isUser
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Container(
                              constraints: BoxConstraints(
                                maxWidth:
                                    MediaQuery.of(context).size.width * 0.75,
                              ),
                              padding: const EdgeInsets.all(14),
                              margin: const EdgeInsets.symmetric(vertical: 6),
                              decoration: BoxDecoration(
                                color: isUser ? Colors.indigo : Colors.white,
                                border: isUser
                                    ? null
                                    : Border.all(color: Colors.grey[300]!),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        isUser ? Icons.person : Icons.smart_toy,
                                        size: 14,
                                        color: isUser
                                            ? Colors.white70
                                            : Colors.grey,
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        isUser ? 'You' : 'AI',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: isUser
                                              ? Colors.white70
                                              : Colors.grey,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    item.content,
                                    style: TextStyle(
                                      color: isUser
                                          ? Colors.white
                                          : Colors.black87,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
          if (_isLoading) const LinearProgressIndicator(),
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _textController,
                decoration: InputDecoration(
                  hintText: 'Chat about this task...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: Colors.grey[100],
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                ),
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
            const SizedBox(width: 8),
            FloatingActionButton.small(
              onPressed: _isLoading ? null : _sendMessage,
              child: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
