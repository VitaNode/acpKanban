import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/kanban_card.dart';
import '../models/kanban_column.dart';
import '../models/card_message.dart';
import '../models/agent_plan.dart';
import '../models/config_option.dart';
import '../models/project_roadmap.dart';
import '../services/project_service.dart';
import '../services/session_websocket_service.dart';
import '../services/acp_client.dart';
import '../widgets/roadmap_manager_dialog.dart';
import '../widgets/message_bubble.dart';
import '../widgets/plan_panel.dart';
import '../widgets/config_options_bar.dart';
import '../utils/date_formatter.dart';
import '../constants/app_constants.dart';
import '../theme/app_theme.dart';

class CardDetailView extends StatefulWidget {
  final KanbanCard card;
  final String projectId;
  final VoidCallback? onBack;

  const CardDetailView({
    super.key,
    required this.card,
    required this.projectId,
    this.onBack,
  });

  @override
  State<CardDetailView> createState() => _CardDetailViewState();
}

class _CardDetailViewState extends State<CardDetailView> {
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
  int _inputTokens = 0;
  int _outputTokens = 0;
  
  String? _summary;
  late TextEditingController _summaryController;
  bool _isEditingSummary = false;
  bool _isSavingSummary = false;

  late TextEditingController _contextController;
  bool _isShowingContext = false;
  bool _isEditingContext = false;

  // Roadmap state
  List<ProjectMilestone> _milestones = [];
  ProjectMilestone? _selectedMilestone;
  ProjectFeature? _selectedFeature;

  String? _targetProviderId;
  final Map<String, String> _providerNameMap = {};
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
    _availableCommands = _card.availableCommands ?? [];
    _inputTokens = _card.inputTokens;
    _outputTokens = _card.outputTokens;
    _titleController = TextEditingController(text: _card.title);
    _descriptionController = TextEditingController(text: _card.description);
    _summaryController = TextEditingController();
    _contextController = TextEditingController();
    _setupWebSocket();
    _loadSummary();
    _loadEnvironmentInfo();
    _loadRoadmapData();
    _chatController.addListener(_onChatChanged);
    _titleController.addListener(_onCardInfoChanged);
    _descriptionController.addListener(_onCardInfoChanged);

    // Setup Enter to send, Shift+Enter to newline
    _chatFocusNode.onKeyEvent = _onChatKeyEvent;
  }

  Future<void> _loadRoadmapData() async {
    try {
      final data = await ACPClient().getProjectProgress(widget.projectId, depth: 2);
      final milestones = data.map((m) => ProjectMilestone.fromJson(m)).toList();
      
      ProjectMilestone? foundMilestone;
      ProjectFeature? foundFeature;
      
      if (_card.featureId != null) {
        for (var m in milestones) {
          for (var f in m.features) {
            if (f.id == _card.featureId) {
              foundMilestone = m;
              foundFeature = f;
              break;
            }
          }
          if (foundFeature != null) break;
        }
      }

      if (mounted) {
        setState(() {
          _milestones = milestones;
          _selectedMilestone = foundMilestone;
          _selectedFeature = foundFeature;
        });
      }
    } catch (e) {
      debugPrint('Error loading roadmap data: $e');
    }
  }

  Future<void> _loadEnvironmentInfo() async {
    try {
      final providers = await ACPClient().listProviders();
      final Map<String, String> nameMap = {};
      for (var p in providers) {
        if (p is Map<String, dynamic>) {
          final idValue = p['id'];
          final nameValue = p['name'];
          String? id;
          String? name;
          if (idValue is String) {
            id = idValue;
          }
          if (nameValue is String) {
            name = nameValue;
          }
          if (id != null && name != null) {
            nameMap[id] = name;
          }
        }
      }
      
      final columns = await ProjectService().getColumns(widget.projectId);
      String? targetProviderId;
      for (var col in columns) {
        if (col.id == _card.columnId) {
          targetProviderId = col.acpProviderId;
          break;
        }
      }

      if (mounted) {
        setState(() {
          _providerNameMap.addAll(nameMap);
          _targetProviderId = targetProviderId;
        });
      }
    } catch (e) {
      debugPrint('Error loading env info: $e');
    }
  }

  String get _providerDisplayName {
    if (_card.acpProviderId != null) return _providerNameMap[_card.acpProviderId] ?? _card.acpProviderId!;
    if (_targetProviderId != null) return _providerNameMap[_targetProviderId] ?? _targetProviderId!;
    return 'Agent';
  }

  void _setupWebSocket() {
    _wsService.connect(_card.id);
    _messageSub = _wsService.messages.listen((msgs) {
      if (mounted) {
        setState(() {
          _messages = msgs;
          _isAgentProcessing = msgs.isNotEmpty && !msgs.last.isComplete && msgs.last.role == 'assistant';
        });
        _scrollToBottom();
      }
    });

    _planSub = _wsService.plan.listen((plan) {
      if (mounted) setState(() => _currentPlan = plan);
    });

    _configSub = _wsService.configOptions.listen((opts) {
      if (mounted) setState(() => _configOptions = opts);
    });

    _commandSub = _wsService.availableCommands.listen((cmds) {
      if (mounted) setState(() => _availableCommands = cmds);
    });

    _cardSub = _wsService.cardUpdates.listen(_onCardUpdate);

    _requestSub = _wsService.requests.listen((req) {
      if (mounted) _handleUIRequest(req);
    });

    _errorSub = _wsService.errors.listen((err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(err),
          backgroundColor: Theme.of(context).colorScheme.error,
        ));
      }
    });

    _initializingSub = _wsService.isInitializing.listen((loading) {
      if (mounted) setState(() => _isInitializing = loading);
    });

    _contextSub = _wsService.contextData.listen((context) {
      if (mounted) {
        setState(() {
          _contextController.text = context;
          _isShowingContext = true;
          _isEditingContext = true;
        });
      }
    });
  }

  void _onCardUpdate(KanbanCard updatedCard) {
    if (!mounted) return;
    setState(() {
      // Sync Agent Session state
      final sessionId = updatedCard.acpSessionId;
      _card = _card.copyWith(
        acpSessionId: sessionId,
        acpProviderId: updatedCard.acpProviderId ?? _card.acpProviderId,
        availableCommands: updatedCard.availableCommands ?? _card.availableCommands,
        inputTokens: updatedCard.inputTokens > 0 ? updatedCard.inputTokens : _card.inputTokens,
        outputTokens: updatedCard.outputTokens > 0 ? updatedCard.outputTokens : _card.outputTokens,
      );

      if (updatedCard.availableCommands != null) {
        _availableCommands = updatedCard.availableCommands!;
      }

      if (updatedCard.inputTokens > 0) _inputTokens = updatedCard.inputTokens;
      if (updatedCard.outputTokens > 0) _outputTokens = updatedCard.outputTokens;

      if (sessionId == null || sessionId.isEmpty) {
        _isAgentConnected = false;
        _configOptions = [];
      } else {
        _isAgentConnected = true;
      }
      
      // Update local card info if title/desc changed via session_info_update
      if (updatedCard.title.isNotEmpty) {
        _titleController.text = updatedCard.title;
      }
      if (updatedCard.description.isNotEmpty) {
        _descriptionController.text = updatedCard.description;
      }
    });
  }

  Future<void> _loadSummary() async {
    try {
      final summaryData = await _projectService.getCardSummary(_card.id);
      final summaryText = summaryData?['summary'] as String?;
      if (mounted) {
        setState(() {
          _summary = summaryText;
          _summaryController.text = summaryText ?? '';
        });
      }
    } catch (e) {
      debugPrint('Error loading summary: $e');
    }
  }

  void _onCardInfoChanged() {
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 1000), _saveCardInfo);
  }

  Future<void> _saveCardInfo() async {
    if (_titleController.text == _card.title && _descriptionController.text == _card.description) return;
    
    setState(() => _isSavingCard = true);
    try {
      await _projectService.updateCard(
        _card.id,
        title: _titleController.text,
        description: _descriptionController.text,
      );
      if (mounted) {
        setState(() {
          _card = _card.copyWith(
            title: _titleController.text,
            description: _descriptionController.text,
          );
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to save: $e')));
      }
    } finally {
      if (mounted) setState(() => _isSavingCard = false);
    }
  }

  Future<void> _initializeAgent() async {
    if (_isAgentConnected) return;
    await _wsService.sendInit();
  }

  void _handleUIRequest(Map<String, dynamic> request) {
    final method = request['method'];
    final params = request['params'] ?? {};
    final requestId = request['id'];

    if (method == 'session/request_permission') {
      _showPermissionDialog(requestId, params);
    }
  }

  void _showPermissionDialog(String requestId, Map<String, dynamic> params) {
    final title = params['title'] ?? 'Permission Request';
    final message = params['message'] ?? 'The agent needs your permission to continue.';
    final options = params['options'] as List? ?? [];
    final arguments = params['arguments']?.toString() ?? '';
    final customColors = Theme.of(context).extension<CustomColors>()!;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.security_rounded, color: Colors.orange),
            const SizedBox(width: 8),
            Text(title),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              if (arguments.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text('Details:', style: Theme.of(context).textTheme.labelSmall),
                ),
              if (arguments.isNotEmpty)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 4),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
                  ),
                  child: SingleChildScrollView(
                    child: Text(arguments,
                        style: TextStyle(
                            fontSize: 13,
                            color: Theme.of(context).colorScheme.onSurface,
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
                            ? customColors.success
                            : Theme.of(context).colorScheme.error,
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

  KeyEventResult _onChatKeyEvent(FocusNode node, KeyEvent event) {
    // Detect Enter key without Shift modifier to send message
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _handleSend();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _toggleCommandsOverlay() {
    if (_commandOverlay != null) {
      _hideCommandsOverlay();
    } else {
      _showCommandsOverlay();
    }
  }

  void _showCommandsOverlay() {
    _hideCommandsOverlay();
    if (_availableCommands.isEmpty) return;
    final renderBox = context.findRenderBox()!;
    final size = renderBox.size;
    setState(() {
      _commandOverlay = OverlayEntry(
          builder: (context) => Stack(
                children: [
                  // Full-screen transparent layer to catch outside clicks
                  GestureDetector(
                    onTap: _hideCommandsOverlay,
                    behavior: HitTestBehavior.opaque,
                    child: Container(color: Colors.transparent),
                  ),
                  Positioned(
                    bottom: 80,
                    left: 16,
                    width: size.width - 32,
                    child: Material(
                        elevation: 12,
                        shadowColor: Colors.black45,
                        borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
                        color: Theme.of(context).cardTheme.color,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 300),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: _availableCommands
                                      .map((c) => ListTile(
                                            dense: true,
                                            leading: const Icon(Icons.bolt, size: 18),
                                            title: Text('/${c['name']}',
                                                style: const TextStyle(fontWeight: FontWeight.bold)),
                                            subtitle: Text(c['description'] ?? ''),
                                            onTap: () {
                                              final cmd = '/${c['name']} ';
                                              _chatController.text = cmd;
                                              _chatController.selection = TextSelection.fromPosition(
                                                  TextPosition(offset: cmd.length));
                                              _chatFocusNode.requestFocus();
                                              _hideCommandsOverlay();
                                            },
                                          ))
                                      .toList()),
                            ),
                          ),
                        )),
                  ),
                ],
              ));
      Overlay.of(context).insert(_commandOverlay!);
    });
  }

  void _hideCommandsOverlay() {
    if (_commandOverlay != null) {
      _commandOverlay!.remove();
      _commandOverlay = null;
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(_scrollController.position.maxScrollExtent,
            duration: AppConstants.animationDuration, curve: Curves.easeOut);
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
    _hideCommandsOverlay();
  }

  void _sendContextPrompt() {
    final contextText = _contextController.text.trim();
    if (contextText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Context is empty.')),
      );
      return;
    }
    final fullPrompt = "[SYSTEM CONTEXT]\n$contextText\n\nPlease acknowledge.";
    _wsService.sendMessage('user', fullPrompt);
    setState(() {
      _contextController.clear(); // Clear text to hide the panel after sending
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SelectionArea(
      child: Column(
        children: [
          // Custom Header to replace AppBar
          _buildViewHeader(theme, colorScheme),
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
                  child: Divider(),
                ),
                if (_messages.isEmpty)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: AppConstants.space32),
                      child: Text('Start a conversation...',
                          style: theme.textTheme.bodySmall),
                    ),
                  )
                else
                  ..._buildMessageList(),
                if (_isAgentProcessing) _buildProcessingIndicator(),
                const SizedBox(height: AppConstants.space24),
              ],
            ),
          ),
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildViewHeader(ThemeData theme, ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(bottom: BorderSide(color: theme.dividerColor.withOpacity(0.05))),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: widget.onBack ?? () => Navigator.pop(context),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: colorScheme.primary.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _card.shortId.toUpperCase(),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: colorScheme.primary,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _card.columnName ?? 'Detail',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _card.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            if (_isSavingCard)
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            _buildActionMenu(colorScheme),
          ],
        ),
      ),
    );
  }

  Widget _buildActionMenu(ColorScheme colorScheme) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      onSelected: (val) {
        if (val == 'delete') _onDelete();
        if (val == 'complete') _onToggleComplete();
        if (val == 'roadmap') _showRoadmapPicker();
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'roadmap',
          child: Row(
            children: [
              const Icon(Icons.alt_route_rounded, size: 18),
              const SizedBox(width: 12),
              Text(_selectedFeature != null ? 'Change Feature' : 'Link to Feature'),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'complete',
          child: Row(
            children: [
              Icon(_card.isCompleted ? Icons.undo_rounded : Icons.check_circle_outline_rounded, size: 18),
              const SizedBox(width: 12),
              Text(_card.isCompleted ? 'Mark Active' : 'Mark Completed'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline_rounded, size: 18, color: Colors.red),
              const SizedBox(width: 12),
              Text('Delete Card', style: TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHeader() {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppConstants.space16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _titleController,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            decoration: const InputDecoration(
              hintText: 'Card Title',
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const SizedBox(height: AppConstants.space8),
          Row(
            children: [
              Icon(Icons.access_time, size: 14, color: colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(
                'Created ${DateFormatter.formatRelative(_card.createdAt)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
            ],
          ),
          if (_selectedMilestone != null && _selectedFeature != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: InkWell(
                onTap: _showRoadmapPicker,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: colorScheme.secondaryContainer.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: colorScheme.secondary.withOpacity(0.1)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.flag_rounded, size: 12, color: colorScheme.secondary),
                      const SizedBox(width: 4),
                      Text(
                        '${_selectedMilestone!.title} > ${_selectedFeature!.title}',
                        style: TextStyle(fontSize: 11, color: colorScheme.onSecondaryContainer, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: AppConstants.space16),
          TextField(
            controller: _descriptionController,
            maxLines: null,
            style: Theme.of(context).textTheme.bodyMedium,
            decoration: const InputDecoration(
              hintText: 'Add a description...',
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummarySection() {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
        padding: const EdgeInsets.all(AppConstants.space16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('PROGRESS SUMMARY', style: Theme.of(context).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
            Row(children: [
              if (_isSavingSummary)
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              else ...[
                if (!_isEditingSummary)
                  IconButton(
                    icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                    onPressed: _generateSummary,
                    tooltip: 'Auto-generate summary',
                  ),
                IconButton(
                  icon: Icon(_isEditingSummary ? Icons.check_rounded : Icons.edit_outlined, size: 18),
                  onPressed: () {
                    if (_isEditingSummary) {
                      _saveSummary();
                    } else {
                      setState(() => _isEditingSummary = true);
                    }
                  },
                ),
              ],
            ]),
          ]),
          const SizedBox(height: AppConstants.space4),
          Text('Confirm or edit the progress summary before initializing the agent.', 
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
          const SizedBox(height: AppConstants.space12),
          if (_isEditingSummary)
            TextField(
              controller: _summaryController,
              maxLines: null,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                hintText: 'Add a summary of the current progress...',
              ),
            )
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppConstants.space12),
              decoration: BoxDecoration(
                  color: Theme.of(context).cardTheme.color,
                  borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
                  border: Border.all(color: Theme.of(context).dividerTheme.color!)),
              child: SelectableText(
                (_summary == null || _summary!.isEmpty) 
                  ? 'No summary available yet. Summaries are automatically generated when moving cards or completing tasks.' 
                  : _summary!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  height: 1.4,
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
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: AppConstants.space12),
          Text('Agent is thinking...', style: Theme.of(context).textTheme.bodySmall),
        ]));
  }

  List<Widget> _buildMessageList() {
    return _messages.map((m) => MessageBubble(message: m)).toList();
  }

  Widget _buildInputArea() {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            border: Border(top: BorderSide(color: Theme.of(context).dividerTheme.color!))),
        child: SafeArea(
            child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isAgentConnected && _contextController.text.isNotEmpty)
              _buildContextPanel(),
            if (!_isAgentConnected)
              Padding(
                padding: const EdgeInsets.only(bottom: AppConstants.space12),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline_rounded, size: 16),
                    const SizedBox(width: AppConstants.space8),
                    Expanded(
                      child: Text(
                          _targetProviderId != null
                              ? 'Agent [${_providerDisplayName.toUpperCase()}] is ready in this column.'
                              : 'No default agent for this column.',
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                    if (_targetProviderId != null)
                      _isInitializing
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : TextButton(
                            onPressed: _initializeAgent,
                            style: TextButton.styleFrom(
                              backgroundColor: colorScheme.primary.withOpacity(0.1),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text('INITIALIZE ${_providerDisplayName.toUpperCase()}'),
                          ),
                  ],
                ),
              ),
            Stack(
              children: [
                Row(children: [
                  if (_isAgentConnected)
                    IconButton(
                      icon: Icon(Icons.bolt_rounded, 
                        color: _commandOverlay != null 
                          ? colorScheme.primary 
                          : colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis)),
                      onPressed: _toggleCommandsOverlay,
                      tooltip: 'Slash Commands',
                      visualDensity: VisualDensity.compact,
                    ),
                  Expanded(
                      child: TextField(
                          controller: _chatController,
                          focusNode: _chatFocusNode,
                          enabled: _isAgentConnected,
                          maxLines: 5,
                          minLines: 1,
                          textInputAction: TextInputAction.newline,
                          keyboardType: TextInputType.multiline,
                          style: const TextStyle(fontSize: 14),
                          decoration: InputDecoration(
                              hintText: _isAgentConnected ? 'Ask or type / command...' : 'Connect agent to start chatting',
                              contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 8)),
                          onSubmitted: (_) => _handleSend())),
                  const SizedBox(width: AppConstants.space8),
                  IconButton.filled(
                    onPressed: _isAgentConnected ? _handleSend : null,
                    icon: const Icon(Icons.arrow_upward_rounded),
                    style: IconButton.styleFrom(
                      backgroundColor: _isAgentConnected ? colorScheme.primary : colorScheme.surfaceContainerHigh,
                      foregroundColor: colorScheme.onPrimary,
                    ),
                  ),
                ]),
                if (_isAgentConnected && (_inputTokens > 0 || _outputTokens > 0))
                  Positioned(
                    top: 4,
                    right: 60,
                    child: _buildTokenUsage(colorScheme),
                  ),
              ],
            ),
          ],
        )));
  }

  Widget _buildTokenUsage(ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer.withOpacity(0.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('↑${_formatTokenCount(_inputTokens)}', 
            style: TextStyle(fontSize: 9, color: colorScheme.onSurface.withOpacity(0.4), fontWeight: FontWeight.w500)),
          const SizedBox(width: 4),
          Text('↓${_formatTokenCount(_outputTokens)}', 
            style: TextStyle(fontSize: 9, color: colorScheme.onSurface.withOpacity(0.4), fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  String _formatTokenCount(int count) {
    if (count >= 1000000) {
      return '${(count / 1000000).toStringAsFixed(1)}M';
    } else if (count >= 1000) {
      return '${(count / 1000).toStringAsFixed(1)}k';
    }
    return count.toString();
  }

  Widget _buildContextPanel() {
    return Container(
      margin: const EdgeInsets.only(bottom: AppConstants.space12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
        border: Border.all(color: Theme.of(context).colorScheme.primary.withOpacity(0.2)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withOpacity(0.05),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(AppConstants.radiusMedium)),
            ),
            child: Row(
              children: [
                Icon(Icons.psychology_outlined, size: 14, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text('CONTEXT INJECTION', style: Theme.of(context).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 14),
                  onPressed: () => setState(() => _contextController.clear()),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                if (_isEditingContext)
                  TextField(
                    controller: _contextController,
                    maxLines: 10,
                    minLines: 3,
                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                    decoration: const InputDecoration(
                      hintText: 'Edit context details...',
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 150),
                    child: SingleChildScrollView(
                      child: Text(
                        _contextController.text,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.4),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => setState(() => _isEditingContext = !_isEditingContext),
                      child: Text(_isEditingContext ? 'PREVIEW' : 'EDIT'),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _sendContextPrompt,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor: Theme.of(context).colorScheme.onPrimary,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                      ),
                      child: const Text('SEND TO AGENT'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _generateSummary() async {
    setState(() => _isSavingSummary = true);
    try {
      final result = await _projectService.generateCardSummary(_card.id);
      if (mounted) {
        if (result != null && result['summary'] != null && result['summary'].isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Summary generated successfully!')),
          );
          _loadSummary();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(result?['message'] ?? 'No messages to summarize')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _isSavingSummary = false);
    }
  }

  Future<void> _saveSummary() async {
    setState(() => _isSavingSummary = true);
    try {
      await _projectService.updateCardSummary(_card.id, _summaryController.text);
      if (mounted) {
        setState(() {
          _summary = _summaryController.text;
          _isEditingSummary = false;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to save summary: $e')));
      }
    } finally {
      if (mounted) setState(() => _isSavingSummary = false);
    }
  }

  Future<void> _onToggleComplete() async {
    try {
      if (_card.isCompleted) {
        await _projectService.uncompleteCard(_card.id);
      } else {
        await _projectService.completeCard(_card.id);
      }
      // Re-load card data
      final updated = await _projectService.getCard(_card.id);
      if (mounted && updated != null) {
        setState(() => _card = updated);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Card "${_card.title}" ${_card.isCompleted ? 'completed' : 'active'}')),
        );
        if (_card.isCompleted) {
          Future.delayed(const Duration(seconds: 2), () => _loadSummary());
        }
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to reload card data')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
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
      try {
        await _projectService.deleteCard(_card.id);
        if (mounted && widget.onBack != null) {
          widget.onBack!();
        } else if (mounted) {
          Navigator.pop(context);
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
        }
      }
    }
  }

  void _showRoadmapPicker() {
    showDialog(
      context: context,
      builder: (context) => RoadmapManagerDialog(
        projectId: widget.projectId,
        initialFeatureId: _card.featureId,
        onFeatureSelected: (milestone, feature) async {
          try {
            await _projectService.updateCard(
              _card.id,
              featureId: feature?.id,
            );
            if (mounted) {
              setState(() {
                _selectedMilestone = milestone;
                _selectedFeature = feature;
                _card = _card.copyWith(featureId: feature?.id);
              });
            }
          } catch (e) {
             if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
            }
          }
        },
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
