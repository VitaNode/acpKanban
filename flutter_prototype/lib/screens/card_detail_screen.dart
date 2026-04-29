import 'dart:async';
import 'package:flutter/material.dart';
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
          if (foundMilestone != null) break;
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

  Future<void> _onFeatureSelected(ProjectFeature? feature) async {
    if (feature?.id == _card.featureId) return;
    
    setState(() {
      _selectedFeature = feature;
      _isSavingCard = true;
    });

    try {
      await ACPClient().updateCard(_card.id, featureId: feature?.id);
      _card = _card.copyWith(featureId: feature?.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Card category updated'), duration: Duration(seconds: 1)),
        );
      }
    } catch (e) {
      debugPrint('Error updating card feature: $e');
    } finally {
      if (mounted) setState(() => _isSavingCard = false);
    }
  }

  Future<void> _loadEnvironmentInfo() async {
    try {
      final providerData = await _projectService.getProviders();
      if (providerData != null && mounted) {
        final providers = providerData['providers'] as List? ?? [];
        for (final p in providers) {
          _providerNameMap[p['id']] = p['name'];
        }
      }

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

  String get _providerDisplayName {
    if (_targetProviderId != null && _providerNameMap.containsKey(_targetProviderId)) {
      return _providerNameMap[_targetProviderId]!;
    }
    return 'AI Agent';
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
            backgroundColor: Theme.of(context).colorScheme.error,
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
    _wsService.sendInit();
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
        Future.delayed(const Duration(seconds: 2), () => _loadSummary());
      }
    }
  }

  Future<void> _onDelete() async {
    final customColors = Theme.of(context).extension<CustomColors>()!;
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
              child: Text('Delete', style: TextStyle(color: Theme.of(context).colorScheme.error))),
        ],
      ),
    );

    if (confirmed == true) {
      final success = await _projectService.deleteCard(_card.id);
      if (success && mounted) {
        Navigator.pop(context);
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
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.onSurface,
                          )),
                      trailing: isCurrent
                          ? Icon(Icons.check_rounded,
                              color: Theme.of(context).colorScheme.primary)
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
        final success = await _projectService.moveCard(_card.id, targetColumn.id, null);
        if (success && mounted) {
          setState(() {
            _card = _card.copyWith(columnId: targetColumn.id);
            _isSavingCard = false;
          });
          _loadEnvironmentInfo();
          _loadSummary();
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
    final customColors = Theme.of(context).extension<CustomColors>()!;

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
        title: const Text('Permission Request'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Agent requesting: $toolName',
                  style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: AppConstants.space12),
              if (arguments.isNotEmpty)
                Container(
                  constraints: const BoxConstraints(maxHeight: 200),
                  width: double.infinity,
                  padding: const EdgeInsets.all(AppConstants.space8),
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
                  borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
                  color: Theme.of(context).cardTheme.color,
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: _availableCommands
                          .map((c) => ListTile(
                                leading: Icon(Icons.flash_on,
                                    size: 18, color: Theme.of(context).colorScheme.primary),
                                title: Text('/${c['name']}',
                                    style: Theme.of(context).textTheme.bodyLarge),
                                subtitle: Text(c['description'] ?? '',
                                    style: Theme.of(context).textTheme.bodySmall),
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
            duration: AppConstants.animationDuration, curve: Curves.easeOut);
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.appBarTheme.backgroundColor,
        border: Border(bottom: BorderSide(color: theme.dividerTheme.color!)),
      ),
      child: Row(
        children: [
          if (widget.onBack != null)
            IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: widget.onBack,
              tooltip: 'Back to Board',
            ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _titleController.text,
              style: theme.textTheme.titleLarge,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_isSavingCard || _isSavingSummary)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              if (value == 'complete') _onComplete();
              else if (value == 'delete') _onDelete();
              else if (value == 'move') _onMove();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'complete',
                child: Row(
                  children: [
                    Icon(_card.status == 'completed' ? Icons.undo_rounded : Icons.check_circle_outline_rounded, size: 20),
                    const SizedBox(width: AppConstants.space12),
                    Text(_card.status == 'completed' ? 'Reactivate Card' : 'Complete Card'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'move',
                child: Row(
                  children: [
                    const Icon(Icons.drive_file_move_outline, size: 20),
                    const SizedBox(width: AppConstants.space12),
                    const Text('Move to Column'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline_rounded, size: 20, color: theme.colorScheme.error),
                    const SizedBox(width: AppConstants.space12),
                    Text('Delete Card', style: TextStyle(color: theme.colorScheme.error)),
                  ],
                ),
              ),
            ],
          ),
        ],
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
      list.add(MessageBubble(message: m, providerName: _providerDisplayName));
    }
    
    return list;
  }

  Widget _buildFoldedHistory(List<CardMessage> messages) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppConstants.space16, vertical: AppConstants.space8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
        border: Border.all(color: Theme.of(context).dividerTheme.color!),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          title: Text('Previous Stage (${messages.length} messages)', 
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500)),
          leading: const Icon(Icons.history_rounded, size: 18),
          children: messages.map((m) => MessageBubble(message: m, providerName: _providerDisplayName)).toList(),
        ),
      ),
    );
  }

  Widget _buildRoadmapSelector(ThemeData theme, ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.all(AppConstants.space12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.alt_route_rounded, size: 16, color: colorScheme.primary),
              const SizedBox(width: 8),
              Text('Project Roadmap', style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.add_circle_outline, size: 18),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (context) => RoadmapManagerDialog(projectId: widget.projectId),
                  ).then((_) => _loadRoadmapData());
                },
                tooltip: 'Manage Roadmap',
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              // Milestone Dropdown
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<ProjectMilestone>(
                    value: _selectedMilestone,
                    isDense: true,
                    hint: const Text('Milestone', style: TextStyle(fontSize: 12)),
                    style: theme.textTheme.bodySmall,
                    items: [
                      const DropdownMenuItem<ProjectMilestone>(
                        value: null,
                        child: Text('Uncategorized', style: TextStyle(fontSize: 12)),
                      ),
                      ..._milestones.map((m) => DropdownMenuItem(
                            value: m,
                            child: Text(m.title, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
                          )),
                    ],
                    onChanged: (m) {
                      setState(() {
                        _selectedMilestone = m;
                        _selectedFeature = null;
                      });
                      if (m == null) _onFeatureSelected(null);
                    },
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.chevron_right, size: 14, color: Colors.grey),
              ),
              // Feature Dropdown
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<ProjectFeature>(
                    value: _selectedFeature,
                    isDense: true,
                    hint: const Text('Feature', style: TextStyle(fontSize: 12)),
                    style: theme.textTheme.bodySmall,
                    disabledHint: const Text('Select Milestone', style: TextStyle(fontSize: 12)),
                    items: _selectedMilestone == null
                        ? []
                        : [
                            const DropdownMenuItem<ProjectFeature>(
                              value: null,
                              child: Text('None', style: TextStyle(fontSize: 12)),
                            ),
                            ..._selectedMilestone!.features.map((f) => DropdownMenuItem(
                                  value: f,
                                  child: Text(f.title, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis),
                                )),
                          ],
                    onChanged: _selectedMilestone == null ? null : (f) => _onFeatureSelected(f),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppConstants.space16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Level 1: Title (High Emphasis)
          TextField(
              controller: _titleController,
              style: theme.textTheme.headlineLarge?.copyWith(
                fontSize: 26,
                letterSpacing: -0.5,
              ),
              decoration: const InputDecoration(
                  border: InputBorder.none, 
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: 'Card Title',
                  filled: false,
                  contentPadding: EdgeInsets.zero),
              maxLines: null),
          
          const SizedBox(height: AppConstants.space8),
          
          // Level 2: Description (Medium Emphasis, with leading icon)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(Icons.notes_rounded, 
                    size: 16, 
                    color: colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis)),
              ),
              const SizedBox(width: AppConstants.space8),
              Expanded(
                child: TextField(
                    controller: _descriptionController,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis),
                      height: 1.5,
                    ),
                    decoration: const InputDecoration(
                        border: InputBorder.none, 
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        hintText: 'Add a detailed description...',
                        filled: false,
                        contentPadding: EdgeInsets.zero),
                    maxLines: null),
              ),
            ],
          ),
          
          const SizedBox(height: AppConstants.space16),
          
          _buildRoadmapSelector(theme, colorScheme),
          
          const SizedBox(height: AppConstants.space16),
          
          // Level 3: Metadata (Disabled/Low Emphasis, chip style)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.access_time_rounded, 
                    size: 12, 
                    color: colorScheme.onSurface.withOpacity(AppConstants.disabledOpacity)),
                const SizedBox(width: 6),
                Text(
                  'Created ${DateFormatter.formatFull(_card.createdAt)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: colorScheme.onSurface.withOpacity(AppConstants.disabledOpacity),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppConstants.space16),
        ]));
  }

  Widget _buildSummarySection() {
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppConstants.space16, vertical: AppConstants.space8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.handshake_rounded, size: 16, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: AppConstants.space8),
            Text('CONTEXT FOR NEXT AGENT',
                style: Theme.of(context).textTheme.labelLarge),
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
          const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: AppConstants.space12),
          Text('Agent is working...', style: Theme.of(context).textTheme.bodySmall),
        ]));
  }

  Widget _buildInputArea() {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
        padding: const EdgeInsets.all(AppConstants.space12),
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
            Row(children: [
              Expanded(
                  child: TextField(
                      controller: _chatController,
                      focusNode: _chatFocusNode,
                      enabled: _isAgentConnected,
                      decoration: InputDecoration(
                          hintText: _isAgentConnected ? 'Ask or type / command...' : 'Connect agent to start chatting',
                          contentPadding: const EdgeInsets.symmetric(horizontal: AppConstants.space16, vertical: AppConstants.space8)),
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
          ],
        )));
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
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            leading: Icon(Icons.psychology_outlined, size: 20, color: Theme.of(context).colorScheme.primary),
            title: const Text('Agent Context', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(_isEditingContext ? Icons.check_rounded : Icons.edit_outlined, size: 18),
                  onPressed: () => setState(() => _isEditingContext = !_isEditingContext),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, size: 18, color: Colors.red),
                  onPressed: () => setState(() => _contextController.clear()),
                ),
                IconButton(
                  icon: Icon(_isShowingContext ? Icons.expand_less : Icons.expand_more, size: 20),
                  onPressed: () => setState(() => _isShowingContext = !_isShowingContext),
                ),
                const SizedBox(width: AppConstants.space4),
                ElevatedButton(
                  onPressed: _sendContextPrompt,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(0, 32),
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
                    )
                  : SingleChildScrollView(
                      child: SelectableText(
                        _contextController.text,
                        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
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
