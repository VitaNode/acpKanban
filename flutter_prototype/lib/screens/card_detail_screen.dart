import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/kanban_card.dart';
import '../models/card_message.dart';
import '../models/agent_plan.dart';
import '../models/config_option.dart';
import '../services/project_service.dart';
import '../services/session_websocket_service.dart';
import '../widgets/message_bubble.dart';
import '../widgets/plan_panel.dart';
import '../widgets/config_options_bar.dart';
import '../utils/date_formatter.dart';
import '../constants/app_constants.dart';

class CardDetailScreen extends StatefulWidget {
  final KanbanCard card;
  final String projectId;

  const CardDetailScreen({
    super.key,
    required this.card,
    required this.projectId,
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
  
  // Phase 5.2: New States
  AgentPlan? _currentPlan;
  List<ConfigOption> _configOptions = [];
  
  bool _isLoadingMessages = false;
  bool _isSavingCard = false;
  bool _isAgentProcessing = false;

  StreamSubscription? _messageSub;
  StreamSubscription? _planSub;
  StreamSubscription? _configSub;
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _card = widget.card;
    _titleController = TextEditingController(text: _card.title);
    _descriptionController = TextEditingController(text: _card.description);

    _setupWebSocket();
    _titleController.addListener(_onCardInfoChanged);
    _descriptionController.addListener(_onCardInfoChanged);
  }

  void _setupWebSocket() {
    _wsService.connect(_card.id);
    
    _messageSub = _wsService.messages.listen((msgs) {
      if (mounted) {
        setState(() {
          _messages = msgs;
          _isAgentProcessing = msgs.isNotEmpty && 
                             msgs.last.role == 'assistant' && 
                             !msgs.last.isComplete;
        });
        _scrollToBottom();
      }
    });

    _planSub = _wsService.plan.listen((plan) {
      if (mounted) setState(() => _currentPlan = plan);
    });

    _configSub = _wsService.configOptions.listen((options) {
      if (mounted) setState(() => _configOptions = options);
    });
  }

  void _onCardInfoChanged() {
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();
    _debounceTimer = Timer(AppConstants.autoSaveDebounce, () => _autoSaveCard());
  }

  Future<void> _autoSaveCard() async {
    final newTitle = _titleController.text.trim();
    final newDesc = _descriptionController.text.trim();
    if (newTitle.isEmpty || (newTitle == _card.title && newDesc == _card.description)) return;

    setState(() => _isSavingCard = true);
    try {
      final updated = await _projectService.updateCard(_card.id, title: newTitle, description: newDesc);
      if (updated != null && mounted) {
        setState(() { _card = updated; _isSavingCard = false; });
      }
    } catch (e) {
      if (mounted) setState(() => _isSavingCard = false);
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

  void _handleSend() {
    final text = _chatController.text.trim();
    if (text.isEmpty) return;

    _wsService.sendMessage('user', text);
    _chatController.clear();
    _chatFocusNode.requestFocus();
    setState(() => _isAgentProcessing = true);
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    _planSub?.cancel();
    _configSub?.cancel();
    _debounceTimer?.cancel();
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
        title: Text(_card.shortId, style: const TextStyle(fontFamily: 'monospace', fontSize: 14)),
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        actions: [
          if (_isSavingCard)
            const Center(child: Padding(padding: EdgeInsets.all(16), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)))),
          IconButton(icon: const Icon(Icons.more_vert), onPressed: () {}),
        ],
      ),
      body: Column(
        children: [
          // Phase 5.2: Config Options Bar
          ConfigOptionsBar(options: _configOptions),
          
          Expanded(
            child: ListView(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(vertical: 16),
              children: [
                _buildHeader(),
                
                // Phase 5.2: Plan Panel (displayed above messages if active)
                if (_currentPlan != null)
                  PlanPanel(plan: _currentPlan!),
                
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Divider(),
                ),

                if (_messages.isEmpty)
                  _buildEmptyState()
                else
                  ..._messages.map((m) => MessageBubble(
                    message: m,
                    providerName: 'AI Agent',
                  )),
                
                if (_isAgentProcessing)
                  _buildProcessingIndicator(),
                  
                const SizedBox(height: 20),
              ],
            ),
          ),
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _titleController,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            decoration: const InputDecoration(border: InputBorder.none, hintText: '任务标题'),
            maxLines: null,
          ),
          TextField(
            controller: _descriptionController,
            style: TextStyle(fontSize: 15, color: Colors.grey[700]),
            decoration: const InputDecoration(border: InputBorder.none, hintText: '添加描述...'),
            maxLines: null,
          ),
          const SizedBox(height: 8),
          Text(
            'Created ${DateFormatter.formatFull(_card.createdAt)}',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Text('没有对话记录，开始询问 AI 吧', style: TextStyle(color: Colors.grey)),
      ),
    );
  }

  Widget _buildProcessingIndicator() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Row(
        children: [
          const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Text('AI 正在思考...', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey[200]!)),
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _chatController,
                focusNode: _chatFocusNode,
                decoration: InputDecoration(
                  hintText: '输入指令或 / 命令...',
                  filled: true,
                  fillColor: Colors.grey[100],
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                ),
                onSubmitted: (_) => _handleSend(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.send, color: Color(0xFF008080)),
              onPressed: _handleSend,
            ),
          ],
        ),
      ),
    );
  }
}
