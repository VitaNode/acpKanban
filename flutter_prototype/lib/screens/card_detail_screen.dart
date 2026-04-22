import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/kanban_card.dart';
import '../models/kanban_column.dart';
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
  
  String? _summary;
  late TextEditingController _summaryController;
  bool _isEditingSummary = false;
  bool _isSavingSummary = false;

  late TextEditingController _contextController;
  bool _isShowingContext = false;
  bool _isEditingContext = false;

  String? _targetProviderId;
  bool _isInitializing = false;
  bool _isAgentConnected = false;
  bool _isSavingCard = false;
  bool _isAgentProcessing = false;
  OverlayEntry? _commandOverlay;

  StreamSubscription? _messageSub;
  StreamSubscription? _planSub;
  StreamSubscription? _configSub;
  StreamSubscription? _commandSub;
  StreamSubscription? _cardSub;
  StreamSubscription? _requestSub;
  StreamSubscription? _errorSub;
  StreamSubscription? _initializingSub;
  StreamSubscription? _contextSub;
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _card = widget.card;
    _titleController = TextEditingController(text: _card.title);
    _descriptionController = TextEditingController(text: _card.description);
    _summaryController = TextEditingController();
    _contextController = TextEditingController();
    _setupWebSocket();
    _loadSummary();
    _loadEnvironmentInfo();
    _chatController.addListener(_onChatChanged);
    _titleController.addListener(_onCardInfoChanged);
    _descriptionController.addListener(_onCardInfoChanged);
  }

  Future<void> _loadEnvironmentInfo() async {
    try {
      final columns = await _projectService.getColumns(widget.projectId);
      final myColumn = columns.firstWhere((c) => c.id == _card.columnId);
      if (mounted) {
        setState(() {
          _targetProviderId = myColumn.acpProviderId;
        });
      }
    } catch (e) {
      debugPrint('Load environment info error: $e');
    }
  }

  Future<void> _loadSummary() async {
    try {
      final summaryObj = await _projectService.getCardSummary(_card.id);
      if (mounted) {
        setState(() {
          _summary = summaryObj?['summary'];
          _summaryController.text = _summary ?? '';
        });
      }
    } catch (e) {
      debugPrint('Load summary error: $e');
    }
  }

  Future<void> _saveSummary() async {
    final s = _summaryController.text.trim();
    if (s == _summary) {
      setState(() => _isEditingSummary = false);
      return;
    }
    setState(() => _isSavingSummary = true);
    try {
      final success = await _projectService.updateCardSummary(_card.id, s);
      if (success && mounted) {
        setState(() {
          _summary = s;
          _isEditingSummary = false;
          _isSavingSummary = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isSavingSummary = false);
    }
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
              (msgs.last.id.startsWith('streaming-') || msgs.last.id.startsWith('thought-'));
        });
      _scrollToBottom();
    });
    _planSub = _wsService.plan.listen((p) {
      if (mounted) setState(() => _currentPlan = p);
    });

    _configSub = _wsService.configOptions.listen((options) {
      if (mounted) {
        setState(() {
          _configOptions = options;
          if (options.isNotEmpty) _isAgentConnected = true;
        });
      }
    });

    _commandSub = _wsService.availableCommands.listen((c) {
      if (mounted) setState(() => _availableCommands = c);
    });
    _cardSub = _wsService.cardUpdates.listen(_onCardUpdate);
    
    _errorSub = _wsService.errors.listen((error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error),
            backgroundColor: AppConstants.errorColor,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    });

    _initializingSub = _wsService.isInitializing.listen((init) {
      if (mounted) setState(() => _isInitializing = init);
    });

    _contextSub = _wsService.contextData.listen((contextText) {
      if (mounted) {
        setState(() {
          _contextController.text = contextText;
          _isShowingContext = true;
        });
      }
    });

    _requestSub = _wsService.requests.listen((req) {
      if (req['method'] == 'session/request_permission') {
        _showPermissionDialog(req['params'], req['id']);
      } else if (req['type'] == 'session_info') {
        if (mounted) {
          setState(() {
            _isInitializing = false;
            _isAgentConnected = true;
            _configOptions = (req['config_options'] as List?)
                ?.map((x) => ConfigOption.fromJson(x))
                .toList() ?? [];
          });
        }
      }
    });
  }

  Future<void> _initializeAgent() async {
    if (_isInitializing) return;
    setState(() => _isInitializing = true);
    // Send session_init command via WebSocket
    _wsService.sendInit();
    // Also request the context immediately
    _wsService.getContext();
  }

  Future<void> _onComplete() async {
    if (_card.status == 'completed') {
      final updated = await _projectService.uncompleteCard(_card.id);
      if (updated != null && mounted) {
        setState(() => _card = updated);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Card "${_card.title}" reactivated')),
        );
      }
    } else {
      final updated = await _projectService.completeCard(_card.id);
      if (updated != null && mounted) {
        setState(() => _card = updated);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Card "${_card.title}" completed')),
        );
      }
    }
  }

  Future<void> _onDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Card'),
        content: Text('Are you sure you want to delete "${_card.title}"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );

    if (confirmed == true) {
      final success = await _projectService.deleteCard(_card.id);
      if (success && mounted) {
        Navigator.pop(context); // Go back to board
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Card "${_card.title}" deleted')),
        );
      }
    }
  }

  Future<void> _onMove() async {
    setState(() => _isSavingCard = true);
    try {
      final columns = await _projectService.getColumns(widget.projectId);
      if (!mounted) return;
      setState(() => _isSavingCard = false);

      final targetColumn = await showDialog<KanbanColumn>(
        context: context,
        builder: (context) {
          final size = MediaQuery.of(context).size;
          return AlertDialog(
            title: const Text('Move to Column'),
            content: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 400,
                maxHeight: size.height * 0.6,
              ),
              child: SizedBox(
                width: size.width * 0.8,
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: columns.length,
                  separatorBuilder: (context, index) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final col = columns[index];
                    final isCurrent = col.id == _card.columnId;
                    return ListTile(
                      title: Text(col.name,
                          style: TextStyle(
                            fontWeight:
                                isCurrent ? FontWeight.bold : FontWeight.normal,
                            color: isCurrent
                                ? AppConstants.primaryColor
                                : AppConstants.textPrimary,
                          )),
                      trailing: isCurrent
                          ? const Icon(Icons.check_rounded,
                              color: AppConstants.primaryColor)
                          : null,
                      onTap: isCurrent ? null : () => Navigator.pop(context, col),
                    );
                  },
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
            ],
          );
        },
      );

      if (targetColumn != null && mounted) {
        setState(() => _isSavingCard = true);
        final success = await _projectService.moveCard(_card.id, targetColumn.id, 0);
        if (success && mounted) {
          setState(() {
            _card = _card.copyWith(columnId: targetColumn.id);
            _isSavingCard = false;
          });
          _loadEnvironmentInfo(); // Reload provider info for new column
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Moved to ${targetColumn.name}')),
          );
        } else if (mounted) {
          setState(() => _isSavingCard = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to move card')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSavingCard = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
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
    // Ensure AppBar title updates immediately
    if (mounted) setState(() {});
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

  void _sendContextPrompt() {
    final contextText = _contextController.text.trim();
    final fullPrompt = "[SYSTEM CONTEXT]\n$contextText\n\nPlease acknowledge.";
    _wsService.sendMessage('user', fullPrompt);
    setState(() {
      _isShowingContext = false;
      _isAgentProcessing = true;
    });
  }

  @override
  void dispose() {
    _hideCommandsOverlay();
    _messageSub?.cancel();
    _planSub?.cancel();
    _configSub?.cancel();
    _commandSub?.cancel();
    _cardSub?.cancel();
    _requestSub?.cancel();
    _errorSub?.cancel();
    _initializingSub?.cancel();
    _debounceTimer?.cancel();
    _titleController.dispose();
    _descriptionController.dispose();
    _summaryController.dispose();
    _contextController.dispose();
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
          title: Text(_titleController.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          actions: [
            if (_isSavingCard || _isSavingSummary)
              const Center(
                  child: Padding(
                      padding: EdgeInsets.all(AppConstants.space16),
                      child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2)))),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              tooltip: 'Card Actions',
              onSelected: (value) {
                if (value == 'complete') {
                  _onComplete();
                } else if (value == 'delete') {
                  _onDelete();
                } else if (value == 'move') {
                  _onMove();
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'complete',
                  child: Row(
                    children: [
                      Icon(
                          _card.status == 'completed'
                              ? Icons.undo_rounded
                              : Icons.check_circle_outline_rounded,
                          size: 20),
                      const SizedBox(width: 12),
                      Text(_card.status == 'completed'
                          ? 'Reactivate Card'
                          : 'Complete Card'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'move',
                  child: Row(
                    children: [
                      Icon(Icons.drive_file_move_outline, size: 20),
                      const SizedBox(width: 12),
                      Text('Move to Column'),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline_rounded,
                          size: 20, color: Colors.red),
                      const SizedBox(width: 12),
                      Text('Delete Card', style: TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
              ],
            ),
          ]),
      body: SelectionArea(
        child: Column(children: [
          if (_isAgentConnected) ConfigOptionsBar(options: _configOptions),
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
                _buildSummarySection(),
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
                  ..._buildMessageList(),
                if (_isAgentProcessing) _buildProcessingIndicator(),
                const SizedBox(height: AppConstants.space24),
              ])),
          _buildInputArea(),
        ]),
      ),
    );
  }

  List<Widget> _buildMessageList() {
    final List<Widget> list = [];
    List<CardMessage> currentBlock = [];
    
    for (var m in _messages) {
      if (m.metadata?['is_milestone'] == 1 || m.metadata?['is_milestone'] == true) {
        if (currentBlock.isNotEmpty) {
          list.add(_buildFoldedHistory(currentBlock));
          currentBlock = [];
        }
        list.add(MessageBubble(message: m, providerName: 'System'));
      } else {
        currentBlock.add(m);
      }
    }
    
    for (var m in currentBlock) {
      list.add(MessageBubble(message: m, providerName: 'AI Agent'));
    }
    
    return list;
  }

  Widget _buildFoldedHistory(List<CardMessage> messages) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppConstants.space16, vertical: AppConstants.space8),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(AppConstants.space12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          title: Text('Previous Stage (${messages.length} messages)', 
              style: const TextStyle(fontSize: 12, color: AppConstants.textSecondary, fontWeight: FontWeight.w500)),
          leading: const Icon(Icons.history_rounded, size: 18, color: AppConstants.textSecondary),
          children: messages.map((m) => MessageBubble(message: m, providerName: 'AI Agent')).toList(),
        ),
      ),
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

  Widget _buildSummarySection() {
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppConstants.space16, vertical: AppConstants.space8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.handshake_rounded, size: 16, color: AppConstants.primaryColor),
            const SizedBox(width: AppConstants.space8),
            Text('CONTEXT FOR NEXT AGENT',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(color: AppConstants.primaryColor, fontWeight: FontWeight.bold)),
            const Spacer(),
            if (!_isEditingSummary)
              TextButton.icon(
                onPressed: () => setState(() => _isEditingSummary = true),
                icon: const Icon(Icons.edit_rounded, size: 14),
                label: const Text('Edit', style: TextStyle(fontSize: 12)),
              )
            else
              Row(children: [
                TextButton(
                  onPressed: () => setState(() {
                    _isEditingSummary = false;
                    _summaryController.text = _summary ?? '';
                  }),
                  child: const Text('Cancel', style: TextStyle(fontSize: 12)),
                ),
                TextButton(
                  onPressed: _saveSummary,
                  child: const Text('Save', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ]),
          ]),
          const SizedBox(height: 4),
          const Text('Confirm or edit the progress summary before initializing the agent.', 
              style: TextStyle(fontSize: 10, color: AppConstants.textSecondary, fontStyle: FontStyle.italic)),
          const SizedBox(height: 12),
          if (_isEditingSummary)
            TextField(
              controller: _summaryController,
              maxLines: null,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Add a summary of the current progress...',
                filled: true,
                fillColor: Colors.grey.shade50,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppConstants.space8), borderSide: BorderSide.none),
              ),
            )
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppConstants.space12),
              decoration: BoxDecoration(
                  color: AppConstants.surfaceColor,
                  borderRadius: BorderRadius.circular(AppConstants.space12),
                  border: Border.all(color: Colors.grey.shade200)),
              child: SelectableText(
                (_summary == null || _summary!.isEmpty) 
                  ? 'No summary available yet. Summaries are automatically generated when moving cards or completing tasks. You can also manually edit this area to provide context for the next stage.' 
                  : _summary!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  height: 1.4,
                  color: (_summary == null || _summary!.isEmpty) ? AppConstants.textHint : null,
                  fontStyle: (_summary == null || _summary!.isEmpty) ? FontStyle.italic : null,
                ),
              ),
            ),
        ]));
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
            child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isAgentConnected && _contextController.text.isNotEmpty)
              _buildContextPanel(),
            if (!_isAgentConnected)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline_rounded,
                        size: 16, color: AppConstants.textSecondary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                          _targetProviderId != null
                              ? 'Agent [${_targetProviderId!.toUpperCase()}] is ready in this column.'
                              : 'No default agent for this column.',
                          style: const TextStyle(
                              fontSize: 12, color: AppConstants.textSecondary)),
                    ),
                    if (_targetProviderId == null)
                      const SizedBox.shrink()
                    else if (_isInitializing)
                      const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                    else
                      TextButton(
                        onPressed: _initializeAgent,
                        style: TextButton.styleFrom(
                          backgroundColor:
                              AppConstants.primaryColor.withOpacity(0.1),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 4),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                            'INITIALIZE ${_targetProviderId?.toUpperCase() ?? "AGENT"}'),
                      ),
                  ],
                ),
              ),
            Row(children: [
              Expanded(
                  child: TextField(
                      controller: _chatController,
                      focusNode: _chatFocusNode,
                      enabled: _isAgentConnected,
                      decoration: InputDecoration(
                          hintText: _isAgentConnected
                              ? 'Ask or type / command...'
                              : 'Connect agent to start chatting',
                          border: OutlineInputBorder(
                              borderRadius:
                                  BorderRadius.circular(AppConstants.space24),
                              borderSide: BorderSide.none),
                          enabledBorder: OutlineInputBorder(
                              borderRadius:
                                  BorderRadius.circular(AppConstants.space24),
                              borderSide: BorderSide.none),
                          focusedBorder: OutlineInputBorder(
                              borderRadius:
                                  BorderRadius.circular(AppConstants.space24),
                              borderSide: BorderSide.none),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: AppConstants.space16,
                              vertical: AppConstants.space8)),
                      onSubmitted: (_) => _handleSend())),
              const SizedBox(width: AppConstants.space8),
              Material(
                color: _isAgentConnected
                    ? AppConstants.primaryColor
                    : Colors.grey.shade300,
                borderRadius: BorderRadius.circular(AppConstants.space24),
                child: InkWell(
                  onTap: _isAgentConnected ? _handleSend : null,
                  borderRadius: BorderRadius.circular(AppConstants.space24),
                  child: const Padding(
                    padding: EdgeInsets.all(AppConstants.space8),
                    child: Icon(Icons.arrow_upward_rounded,
                        color: Colors.white, size: 24),
                  ),
                ),
              ),
            ]),
          ],
        )));
  }

  Widget _buildContextPanel() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppConstants.primaryColor.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(
            color: AppConstants.primaryColor.withOpacity(0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            leading: const Icon(Icons.psychology_outlined, size: 20, color: AppConstants.primaryColor),
            title: const Text('Agent Context', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!_isEditingContext)
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    onPressed: () => setState(() => _isEditingContext = true),
                    tooltip: 'Edit Context',
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.check_rounded, size: 18, color: Colors.green),
                    onPressed: () => setState(() => _isEditingContext = false),
                    tooltip: 'Done Editing',
                  ),
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, size: 18, color: Colors.red),
                  onPressed: () => setState(() => _contextController.clear()),
                  tooltip: 'Clear Context',
                ),
                IconButton(
                  icon: Icon(_isShowingContext ? Icons.expand_less : Icons.expand_more, size: 20),
                  onPressed: () => setState(() => _isShowingContext = !_isShowingContext),
                ),
                const SizedBox(width: 4),
                ElevatedButton(
                  onPressed: _sendContextPrompt,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppConstants.primaryColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                    minimumSize: const Size(0, 32),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: const Text('SEND', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
          if (_isShowingContext)
            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: _isEditingContext
                  ? TextField(
                      controller: _contextController,
                      maxLines: null,
                      style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.all(8),
                      ),
                    )
                  : SingleChildScrollView(
                      child: SelectableText(
                        _contextController.text,
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade800, fontFamily: 'monospace'),
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}

extension RenderBoxExtension on BuildContext {
  RenderBox? findRenderBox() {
    final renderObject = findRenderObject();
    if (renderObject is RenderBox) return renderObject;
    return null;
  }
}
