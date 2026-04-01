import 'package:flutter/material.dart';
import '../services/project_service.dart';
import '../services/session_websocket_service.dart';
import '../models/kanban_card.dart';
import '../models/card_message.dart';
import '../widgets/message_bubble.dart';
import '../services/acp_client.dart';
import '../services/smart_connect.dart';

class CardSessionScreen extends StatefulWidget {
  final KanbanCard card;
  final ACPClient? acpClient;

  const CardSessionScreen({super.key, required this.card, this.acpClient});

  @override
  State<CardSessionScreen> createState() => _CardSessionScreenState();
}

class _CardSessionScreenState extends State<CardSessionScreen> {
  final _projectService = ProjectService();
  final _wsService = SessionWebSocketService();
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  List<CardMessage> _messages = [];
  bool _isLoading = false;
  bool _wsConnected = false;

  @override
  void initState() {
    super.initState();
    _initWebSocket();
    _wsService.messages.listen((msgs) {
      if (mounted) {
        setState(() {
          _messages = msgs;
          _isLoading = false;
        });
        _scrollToBottom();
      }
    });
    _wsService.status.listen((status) {
      if (mounted) {
        setState(() => _wsConnected = status == 'connected');
      }
    });
  }

  Future<void> _initWebSocket() async {
    setState(() => _isLoading = true);
    final connected = await _wsService.connect(widget.card.id);
    if (!connected && mounted) {
      await _loadSession();
    }
  }

  @override
  void dispose() {
    _wsService.disconnect();
    _wsService.dispose();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadSession() async {
    setState(() => _isLoading = true);
    try {
      final response = await _projectService.getSessionHistory(widget.card.id);
      if (response != null && mounted) {
        final List<dynamic> msgData = response['messages'] ?? [];
        setState(() =>
            _messages = msgData.map((m) => CardMessage.fromJson(m)).toList());
        _scrollToBottom();
      }
    } catch (e) {
      debugPrint('Load session error: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _scrollToBottom() {
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
    _scrollToBottom();

    try {
      if (_wsConnected) {
        await _wsService.sendMessage('user', text);
      } else {
        try {
          if (widget.acpClient != null &&
              widget.acpClient!.activeMode != ConnectionPath.none) {
            // Path 2: Route through local bridge via ACPClient
            final response =
                await widget.acpClient!.sendRequest('chat/message', {
              'message': text,
              'card_id': widget.card.id,
            });

            final aiMessage =
                response['result']?['message'] ?? 'No response from AI';
            // Save AI response to server history too
            await _projectService.addSessionMessage(
                widget.card.id, 'assistant', aiMessage);
          } else {
            // Path 3: Direct to cloud server
            await _projectService.addSessionMessage(
                widget.card.id, 'user', text);
          }
          await _loadSession();
        } catch (e) {
          debugPrint('Send message error: $e');
        }
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final toolMessages = _messages.where((m) => m.role == 'tool').toList();

    return Scaffold(
      backgroundColor: Colors.grey[50],
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
          if (toolMessages.isNotEmpty) _buildExecutionSummary(toolMessages),
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
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          return MessageBubble(message: _messages[index]);
                        },
                      ),
          ),
          if (_isLoading) const LinearProgressIndicator(),
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildExecutionSummary(List<CardMessage> toolMessages) {
    return Container(
      color: Colors.indigo.withOpacity(0.05),
      child: ExpansionTile(
        dense: true,
        leading: const Icon(Icons.analytics_outlined, color: Colors.indigo),
        title: Text(
          'Execution Log: ${toolMessages.length} operations',
          style: const TextStyle(
              fontSize: 13, fontWeight: FontWeight.bold, color: Colors.indigo),
        ),
        children: [
          SizedBox(
            height: 250,
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: toolMessages.length,
              itemBuilder: (context, index) {
                final msg = toolMessages[index];
                final args = msg.metadata?['arguments'];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Card(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.check_circle_outline,
                                  size: 14, color: Colors.green),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  msg.metadata?['name'] ?? 'Unknown Tool',
                                  style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      fontFamily: 'monospace'),
                                ),
                              ),
                              Text(
                                _formatTime(msg.createdAt),
                                style: const TextStyle(
                                    fontSize: 10, color: Colors.grey),
                              ),
                            ],
                          ),
                          if (args != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Arguments: $args',
                              style: const TextStyle(
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                  color: Colors.grey),
                            ),
                          ],
                          if (msg.content.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Result: ${msg.content}',
                              style: const TextStyle(
                                  fontSize: 11, fontFamily: 'monospace'),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(String dateStr) {
    final dt = DateTime.tryParse(dateStr);
    if (dt == null) return '';
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
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
