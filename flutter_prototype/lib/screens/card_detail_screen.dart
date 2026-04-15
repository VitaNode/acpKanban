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
  const CardDetailScreen(
      {super.key, required this.card, required this.projectId});
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
  AgentPlan? _currentPlan;
  List<ConfigOption> _configOptions = [];
  List<Map<String, dynamic>> _availableCommands = [];
  List<KanbanCard> _relatedCards = [];

  bool _isSavingCard = false;
  bool _isAgentProcessing = false;
  OverlayEntry? _commandOverlay;

  StreamSubscription? _messageSub;
  StreamSubscription? _planSub;
  StreamSubscription? _configSub;
  StreamSubscription? _commandSub;
  StreamSubscription? _cardSub;
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _card = widget.card;
    _titleController = TextEditingController(text: _card.title);
    _descriptionController = TextEditingController(text: _card.description);
    _setupWebSocket();
    _loadRelatedCards();
    _chatController.addListener(_onChatChanged);
    _titleController.addListener(_onCardInfoChanged);
    _descriptionController.addListener(_onCardInfoChanged);
  }

  Future<void> _loadRelatedCards() async {
    final cards = await _projectService.getRelatedCards(_card.id);
    if (mounted) setState(() => _relatedCards = cards);
  }

  void _setupWebSocket() {
    _wsService.connect(_card.id);
    _messageSub = _wsService.messages.listen((msgs) {
      if (mounted)
        setState(() {
          _messages = msgs;
          // 只有流式更新产生的 streaming- 消息才显示"正在执行"
          // 历史消息（从数据库加载的）一律视为已完成
          _isAgentProcessing = msgs.isNotEmpty &&
              msgs.last.role == 'assistant' &&
              !msgs.last.isComplete &&
              msgs.last.id.startsWith('streaming-');
        });
      _scrollToBottom();
    });
    _planSub = _wsService.plan.listen((p) {
      if (mounted) setState(() => _currentPlan = p);
    });

    // 如果卡片有 sessionMode，则在收到 configOptions 后设置
    bool _modeApplied = _card.sessionMode == null;
    _configSub = _wsService.configOptions.listen((options) {
      if (mounted) {
        setState(() => _configOptions = options);
        // 应用 session mode
        if (!_modeApplied && _card.sessionMode != null && options.isNotEmpty) {
          final modeOption = options.firstWhere(
            (o) => o.category == 'mode',
            orElse: () => options.first,
          );
          if (modeOption.options.any((o) => o.value == _card.sessionMode)) {
            _wsService.setConfigOption(modeOption.id, _card.sessionMode!);
            _modeApplied = true;
          }
        }
      }
    });
    _commandSub = _wsService.availableCommands.listen((c) {
      if (mounted) setState(() => _availableCommands = c);
    });
    _cardSub = _wsService.cardUpdates.listen(_onCardUpdate);
    _wsService.requests.listen((req) {
      if (req['method'] == 'session/request_permission') {
        _showPermissionDialog(req['params'], req['id']);
      }
    });
  }

  void _onCardUpdate(KanbanCard updatedCard) {
    if (!mounted) return;
    setState(() {
      if (updatedCard.title.isNotEmpty && updatedCard.title != _card.title) {
        _card = _card.copyWith(title: updatedCard.title);
        _titleController.text = updatedCard.title;
      }
      if (updatedCard.description.isNotEmpty &&
          updatedCard.description != _card.description) {
        _card = _card.copyWith(description: updatedCard.description);
        _descriptionController.text = updatedCard.description;
      }
    });
  }

  Future<void> _showPermissionDialog(
      Map<String, dynamic> params, String requestId) async {
    final toolCall = params['toolCall'] as Map<String, dynamic>?;
    final options =
        (params['options'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    if (toolCall == null || options.isEmpty) return;

    String toolName = toolCall['name'] ?? toolCall['title'] ?? 'Unknown Tool';
    String arguments = toolCall['arguments'] ?? '';

    // Handle official ACP content block if name/arguments are missing (e.g. Plan mode)
    if (toolCall['content'] != null && toolCall['content'] is List) {
      final contentList = toolCall['content'] as List;
      for (var block in contentList) {
        if (block is Map && block['type'] == 'content') {
          final innerContent = block['content'];
          if (innerContent is Map && innerContent['type'] == 'text') {
            arguments += (arguments.isNotEmpty ? '\n' : '') +
                innerContent['text'].toString();
          }
        }
      }
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title:
            const Text('权限申请', style: TextStyle(fontWeight: FontWeight.bold)),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Agent 申请: $toolName',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              if (arguments.isNotEmpty)
                Container(
                  constraints: const BoxConstraints(maxHeight: 200),
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: SingleChildScrollView(
                    child: Text(arguments,
                        style: const TextStyle(
                            fontSize: 13,
                            color: Colors.black87,
                            fontFamily: 'monospace')),
                  ),
                ),
            ],
          ),
        ),
        actions: options
            .map((opt) => TextButton(
                  onPressed: () {
                    _wsService.sendResponse(requestId, {
                      "outcome": {
                        "outcome": "selected",
                        "optionId": opt['optionId']
                      }
                    });
                    Navigator.pop(context);
                  },
                  child: Text(opt['name'],
                      style: TextStyle(
                        color: opt['kind'].toString().contains('allow')
                            ? const Color(0xFF008080)
                            : Colors.red,
                        fontWeight: opt['kind'].toString().contains('always')
                            ? FontWeight.bold
                            : FontWeight.normal,
                      )),
                ))
            .toList(),
      ),
    );
  }

  void _onChatChanged() {
    final text = _chatController.text;
    if (text.startsWith('/') && !text.contains(' ')) {
      _showCommandsOverlay();
    } else {
      _hideCommandsOverlay();
    }
  }

  void _showCommandsOverlay() {
    _hideCommandsOverlay();
    if (_availableCommands.isEmpty) return;
    final renderBox = context.findRenderBox()!;
    final size = renderBox.size;
    _commandOverlay = OverlayEntry(
        builder: (context) => Positioned(
              bottom: 80,
              left: 16,
              width: size.width - 32,
              child: Material(
                  elevation: 8,
                  borderRadius: BorderRadius.circular(12),
                  color: Colors.white,
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: _availableCommands
                          .map((c) => ListTile(
                                leading: const Icon(Icons.flash_on,
                                    size: 18, color: Color(0xFF008080)),
                                title: Text('/${c['name']}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14)),
                                subtitle: Text(c['description'] ?? '',
                                    style: const TextStyle(fontSize: 12)),
                                onTap: () {
                                  _chatController.text = '/${c['name']} ';
                                  _chatController.selection =
                                      TextSelection.fromPosition(TextPosition(
                                          offset: _chatController.text.length));
                                  _hideCommandsOverlay();
                                },
                              ))
                          .toList())),
            ));
    Overlay.of(context).insert(_commandOverlay!);
  }

  void _hideCommandsOverlay() {
    _commandOverlay?.remove();
    _commandOverlay = null;
  }

  void _onCardInfoChanged() {
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();
    _debounceTimer =
        Timer(AppConstants.autoSaveDebounce, () => _autoSaveCard());
  }

  Future<void> _autoSaveCard() async {
    final t = _titleController.text.trim();
    final d = _descriptionController.text.trim();
    if (t.isEmpty || (t == _card.title && d == _card.description)) return;
    setState(() => _isSavingCard = true);
    try {
      final updated =
          await _projectService.updateCard(_card.id, title: t, description: d);
      if (updated != null && mounted)
        setState(() {
          _card = updated;
          _isSavingCard = false;
        });
    } catch (e) {
      if (mounted) setState(() => _isSavingCard = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients)
        _scrollController.animateTo(_scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    });
  }

  void _handleSend() {
    final text = _chatController.text.trim();
    if (text.isEmpty) return;
    _wsService.sendMessage('user', text);
    _chatController.clear();
    _chatFocusNode.requestFocus();
    setState(() => _isAgentProcessing = true);
    _hideCommandsOverlay();
  }

  @override
  void dispose() {
    _hideCommandsOverlay();
    _messageSub?.cancel();
    _planSub?.cancel();
    _configSub?.cancel();
    _commandSub?.cancel();
    _cardSub?.cancel();
    _debounceTimer?.cancel();
    _titleController.dispose();
    _descriptionController.dispose();
    _chatController.dispose();
    _scrollController.dispose();
    _chatFocusNode.dispose();
    _wsService.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppConstants.backgroundColor,
      appBar: AppBar(
          title: Text(_card.shortId,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 14)),
          actions: [
            if (_isSavingCard)
              const Center(
                  child: Padding(
                      padding: EdgeInsets.all(AppConstants.space16),
                      child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)))),
            IconButton(
              icon: const Icon(Icons.more_vert), 
              onPressed: () {},
              tooltip: 'Card Actions',
            ),
          ]),
      body: Column(children: [
        ConfigOptionsBar(options: _configOptions),
        Expanded(
            child: ListView(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(vertical: AppConstants.space16),
                children: [
              _buildHeader(),
              if (_currentPlan != null) 
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: AppConstants.space16),
                  child: PlanPanel(plan: _currentPlan!),
                ),
              if (_relatedCards.isNotEmpty) _buildRelatedCards(),
              const Padding(
                  padding: EdgeInsets.symmetric(horizontal: AppConstants.space16, vertical: AppConstants.space8),
                  child: Divider()),
              if (_messages.isEmpty)
                const Center(
                    child: Padding(
                        padding: EdgeInsets.symmetric(vertical: AppConstants.space32),
                        child: Text('Start a conversation...',
                            style: TextStyle(color: AppConstants.textHint))))
              else
                ..._messages.map(
                    (m) => MessageBubble(message: m, providerName: 'AI Agent')),
              if (_isAgentProcessing) _buildProcessingIndicator(),
              const SizedBox(height: AppConstants.space24),
            ])),
        _buildInputArea(),
      ]),
    );
  }

  Widget _buildHeader() {
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppConstants.space16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
              controller: _titleController,
              style: Theme.of(context).textTheme.headlineLarge,
              decoration: const InputDecoration(
                  border: InputBorder.none, 
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: 'Card Title',
                  filled: false,
                  contentPadding: EdgeInsets.zero),
              maxLines: null),
          TextField(
              controller: _descriptionController,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppConstants.textSecondary),
              decoration: const InputDecoration(
                  border: InputBorder.none, 
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: 'Add description...',
                  filled: false,
                  contentPadding: EdgeInsets.zero),
              maxLines: null),
          const SizedBox(height: AppConstants.space8),
          Text('Created ${DateFormatter.formatFull(_card.createdAt)}',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: AppConstants.space16),
        ]));
  }

  Widget _buildRelatedCards() {
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppConstants.space16, vertical: AppConstants.space8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.link_rounded, size: 16, color: AppConstants.textSecondary),
            const SizedBox(width: AppConstants.space8),
            Text('RELATED CARDS (${_relatedCards.length})',
                style: Theme.of(context).textTheme.labelLarge),
          ]),
          const SizedBox(height: AppConstants.space8),
          ..._relatedCards.map((c) => _buildRelatedCardItem(c)),
        ]));
  }

  Widget _buildRelatedCardItem(KanbanCard card) {
    final statusColor = card.status == 'completed'
        ? AppConstants.successColor
        : card.status == 'active'
            ? AppConstants.primaryColor
            : Colors.grey;
    return Container(
        margin: const EdgeInsets.only(bottom: AppConstants.space8),
        decoration: BoxDecoration(
            color: AppConstants.surfaceColor,
            borderRadius: BorderRadius.circular(AppConstants.space12),
            border: Border.all(color: Colors.grey.shade200)),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              Navigator.pushReplacement(
                context, 
                MaterialPageRoute(builder: (context) => CardDetailScreen(card: card, projectId: widget.projectId))
              );
            },
            borderRadius: BorderRadius.circular(AppConstants.space12),
            child: Padding(
              padding: const EdgeInsets.all(AppConstants.space12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                          color: statusColor, shape: BoxShape.circle)),
                  const SizedBox(width: AppConstants.space8),
                  Expanded(
                      child: Text(card.title,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold))),
                  if (card.columnName != null)
                    Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: AppConstants.space8, vertical: 2),
                        decoration: BoxDecoration(
                            color: Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(AppConstants.space8)),
                        child: Text(card.columnName!,
                            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600))),
                ]),
                if (card.summary != null) ...[
                  const SizedBox(height: AppConstants.space4),
                  Text(card.summary!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ]),
            ),
          ),
        ));
  }

  Widget _buildProcessingIndicator() {
    return Padding(
        padding: const EdgeInsets.all(AppConstants.space16),
        child: Row(children: [
          const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: AppConstants.space12),
          Text('Agent is working...',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
        ]));
  }

  Widget _buildInputArea() {
    return Container(
        padding: const EdgeInsets.all(AppConstants.space12),
        decoration: BoxDecoration(
            color: AppConstants.backgroundColor,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                offset: const Offset(0, -2),
              ),
            ],
            border: Border(top: BorderSide(color: Colors.grey.shade200))),
        child: SafeArea(
            child: Row(children: [
          Expanded(
              child: TextField(
                  controller: _chatController,
                  focusNode: _chatFocusNode,
                  decoration: InputDecoration(
                      hintText: 'Ask or type / command...',
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppConstants.space24),
                          borderSide: BorderSide.none),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppConstants.space24),
                          borderSide: BorderSide.none),
                      focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppConstants.space24),
                          borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: AppConstants.space16, vertical: AppConstants.space8)),
                  onSubmitted: (_) => _handleSend())),
          const SizedBox(width: AppConstants.space8),
          Material(
            color: AppConstants.primaryColor,
            borderRadius: BorderRadius.circular(AppConstants.space24),
            child: InkWell(
              onTap: _handleSend,
              borderRadius: BorderRadius.circular(AppConstants.space24),
              child: const Padding(
                padding: EdgeInsets.all(AppConstants.space8),
                child: Icon(Icons.arrow_upward_rounded, color: Colors.white, size: 24),
              ),
            ),
          ),
        ])));
  }
}

extension RenderBoxExtension on BuildContext {
  RenderBox? findRenderBox() {
    final renderObject = findRenderObject();
    if (renderObject is RenderBox) return renderObject;
    return null;
  }
}
