import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/kanban_card.dart';
import '../models/card_message.dart';
import '../services/project_service.dart';
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
  final List<ACPProvider> providers;

  const CardDetailScreen({
    super.key,
    required this.card,
    required this.projectId,
    this.workspacePath,
    this.acpClient,
    this.providers = const [],
  });

  @override
  State<CardDetailScreen> createState() => _CardDetailScreenState();
}

class _CardDetailScreenState extends State<CardDetailScreen> {
  final _projectService = ProjectService();

  late TextEditingController _titleController;
  late TextEditingController _descriptionController;
  final _chatController = TextEditingController();
  final _scrollController = ScrollController();
  final _chatFocusNode = FocusNode();

  late KanbanCard _card;
  List<CardMessage> _messages = [];
  List<KanbanCard> _relatedCards = [];
  bool _isLoadingMessages = false;
  bool _isLoadingRelated = false;
  bool _isSavingCard = false;
  String? _sessionId;

  // Tool call states
  List<Map<String, dynamic>> _toolCalls = [];
  Set<String> _expandedToolCalls = {};
  bool _isAgentProcessing = false;
  bool _isWaitingForPermission = false;

  Timer? _debounceTimer;
  StreamSubscription<String>? _acpMessageSubscription;

  @override
  void initState() {
    super.initState();
    _card = widget.card;
    _titleController = TextEditingController(text: _card.title);
    _descriptionController = TextEditingController(text: _card.description);

    _loadSessionHistory();
    _loadSessionId();
    _loadRelatedCards();
    _setupListeners();
  }

  void _setupListeners() {
    // Subscribe to ACP streaming messages
    if (widget.acpClient != null) {
      _acpMessageSubscription = widget.acpClient!.messages.listen(_handleAcpStreamMessage);
    }

    _titleController.addListener(_onCardInfoChanged);
    _descriptionController.addListener(_onCardInfoChanged);
  }

  void _handleAcpStreamMessage(String messageJson) {
    if (!mounted) return;

    try {
      final data = jsonDecode(messageJson) as Map<String, dynamic>;
      final method = data['method'] as String?;
      final params = data['params'] as Map<String, dynamic>? ?? {};
      
      // CRITICAL: Only handle messages for THIS card
      final msgCardId = params['card_id']?.toString();
      if (msgCardId != null && msgCardId != _card.id) {
        return;
      }

      final update = params['update'] as Map<String, dynamic>? ?? {};
      final sessionUpdate = update['sessionUpdate'] as String?;

      if (method == 'session/update') {
        // 1. Handle Text Streaming (agent_message_chunk)
        if (sessionUpdate == 'agent_message_chunk') {
          final content = update['content'] as Map<String, dynamic>? ?? {};
          final text = content['text']?.toString() ?? '';
          
          if (text.isNotEmpty) {
            setState(() {
              _isAgentProcessing = true;
              // If last message is assistant, append. Otherwise create new.
              if (_messages.isNotEmpty && _messages.last.role == 'assistant') {
                final last = _messages.last;
                _messages[_messages.length - 1] = last.copyWith(
                  content: last.content + text,
                );
              } else {
                _messages.add(CardMessage(
                  id: 'stream_${DateTime.now().millisecondsSinceEpoch}',
                  cardId: _card.id,
                  role: 'assistant',
                  content: text,
                  createdAt: DateTime.now().toIso8601String(),
                ));
              }
            });
            _scrollToBottom();
          }
        }
        // 2. Handle Tool Calls
        else if (sessionUpdate == 'tool_call') {
          final toolCallId = update['id']?.toString() ?? '';
          final toolName = (update['tool'] ?? update['toolName'] ?? 'Unknown Tool').toString();
          final title = update['title']?.toString() ?? '';
          final input = update['input'] as Map<String, dynamic>? ?? {};

          setState(() {
            _toolCalls.add({
              'id': toolCallId,
              'name': toolName,
              'title': title,
              'status': update['status'] ?? 'in_progress',
              'input': input,
              'content': '',
              'timestamp': DateTime.now().toIso8601String(),
            });
            _isAgentProcessing = true;
          });
          _scrollToBottom();
        }
        // 3. Handle Tool Call Updates (completed/failed)
        else if (sessionUpdate == 'tool_call_update') {
          final toolCallId = (update['id'] ?? update['toolCallId'] ?? '').toString();
          final status = update['status']?.toString() ?? '';
          final result = update['result'] ?? update['content'] ?? update['rawOutput'] ?? '';

          setState(() {
            final index = _toolCalls.indexWhere((tc) => tc['id'] == toolCallId);
            if (index != -1) {
              _toolCalls[index] = {
                ..._toolCalls[index],
                'status': status == 'completed' ? 'completed' : status == 'failed' ? 'failed' : status,
                'content': result is String ? result : const JsonEncoder().convert(result),
              };
            }
          });
          _scrollToBottom();
        }
        // 4. Handle Permission Requests
        else if (sessionUpdate == 'request_permission' ||
                 (update.containsKey('permission') && update['permission'] != null)) {
          setState(() {
            _isWaitingForPermission = true;
          });
        }
      }
      // 5. Handle Usage / End of Turn
      else if (method == 'session/update' && (update.containsKey('usage') || sessionUpdate == 'stop')) {
        setState(() {
          _isAgentProcessing = false;
          _isWaitingForPermission = false;
        });
        // Final sync from DB to ensure UI matches reality
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) _loadSessionHistory();
        });
      }
    } catch (e) {
      debugPrint('[CardDetail] Error handling ACP stream: $e');
    }
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

  Future<void> _loadSessionHistory() async {
    setState(() => _isLoadingMessages = true);
    try {
      final response = await _projectService.getSessionHistory(_card.id);
      if (response != null && mounted) {
        final List<dynamic> msgData = response['messages'] ?? [];
        final messages = msgData.map((m) => CardMessage.fromJson(m)).toList();
        
        // Detect if last message is from assistant and incomplete
        bool isStillProcessing = false;
        if (messages.isNotEmpty) {
          final last = messages.last;
          if (last.role == 'assistant' && !last.isComplete) {
            isStillProcessing = true;
          } else if (last.role == 'user') {
            // Also processing if user sent something but no assistant reply yet
            isStillProcessing = true; 
          }
        }

        setState(() {
          _messages = messages;
          _isLoadingMessages = false;
          _isAgentProcessing = isStillProcessing;
        });
        _scrollToBottom();
      }
    } catch (e) {
      debugPrint('Load session history error: $e');
      if (mounted) setState(() => _isLoadingMessages = false);
    }
  }

  Future<void> _loadSessionId() async {
    if (_card.acpSessionId != null) {
      setState(() => _sessionId = _card.acpSessionId);
      debugPrint('[CardDetail] Session ID restored: $_sessionId');
    } else {
      debugPrint('[CardDetail] No saved session for card: ${_card.id}');
    }
  }

  Future<void> _loadRelatedCards() async {
    if (!mounted) return;
    setState(() => _isLoadingRelated = true);
    try {
      final related = await _projectService.getRelatedCards(_card.id);
      if (mounted) {
        setState(() {
          _relatedCards = related;
          _isLoadingRelated = false;
        });
      }
    } catch (e) {
      debugPrint('Load related cards error: $e');
      if (mounted) setState(() => _isLoadingRelated = false);
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
    final userMessageId = 'temp_${DateTime.now().millisecondsSinceEpoch}';

    // 1. Optimistic UI Update
    setState(() {
      _messages = [
        ..._messages,
        CardMessage(
          id: userMessageId,
          cardId: _card.id,
          role: 'user',
          content: text,
          createdAt: DateTime.now().toIso8601String(),
        )
      ];
      _chatController.clear();
      _toolCalls = [];
      _expandedToolCalls = {};
      _isAgentProcessing = true;
      _isWaitingForPermission = false;
    });
    _scrollToBottom();

    // 2. Persist user message to DB (FastAPI)
    // This makes it visible even if we leave the page immediately
    try {
      await _projectService.addSessionMessage(_card.id, 'user', text);
    } catch (e) {
      debugPrint('[CardDetail] DB persistence error: $e');
    }

    // 3. Check connectivity
    if (widget.acpClient == null || 
        widget.acpClient!.activeMode == ConnectionPath.none) {
      debugPrint('[CardDetail] ACP not connected, message persisted to DB only');
      setState(() => _isAgentProcessing = false);
      return;
    }

    // 4. Send request to Bridge (Asynchronous in Backend)
    // The bridge will handle forwarding to ACP and persisting chunks to DB
    widget.acpClient!.sendRequest('chat/message', {
      'message': text,
      'card_id': _card.id,
      'card_title': _card.title,
      'card_description': _card.description,
      'workspace_path': widget.workspacePath,
      'acp_session_id': _card.acpSessionId,
    }).then((response) async {
      if (!mounted) return;

      // Handle final response if bridge returns one (usually it returns success result)
      final result = response['result'];
      if (result != null && result is Map) {
        final newSessionId = result['session_id'];
        if (newSessionId != null && newSessionId != _sessionId) {
          setState(() {
            _sessionId = newSessionId;
            _card = _card.copyWith(acpSessionId: newSessionId);
          });
          await _projectService.updateCardSessionId(_card.id, newSessionId);
        }
      }
      
      // We don't manually add assistant message here because 
      // it's being streamed via _handleAcpStreamMessage and saved to DB by Bridge.
    }).catchError((e) {
      debugPrint('[CardDetail] Send request error: $e');
      if (mounted) {
        setState(() {
          _isAgentProcessing = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _titleController.removeListener(_onCardInfoChanged);
    _descriptionController.removeListener(_onCardInfoChanged);
    
    // Cancel ACP subscription and pending requests
    _acpMessageSubscription?.cancel();
    widget.acpClient?.cancelAllPendingRequests();
    
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
                        _buildSmallMeta(
                            'Created ${DateFormatter.formatFull(_card.createdAt)}'),
                        _buildDot(),
                        _buildSmallMeta('${_card.sessionCount} Messages'),
                        if (_sessionId != null) ...[
                          _buildDot(),
                          _buildSessionIdChip(),
                        ],
                      ],
                    ),
                  ),
                  _buildRelatedCardsSection(),
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
                        final provider = _getProviderInfo();
                        return MessageBubble(
                          message: _messages[index],
                          providerId: _card.acpProviderId,
                          providerName: provider?.name ?? 'AI Agent',
                          providerIcon: provider?.icon,
                        );
                      },
                    ),
                  const SizedBox(height: 100),
                ],
              ),
            ),
          ),
          // Tool call area
          if (_toolCalls.isNotEmpty || _isAgentProcessing || _isWaitingForPermission)
            _buildToolCallArea(),
          if (_isLoadingMessages && _messages.isNotEmpty)
            const LinearProgressIndicator(minHeight: 2),
          _buildInputArea(),
        ],
      ),
    );
  }

  ACPProvider? _getProviderInfo() {
    if (_card.acpProviderId == null || widget.providers.isEmpty) return null;
    try {
      return widget.providers
          .firstWhere((p) => p.id == _card.acpProviderId);
    } catch (e) {
      return null;
    }
  }

  Widget _getProviderIcon(String? providerId) {
    if (providerId == null) return const Icon(Icons.person_outline, size: 14);
    final provider = widget.providers.firstWhere(
      (p) => p.id == providerId,
      orElse: () => ACPProvider(
        id: providerId,
        name: providerId,
        command: const [],
      ),
    );
    if (provider.icon.isNotEmpty && provider.icon != 'smart_toy') {
      return Text(provider.icon, style: const TextStyle(fontSize: 12));
    }
    return const Icon(Icons.bolt, size: 14, color: Colors.amber);
  }

  Widget _buildRelatedCardsSection() {
    if (_isLoadingRelated && _relatedCards.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(minHeight: 1),
      );
    }

    if (_relatedCards.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Row(
          children: [
            Icon(Icons.auto_awesome_motion, size: 16, color: Colors.grey[600]),
            const SizedBox(width: 8),
            Text(
              'Related Cards',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.grey[800],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 90,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _relatedCards.length,
            itemBuilder: (context, index) {
              return _buildRelatedCardItem(_relatedCards[index]);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildRelatedCardItem(KanbanCard card) {
    return Container(
      width: 160,
      margin: const EdgeInsets.only(right: 12),
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => CardDetailScreen(
                card: card,
                projectId: widget.projectId,
                workspacePath: widget.workspacePath,
                acpClient: widget.acpClient,
                providers: widget.providers,
              ),
            ),
          );
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.grey[50],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey[200]!),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                card.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  height: 1.2,
                ),
              ),
              Row(
                children: [
                  _getProviderIcon(card.acpProviderId),
                  const SizedBox(width: 4),
                  if (card.isCompleted)
                    const Icon(Icons.check_circle, size: 12, color: Colors.green)
                  else
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: Colors.blue,
                        shape: BoxShape.circle,
                      ),
                    ),
                  const Spacer(),
                  Text(
                    card.shortId,
                    style: TextStyle(
                      fontSize: 10,
                      color: Colors.grey[400],
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
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

  Widget _buildSessionIdChip() {
    return InkWell(
      onTap: () {
        if (_sessionId != null) {
          Clipboard.setData(ClipboardData(text: _sessionId!));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Session ID copied'),
              duration: Duration(seconds: 1),
            ),
          );
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.grey[100],
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          _sessionId ?? 'No session',
          style: AppConstants.metadataStyle.copyWith(
            color: AppConstants.primaryColor,
            fontFamily: 'monospace',
            fontSize: 11,
          ),
        ),
      ),
    );
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

  Widget _buildToolCallArea() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        border: Border(top: BorderSide(color: Colors.grey[200]!)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Permission waiting indicator
          if (_isWaitingForPermission)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: Colors.orange[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange[200]!),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.orange[600]!),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '等待授权...',
                      style: TextStyle(
                        color: Colors.orange[700],
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          // Tool calls summary (collapsible)
          if (_toolCalls.isNotEmpty)
            _buildToolCallSummary(),
        ],
      ),
    );
  }

  Widget _buildToolCallSummary() {
    final completedCount = _toolCalls.where((tc) => tc['status'] == 'completed' || tc['status'] == 'succeeded').length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () {
            setState(() {
              if (_expandedToolCalls.isEmpty) {
                // Expand all
                _expandedToolCalls = _toolCalls.map((tc) => tc['id'] as String).toSet();
              } else {
                // Collapse all
                _expandedToolCalls = {};
              }
            });
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey[300]!),
            ),
            child: Row(
              children: [
                Icon(Icons.build, size: 16, color: Colors.blue[600]),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${_toolCalls.length} 个工具调用${completedCount > 0 ? '（$completedCount 已完成）' : ''}',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                  ),
                ),
                Icon(
                  _expandedToolCalls.isEmpty ? Icons.expand_more : Icons.expand_less,
                  size: 16,
                  color: Colors.grey[600],
                ),
              ],
            ),
          ),
        ),
        if (_expandedToolCalls.isNotEmpty) ...[
          const SizedBox(height: 8),
          ..._toolCalls.map((toolCall) => _buildToolCallCard(toolCall)),
        ],
      ],
    );
  }

  Widget _buildToolCallCard(Map<String, dynamic> toolCall) {
    final isExpanded = _expandedToolCalls.contains(toolCall['id']);
    final status = toolCall['status'] as String;
    final name = toolCall['name'] as String;
    final input = toolCall['input'] as Map<String, dynamic>? ?? {};
    final content = toolCall['content'] as String? ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey[300]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () {
              setState(() {
                if (isExpanded) {
                  _expandedToolCalls.remove(toolCall['id']);
                } else {
                  _expandedToolCalls.add(toolCall['id']);
                }
              });
            },
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  // Status indicator
                  if (status == 'in_progress')
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.blue[600]!),
                      ),
                    )
                  else if (status == 'completed' || status == 'succeeded')
                    Icon(Icons.check_circle, size: 16, color: Colors.green[600])
                  else if (status == 'failed')
                    Icon(Icons.error, size: 16, color: Colors.red[600])
                  else
                    Icon(Icons.circle, size: 12, color: Colors.grey[400]),
                  const SizedBox(width: 8),
                  // Tool name
                  Expanded(
                    child: Text(
                      _formatToolName(name),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Input summary
                  if (input.isNotEmpty)
                    Text(
                      _formatInputSummary(input),
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[600],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  const SizedBox(width: 4),
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: Colors.grey[600],
                  ),
                ],
              ),
            ),
          ),
          // Expanded content
          if (isExpanded)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.grey[50],
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(8),
                  bottomRight: Radius.circular(8),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Input parameters
                  if (input.isNotEmpty) ...[
                    Text(
                      '输入参数:',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey[700],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.grey[300]!),
                      ),
                      child: Text(
                        const JsonEncoder.withIndent('  ').convert(input),
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  // Output content
                  if (content.isNotEmpty) ...[
                    Text(
                      '输出:',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey[700],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.grey[300]!),
                      ),
                      child: Text(
                        content.length > 1000 ? '${content.substring(0, 1000)}...' : content,
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _formatToolName(String name) {
    // Convert camelCase to readable format
    return name
        .replaceAllMapped(
          RegExp(r'([A-Z])'),
          (match) => ' ${match.group(1)}',
        )
        .trim();
  }

  String _formatInputSummary(Map<String, dynamic> input) {
    // Show first meaningful value
    for (final entry in input.entries) {
      if (entry.value != null && entry.value.toString().isNotEmpty) {
        final value = entry.value.toString();
        return value.length > 30 ? '${value.substring(0, 30)}...' : value;
      }
    }
    return '';
  }
}
