import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/kanban_card.dart';
import '../models/card_message.dart';
import '../services/project_service.dart';
import '../services/session_websocket_service.dart';
import '../services/acp_client.dart';
import '../services/smart_connect.dart';
import '../widgets/message_bubble.dart';
import '../utils/date_formatter.dart';
import '../constants/app_constants.dart';

class CardDetailScreen extends StatefulWidget {
  final KanbanCard card;
  final String projectId;
  final String? workspacePath;
  final ACPClient? acpClient;

  const CardDetailScreen({
    super.key,
    required this.card,
    required this.projectId,
    this.workspacePath,
    this.acpClient,
  });

  @override
  State<CardDetailScreen> createState() => _CardDetailScreenState();
}

class _CardDetailScreenState extends State<CardDetailScreen> {
  final _projectService = ProjectService();
  final _wsService = SessionWebSocketService();

  late TextEditingController _titleController;
  late TextEditingController _descriptionController;
  final _chatController = TextEditingController();
  final _scrollController = ScrollController();
  final _chatFocusNode = FocusNode();

  late KanbanCard _card;
  List<CardMessage> _messages = [];
  bool _isLoadingMessages = false;
  bool _wsConnected = false;
  bool _isSavingCard = false;
  String? _sessionId;

  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _card = widget.card;
    _titleController = TextEditingController(text: _card.title);
    _descriptionController = TextEditingController(text: _card.description);

    _initWebSocket();
    _loadSessionHistory();
    _loadSessionId();
    _setupListeners();
  }

  void _setupListeners() {
    _wsService.messages.listen((msgs) {
      if (mounted) {
        setState(() {
          _messages = msgs;
          _isLoadingMessages = false;
        });
        _scrollToBottom();
      }
    });

    _wsService.status.listen((status) {
      if (mounted) {
        setState(() => _wsConnected = status == 'connected');
      }
    });

    _titleController.addListener(_onCardInfoChanged);
    _descriptionController.addListener(_onCardInfoChanged);
  }

  void _onCardInfoChanged() {
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();
    _debounceTimer = Timer(AppConstants.autoSaveDebounce, () {
      _autoSaveCard();
    });
  }

  Future<void> _autoSaveCard() async {
    final newTitle = _titleController.text.trim();
    final newDesc = _descriptionController.text.trim();

    if (newTitle.isEmpty || newTitle.length > 200) return;
    if (newTitle == _card.title && newDesc == _card.description) return;

    if (!mounted) return;
    setState(() => _isSavingCard = true);

    bool saved = false;

    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        final updated = await _projectService.updateCard(
          _card.id,
          title: newTitle,
          description: newDesc,
        );

        if (updated != null) {
          if (mounted) {
            setState(() {
              _card = updated;
              _isSavingCard = false;
            });
          }
          saved = true;
          break;
        } else {
          throw Exception('Server returned null on update');
        }
      } catch (e) {
        debugPrint('Auto-save error (attempt ${attempt + 1}): $e');
        if (attempt < 2) {
          await Future.delayed(AppConstants.retryDelayBase * (attempt + 1));
        }
      }
    }

    if (!saved && mounted) {
      setState(() => _isSavingCard = false);
      _showErrorSnackBar(
          'Failed to save changes. Please check your connection.');
    }
  }

  void _showErrorSnackBar(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: AppConstants.errorColor,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    });
  }

  Future<void> _initWebSocket() async {
    setState(() => _isLoadingMessages = true);
    final connected = await _wsService.connect(_card.id);
    if (!connected && mounted) {
      await _loadSessionHistory();
    }
  }

  Future<void> _loadSessionHistory() async {
    setState(() => _isLoadingMessages = true);
    try {
      final response = await _projectService.getSessionHistory(_card.id);
      if (response != null && mounted) {
        final List<dynamic> msgData = response['messages'] ?? [];
        setState(() {
          _messages = msgData.map((m) => CardMessage.fromJson(m)).toList();
          _isLoadingMessages = false;
        });
        _scrollToBottom();
      }
    } catch (e) {
      debugPrint('Load session history error: $e');
      if (mounted) setState(() => _isLoadingMessages = false);
    }
  }

  Future<void> _loadSessionId() async {
    try {
      final sessionId = await widget.acpClient?.getSessionId(_card.id);
      if (mounted && sessionId != null) {
        setState(() => _sessionId = sessionId['session_id']);
      }
    } catch (e) {
      debugPrint('Load session ID error: $e');
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients &&
          _scrollController.position.hasContentDimensions) {
        final maxScroll = _scrollController.position.maxScrollExtent;
        if (maxScroll.isFinite && maxScroll > 0) {
          _scrollController.animateTo(
            maxScroll,
            duration: AppConstants.animationDuration,
            curve: Curves.easeOut,
          );
        }
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _chatController.text.trim();
    if (text.isEmpty) return;

    final originalMessages = List<CardMessage>.from(_messages);

    setState(() {
      _messages = [
        ..._messages,
        CardMessage(
          id: 'temp_${DateTime.now().millisecondsSinceEpoch}',
          cardId: _card.id,
          role: 'user',
          content: text,
          createdAt: DateTime.now().toIso8601String(),
        )
      ];
      _chatController.clear();
      _isLoadingMessages = true;
    });
    _scrollToBottom();

    try {
      if (_wsConnected) {
        await _wsService.sendMessage('user', text);
      } else {
        // Path 2 or Path 3: Always persist user message to DB first to avoid loss on refresh
        await _projectService.addSessionMessage(_card.id, 'user', text);

        if (widget.acpClient != null &&
            widget.acpClient!.activeMode != ConnectionPath.none) {
          final response = await widget.acpClient!.sendRequest('chat/message', {
            'message': text,
            'card_id': _card.id,
            'card_title': _card.title,
            'card_description': _card.description,
            'workspace_path':
                widget.workspacePath, // Explicitly pass workspace path
          });

          final aiMessage = response['result']?['message'] ?? 'No response';
          await _projectService.addSessionMessage(
              _card.id, 'assistant', aiMessage);
        }

        await _loadSessionHistory();
      }
    } catch (e) {
      debugPrint('Send message error: $e');
      if (mounted) {
        setState(() {
          _messages = originalMessages;
          _isLoadingMessages = false;
        });
        _showErrorSnackBar('Failed to send message. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _isLoadingMessages = false);
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _titleController.removeListener(_onCardInfoChanged);
    _descriptionController.removeListener(_onCardInfoChanged);

    _titleController.dispose();
    _descriptionController.dispose();
    _chatController.dispose();
    _scrollController.dispose();
    _chatFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Task Hub'),
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        actions: [
          if (_isSavingCard)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _loadSessionHistory();
              _autoSaveCard();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(
                  horizontal: AppConstants.horizontalPadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _titleController,
                    maxLength: 200,
                    buildCounter: (context,
                            {required currentLength,
                            required isFocused,
                            maxLength}) =>
                        null,
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      letterSpacing: -0.5,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'Card Title',
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 8),
                      counterText: '',
                    ),
                    maxLines: null,
                  ),
                  TextField(
                    controller: _descriptionController,
                    style: TextStyle(
                      fontSize: 15,
                      color: Colors.grey[700],
                      height: 1.5,
                    ),
                    decoration: const InputDecoration(
                      hintText: 'Add a more detailed description...',
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 8),
                    ),
                    maxLines: null,
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(color: Colors.grey[100]!),
                        bottom: BorderSide(color: Colors.grey[100]!),
                      ),
                    ),
                    child: Row(
                      children: [
                        _buildSmallMeta('#${_card.shortId}'),
                        _buildDot(),
                        _buildSmallMeta(
                            'Created ${DateFormatter.formatFull(_card.createdAt)}'),
                        _buildDot(),
                        _buildSmallMeta('${_card.sessionCount} Messages'),
                        if (_sessionId != null) ...[
                          _buildDot(),
                          _buildSmallMeta(_buildSessionIdDisplay()),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_isLoadingMessages && _messages.isEmpty)
                    _buildSkeletonLoading()
                  else if (_messages.isEmpty)
                    _buildEmptyState()
                  else
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        return MessageBubble(message: _messages[index]);
                      },
                    ),
                  const SizedBox(height: 100),
                ],
              ),
            ),
          ),
          if (_isLoadingMessages && _messages.isNotEmpty)
            const LinearProgressIndicator(minHeight: 2),
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildSkeletonLoading() {
    return Column(
      children: List.generate(
          3,
          (index) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                            color: Colors.grey[100], shape: BoxShape.circle)),
                    const SizedBox(width: 12),
                    Expanded(
                        child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                            width: 80, height: 10, color: Colors.grey[100]),
                        const SizedBox(height: 8),
                        Container(
                            width: double.infinity,
                            height: 40,
                            decoration: BoxDecoration(
                                color: Colors.grey[50],
                                borderRadius: BorderRadius.circular(8))),
                      ],
                    )),
                  ],
                ),
              )),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Column(
          children: [
            Icon(Icons.chat_bubble_outline, size: 40, color: Colors.grey[200]),
            const SizedBox(height: 16),
            Text(
              'No discussion yet.\nAsk the AI Agent for help with this task.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[400], fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSmallMeta(String text) {
    return Text(
      text,
      style: AppConstants.metadataStyle.copyWith(
        color: AppConstants.metadataColor,
      ),
    );
  }

  Widget _buildDot() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Icon(Icons.circle, size: 3, color: AppConstants.metadataIconColor),
    );
  }

  String _buildSessionIdDisplay() {
    if (_sessionId == null) return 'No session';
    final short =
        _sessionId!.length > 8 ? _sessionId!.substring(0, 8) : _sessionId!;
    return 'Session: $short';
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey[200]!)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Focus(
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.enter &&
                      !HardwareKeyboard.instance.isShiftPressed) {
                    _sendMessage();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  controller: _chatController,
                  focusNode: _chatFocusNode,
                  maxLines: 5,
                  minLines: 1,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.send,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: 'Ask AI Agent (Shift+Enter for newline)...',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: Colors.grey[100],
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  ),
                  onSubmitted: (value) {
                    _sendMessage();
                  },
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: _isLoadingMessages ? null : _sendMessage,
              icon: Icon(
                Icons.send_rounded,
                color: _isLoadingMessages
                    ? Colors.grey
                    : AppConstants.primaryColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
