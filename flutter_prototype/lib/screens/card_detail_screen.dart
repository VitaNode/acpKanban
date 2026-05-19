import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/kanban_card.dart';
import '../models/project.dart';
import '../models/kanban_column.dart';
import '../models/card_message.dart';
import '../models/agent_plan.dart';
import '../models/ag_ui_event.dart';
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
import '../constants/ui_copy.dart';
import '../constants/error_copy.dart';
import '../theme/app_theme.dart';
import '../widgets/app_feedback.dart';
import '../utils/app_logger.dart';

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

  bool _userIsAtBottom = false;
  int _unreadCount = 0;

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

  String? _projectName;
  String? _columnName;
  late TextEditingController _contextController;
  bool _isShowingContext = false;
  bool _isEditingContext = false;

  List<ProjectMilestone> _milestones = [];
  ProjectMilestone? _selectedMilestone;
  ProjectFeature? _selectedFeature;

  String? _targetProviderId;
  final Map<String, String> _providerNameMap = {};
  bool _isInitializing = false;
  bool _isStartingSession = false;
  String? _statusMessage;
  bool _isAgentConnected = false;
  bool _isSavingCard = false;
  bool _isAgentProcessing = false;
  OverlayEntry? _commandOverlay;
  final Set<String> _respondedRequestIds = {};

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

  Timer? _renderThrottleTimer;
  List<CardMessage> _pendingMessages = [];

  @override
  void initState() {
    super.initState();
    _card = widget.card;
    _columnName = (_card.columnName != null &&
            _card.columnName!.toLowerCase() != 'detail')
        ? _card.columnName
        : null;
    _availableCommands = _card.availableCommands ?? [];
    _inputTokens = _card.inputTokens;
    _outputTokens = _card.outputTokens;
    _titleController = TextEditingController(text: _card.title);
    _descriptionController = TextEditingController(text: _card.description);
    _summaryController = TextEditingController();
    _contextController = TextEditingController();
    _isAgentConnected =
        _card.acpSessionId != null && _card.acpSessionId!.isNotEmpty;
    _setupWebSocket();
    _loadSummary();
    _loadEnvironmentInfo();
    _loadRoadmapData();
    _chatController.addListener(_onChatChanged);
    _titleController.addListener(_onCardInfoChanged);
    _descriptionController.addListener(_onCardInfoChanged);
    _scrollController.addListener(_onScroll);

    _chatFocusNode.onKeyEvent = _onChatKeyEvent;
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    bool atBottom = pos.extentAfter < 100;

    if (atBottom != _userIsAtBottom) {
      setState(() {
        _userIsAtBottom = atBottom;
        if (atBottom) {
          _unreadCount = 0;
        }
      });
    }
  }

  Future<void> _loadRoadmapData() async {
    try {
      final data =
          await ACPClient().getProjectProgress(widget.projectId, depth: 2);
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
      AppLogger.error(UICopy.failedToLoadRoadmap, e);
    }
  }

  Future<void> _loadEnvironmentInfo() async {
    try {
      var project = await _projectService.getProject(widget.projectId);
      if (project == null) {
        final allProjects = await _projectService.getProjects();
        project = allProjects.cast<Project?>().firstWhere(
              (p) => p?.id == widget.projectId,
              orElse: () => null,
            );
      }
      if (mounted && project != null) {
        setState(() {
          _projectName = project!.name;
        });
      }
    } catch (e) {
      AppLogger.error(UICopy.failedToLoadProject, e);
    }

    try {
      final columns = await _projectService.getColumns(widget.projectId);
      String? actualColumnName;
      String? targetProviderId;
      for (var col in columns) {
        if (col.id == _card.columnId) {
          actualColumnName = col.name;
          targetProviderId = col.acpProviderId;
          break;
        }
      }
      if (mounted) {
        setState(() {
          if (actualColumnName != null) {
            _columnName = actualColumnName;
          }
          _targetProviderId = targetProviderId;
        });
      }
    } catch (e) {
      AppLogger.error(UICopy.failedToLoadColumn, e);
    }

    try {
      final providers = await ACPClient().listProviders();
      final Map<String, String> nameMap = {};
      for (var p in providers) {
        if (p is Map<String, dynamic>) {
          final id = p['id']?.toString();
          final name = p['name']?.toString();
          if (id != null && name != null) {
            nameMap[id] = name;
          }
        }
      }
      if (mounted) {
        setState(() {
          _providerNameMap.addAll(nameMap);
        });
      }
    } catch (e) {
      AppLogger.error(UICopy.failedToLoadProvider, e);
    }
  }

  String get _providerDisplayName {
    if (_card.acpProviderId != null)
      return _providerNameMap[_card.acpProviderId] ?? _card.acpProviderId!;
    if (_targetProviderId != null)
      return _providerNameMap[_targetProviderId] ?? _targetProviderId!;
    return UICopy.agent;
  }

  void _setupWebSocket() {
    _wsService.connect(_card.id).then((success) {
      if (success && mounted) {
        if (_card.acpProviderId != null || _targetProviderId != null) {
          _initializeAgent();
        }
      }
    });
    _messageSub = _wsService.messages.listen((msgs) {
      if (!mounted) return;
      _pendingMessages = msgs;
      if (_renderThrottleTimer == null || !_renderThrottleTimer!.isActive) {
        _renderThrottleTimer =
            Timer(AppConstants.streamThrottleMs, _flushMessages);
      }
    });

    _planSub = _wsService.plan.listen((plan) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _currentPlan = plan);
      });
    });

    _configSub = _wsService.configOptions.listen((opts) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _configOptions = opts);
      });
    });

    _commandSub = _wsService.availableCommands.listen((cmds) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _availableCommands = cmds);
      });
    });

    _cardSub = _wsService.cardUpdates.listen((card) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onCardUpdate(card);
      });
    });

    _requestSub = _wsService.requests.listen((req) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _handleUIRequest(req);
      });
    });

    _errorSub = _wsService.errors.listen((err) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          AppFeedback.showError(context, err);
        }
      });
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

  void _flushMessages() {
    if (!mounted) return;

    final pending = List<CardMessage>.from(_pendingMessages);
    final isProcessing = pending.isNotEmpty &&
        !pending.last.isComplete &&
        pending.last.role == 'assistant';
    final bool isInitialLoad = _messages.isEmpty && pending.isNotEmpty;

    final Set<String> newRespondedIds = {};
    for (int i = 0; i < pending.length; i++) {
      final m = pending[i];
      if (m.role == 'assistant') {
        final event = AgUiEvent.fromMessage(m);
        if (event.eventType == 'interactive_request' &&
            event.requestId != null) {
          for (int j = i + 1; j < pending.length; j++) {
            final next = pending[j];
            if (next.role == 'user') {
              if (next.content.startsWith('Response:')) {
                newRespondedIds.add(event.requestId!);
                break;
              }
              if (next.content.startsWith('Authorized:')) continue;
              break;
            }
            if (next.role == 'assistant') break;
          }
        }
      }
    }

    setState(() {
      if (!_userIsAtBottom &&
          !isInitialLoad &&
          pending.length > _messages.length) {
        _unreadCount += (pending.length - _messages.length);
      }

      _messages = pending;
      _isAgentProcessing = isProcessing;
      _respondedRequestIds.addAll(newRespondedIds);

      if (isInitialLoad && isProcessing) {
        _userIsAtBottom = true;
      }
    });

    _scrollToBottom(force: isInitialLoad && isProcessing);
    _renderThrottleTimer = null;
  }

  void _onCardUpdate(KanbanCard updatedCard) {
    if (!mounted) return;
    final bool wasConnected = _isAgentConnected;
    final bool columnChanged = updatedCard.columnId != _card.columnId;

    if (columnChanged) {
      _projectService.getColumns(widget.projectId).then((cols) {
        if (!mounted) return;
        for (var col in cols) {
          if (col.id == updatedCard.columnId) {
            setState(() => _targetProviderId = col.acpProviderId);
            break;
          }
        }
      });
    }

    setState(() {
      final sessionId = updatedCard.acpSessionId;

      if (updatedCard.inputTokens > 0) _inputTokens = updatedCard.inputTokens;
      if (updatedCard.outputTokens > 0)
        _outputTokens = updatedCard.outputTokens;

      _card = _card.copyWith(
        acpSessionId: sessionId ?? _card.acpSessionId,
        acpProviderId: updatedCard.acpProviderId ?? _card.acpProviderId,
        availableCommands:
            updatedCard.availableCommands ?? _card.availableCommands,
        inputTokens: _inputTokens,
        outputTokens: _outputTokens,
      );

      if (updatedCard.availableCommands != null) {
        _availableCommands = updatedCard.availableCommands!;
      }

      if (updatedCard.columnName != null &&
          updatedCard.columnName!.isNotEmpty &&
          updatedCard.columnName!.toLowerCase() != 'detail') {
        _columnName = updatedCard.columnName;
      }

      if (!_isAgentConnected &&
          !_isStartingSession &&
          (updatedCard.acpProviderId != null || _targetProviderId != null)) {
        _initializeAgent();
      }

      if (sessionId != null) {
        if (sessionId.isEmpty) {
          _isAgentConnected = false;
          _configOptions = [];
        } else {
          _isAgentConnected = true;
          _isStartingSession = false;
          if (!wasConnected) {
            _statusMessage = UICopy.sessionReady;
            Timer(const Duration(seconds: 5), () {
              if (mounted) setState(() => _statusMessage = null);
            });
          }
        }
      }

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
      AppLogger.error(UICopy.failedToLoadSummary, e);
    }
  }

  void _onCardInfoChanged() {
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 1000), _saveCardInfo);
  }

  Future<void> _saveCardInfo() async {
    if (_titleController.text == _card.title &&
        _descriptionController.text == _card.description) return;

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
        AppFeedback.showError(context, ErrorCopy.mapError(null, e.toString()));
      }
    } finally {
      if (mounted) setState(() => _isSavingCard = false);
    }
  }

  Future<void> _initializeAgent() async {
    if (_isAgentConnected) return;
    setState(() => _isStartingSession = true);
    await _wsService.sendInit();
  }

  void _handleUIRequest(Map<String, dynamic> request) {
    final method = request['method'];
    final params = request['params'] ?? {};
    final requestId = request['id'];

    if (method == 'session/request_permission') {
      if (_wsService.uiFormat == 'ag_ui') {
        AppLogger.debug(
            'Skipping permission dialog in AG-UI mode (request is in chat)');
        return;
      }

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showPermissionDialog(requestId, params);
        }
      });
    }
  }

  void _handleInteractiveResponse(String requestId, String optionId) {
    if (_respondedRequestIds.contains(requestId)) return;

    setState(() {
      _respondedRequestIds.add(requestId);
      _isAgentProcessing = true;
    });

    final response = {
      'outcome': {'optionId': optionId}
    };

    _wsService.sendResponse(requestId, response);
    _wsService.addSyntheticUserMessage('${UICopy.authorized}: $optionId');
  }

  void _showPermissionDialog(String requestId, Map<String, dynamic> params) {
    final title = params['title'] ?? UICopy.permissionRequest;
    final message = params['message'] ?? UICopy.agentNeedsPermission;
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
                  child: Text('${UICopy.details}:',
                      style: Theme.of(context).textTheme.labelSmall),
                ),
              if (arguments.isNotEmpty)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 4),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    borderRadius:
                        BorderRadius.circular(AppConstants.radiusSmall),
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
                      "outcome": {"optionId": opt['optionId']}
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
                        borderRadius:
                            BorderRadius.circular(AppConstants.radiusMedium),
                        color: Theme.of(context).cardTheme.color,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 300),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(
                                AppConstants.radiusMedium),
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: _availableCommands
                                      .map((c) => ListTile(
                                            dense: true,
                                            leading: const Icon(Icons.bolt,
                                                size: 18),
                                            title: Text('/${c['name']}',
                                                style: const TextStyle(
                                                    fontWeight:
                                                        FontWeight.bold)),
                                            subtitle:
                                                Text(c['description'] ?? ''),
                                            onTap: () {
                                              final cmd = '/${c['name']} ';
                                              _chatController.text = cmd;
                                              _chatController.selection =
                                                  TextSelection.fromPosition(
                                                      TextPosition(
                                                          offset: cmd.length));
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

  void _scrollToBottom({bool force = false}) {
    if (!force && !_userIsAtBottom) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(_scrollController.position.maxScrollExtent,
            duration: AppConstants.animationDuration, curve: Curves.easeOut);

        if (force) {
          setState(() {
            _unreadCount = 0;
            _userIsAtBottom = true;
          });
        }
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

  Future<void> _handleStop() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(UICopy.stopAgent),
        content: const Text(UICopy.confirmStopAgent),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(UICopy.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(UICopy.stop, style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _wsService.cancelSession();
      if (mounted) {
        setState(() => _isAgentProcessing = false);
      }
    }
  }

  void _sendContextPrompt() {
    final contextText = _contextController.text.trim();
    if (contextText.isEmpty) {
      AppFeedback.showInfo(context, UICopy.contextEmpty);
      return;
    }
    final fullPrompt = "[SYSTEM CONTEXT]\n$contextText\n\nPlease acknowledge.";
    _wsService.sendMessage('user', fullPrompt);
    setState(() {
      _contextController.clear();
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
    _renderThrottleTimer?.cancel();
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
          _buildViewHeader(theme, colorScheme),
          if (_isAgentConnected) ConfigOptionsBar(options: _configOptions),
          Expanded(
            child: Stack(
              children: [
                ListView(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(
                      vertical: AppConstants.space16),
                  children: [
                    _buildHeader(),
                    if (_currentPlan != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppConstants.space16),
                        child: PlanPanel(plan: _currentPlan!),
                      ),
                    _buildSummarySection(),
                    const Padding(
                      padding: EdgeInsets.symmetric(
                          horizontal: AppConstants.space16,
                          vertical: AppConstants.space8),
                      child: Divider(),
                    ),
                    if (_messages.isEmpty)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: AppConstants.space32),
                          child: Text(UICopy.startConversation,
                              style: theme.textTheme.bodySmall),
                        ),
                      )
                    else
                      ..._buildMessageList(),
                    if (_isAgentProcessing) _buildProcessingIndicator(),
                    const SizedBox(height: AppConstants.space24),
                  ],
                ),
                if (_unreadCount > 0)
                  Positioned(
                    bottom: AppConstants.space16,
                    right: AppConstants.space16,
                    child: _buildJumpToBottomButton(colorScheme),
                  ),
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
        border: Border(
            bottom: BorderSide(color: theme.dividerColor.withOpacity(0.05))),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: widget.onBack ?? () => Navigator.pop(context),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Row(
                    children: [
                      if (_projectName != null) ...[
                        Text(
                          _projectName!,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text('>',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: colorScheme.onSurfaceVariant
                                      .withOpacity(0.5))),
                        ),
                      ],
                      if (_columnName != null &&
                          _columnName!.isNotEmpty &&
                          _columnName!.toLowerCase() != 'detail')
                        Text(
                          _columnName!,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                if (_isSavingCard)
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                _buildActionMenu(colorScheme),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _titleController,
                      maxLines: null,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: colorScheme.onSurface,
                        fontWeight: FontWeight.bold,
                      ),
                      decoration: const InputDecoration.collapsed(
                        hintText: UICopy.cardTitleHint,
                      ),
                      textInputAction: TextInputAction.newline,
                    ),
                  ),
                  if (_card.shortId.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, left: 8),
                      child: Text(
                        _card.shortId.toUpperCase(),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant.withOpacity(0.5),
                          fontFamily: 'monospace',
                          fontSize: 10,
                        ),
                      ),
                    ),
                ],
              ),
            ),
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
        if (val == 'move') _showMoveColumnDialog();
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'move',
          child: Row(
            children: [
              const Icon(Icons.drive_file_move_outlined, size: 18),
              const SizedBox(width: 12),
              const Text(UICopy.moveCard),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'complete',
          child: Row(
            children: [
              Icon(
                  _card.isCompleted
                      ? Icons.undo_rounded
                      : Icons.check_circle_outline_rounded,
                  size: 18),
              const SizedBox(width: 12),
              Text(
                  _card.isCompleted ? UICopy.markActive : UICopy.markCompleted),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline_rounded,
                  size: 18, color: colorScheme.error),
              const SizedBox(width: 12),
              Text(UICopy.deleteCard,
                  style: TextStyle(color: colorScheme.error)),
            ],
          ),
        ),
      ],
    );
  }

  void _showMoveColumnDialog() async {
    final colorScheme = Theme.of(context).colorScheme;

    try {
      final columns = await _projectService.getColumns(widget.projectId);
      if (!mounted) return;

      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text(UICopy.moveCard),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: columns.length,
              itemBuilder: (context, index) {
                final col = columns[index];
                final isCurrent = col.id == _card.columnId;

                return ListTile(
                  leading: Icon(
                    isCurrent
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: isCurrent ? colorScheme.primary : null,
                  ),
                  title: Text(col.name,
                      style: TextStyle(
                        fontWeight: isCurrent ? FontWeight.bold : null,
                      )),
                  enabled: !isCurrent,
                  onTap: () async {
                    Navigator.pop(context);
                    final success =
                        await _projectService.moveCard(_card.id, col.id, null);
                    if (success && mounted) {
                      AppFeedback.showSuccess(
                          context, '${UICopy.movedTo} ${col.name}');
                      widget.onBack?.call();
                    }
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(UICopy.cancel),
            ),
          ],
        ),
      );
    } catch (e) {
      AppFeedback.showError(context, ErrorCopy.mapError(null, e.toString()));
    }
  }

  Widget _buildHeader() {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppConstants.space16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
              border: Border.all(
                  color: colorScheme.outlineVariant.withOpacity(0.5)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<ProjectMilestone>(
                      value: _selectedMilestone,
                      isDense: true,
                      hint: const Text(UICopy.milestone,
                          style: TextStyle(fontSize: 12)),
                      style: Theme.of(context).textTheme.bodySmall,
                      items: [
                        const DropdownMenuItem<ProjectMilestone>(
                          value: null,
                          child: Text(UICopy.uncategorized,
                              style: TextStyle(fontSize: 12)),
                        ),
                        ..._milestones.map((m) => DropdownMenuItem(
                              value: m,
                              child: Text(m.title,
                                  style: const TextStyle(fontSize: 12),
                                  overflow: TextOverflow.ellipsis),
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
                  child:
                      Icon(Icons.chevron_right, size: 14, color: Colors.grey),
                ),
                Expanded(
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<ProjectFeature>(
                      value: _selectedFeature,
                      isDense: true,
                      hint: const Text(UICopy.feature,
                          style: TextStyle(fontSize: 12)),
                      style: Theme.of(context).textTheme.bodySmall,
                      disabledHint: const Text(UICopy.selectMilestone,
                          style: TextStyle(fontSize: 12)),
                      items: _selectedMilestone == null
                          ? []
                          : [
                              const DropdownMenuItem<ProjectFeature>(
                                value: null,
                                child: Text(UICopy.none,
                                    style: TextStyle(fontSize: 12)),
                              ),
                              ..._selectedMilestone!.features
                                  .map((f) => DropdownMenuItem(
                                        value: f,
                                        child: Text(f.title,
                                            style:
                                                const TextStyle(fontSize: 12),
                                            overflow: TextOverflow.ellipsis),
                                      )),
                            ],
                      onChanged: _selectedMilestone == null
                          ? null
                          : (f) => _onFeatureSelected(f),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_selectedMilestone != null && _selectedFeature != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: InkWell(
                onTap: _showRoadmapPicker,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: colorScheme.secondaryContainer.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: colorScheme.secondary.withOpacity(0.1)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.flag_rounded,
                          size: 12, color: colorScheme.secondary),
                      const SizedBox(width: 4),
                      Text(
                        '${_selectedMilestone!.title} > ${_selectedFeature!.title}',
                        style: TextStyle(
                            fontSize: 11,
                            color: colorScheme.onSecondaryContainer,
                            fontWeight: FontWeight.w500),
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
            decoration: InputDecoration(
              hintText: UICopy.addDescriptionHint,
              contentPadding: const EdgeInsets.all(AppConstants.space12),
              filled: true,
              fillColor: colorScheme.surfaceContainer.withOpacity(0.3),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
                borderSide: BorderSide(
                    color: Theme.of(context).dividerColor.withOpacity(0.05)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
                borderSide: BorderSide(
                    color: Theme.of(context).dividerColor.withOpacity(0.05)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Icon(Icons.access_time,
                  size: 12,
                  color: colorScheme.onSurfaceVariant.withOpacity(0.6)),
              const SizedBox(width: 4),
              Text(
                '${UICopy.created} ${DateFormatter.formatShortDate(_card.createdAt)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant.withOpacity(0.6),
                      fontSize: 10,
                    ),
              ),
            ],
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
            Text(UICopy.progressSummary,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.bold, letterSpacing: 1.2)),
            Row(children: [
              if (_isSavingSummary)
                const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
              else ...[
                if (!_isEditingSummary)
                  IconButton(
                    icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                    onPressed: _generateSummary,
                    tooltip: UICopy.autoGenerateSummary,
                  ),
                IconButton(
                  icon: Icon(
                      _isEditingSummary
                          ? Icons.check_rounded
                          : Icons.edit_outlined,
                      size: 18),
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
          if (_isEditingSummary)
            TextField(
              controller: _summaryController,
              maxLines: null,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                hintText: UICopy.addSummaryHint,
              ),
            )
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppConstants.space12),
              decoration: BoxDecoration(
                  color: Theme.of(context).cardTheme.color,
                  borderRadius:
                      BorderRadius.circular(AppConstants.radiusMedium),
                  border:
                      Border.all(color: Theme.of(context).dividerTheme.color!)),
              child: Text(
                (_summary == null || _summary!.isEmpty)
                    ? UICopy.noSummaryYet
                    : _summary!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      height: 1.4,
                      fontStyle: (_summary == null || _summary!.isEmpty)
                          ? FontStyle.italic
                          : null,
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
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: AppConstants.space12),
          Text(UICopy.agentThinking,
              style: Theme.of(context).textTheme.bodySmall),
        ]));
  }

  List<Widget> _buildMessageList() {
    return _messages
        .map((m) => MessageBubble(
              message: m,
              providerName: _providerDisplayName,
              providerId: _card.acpProviderId,
              respondedRequestIds: _respondedRequestIds,
              onOptionSelected: (requestId, optionId) =>
                  _handleInteractiveResponse(requestId, optionId),
            ))
        .toList();
  }

  Widget _buildJumpToBottomButton(ColorScheme colorScheme) {
    return FloatingActionButton.extended(
      onPressed: () => _scrollToBottom(force: true),
      label: Text('$_unreadCount ${UICopy.unreadMessages}'),
      icon: const Icon(Icons.arrow_downward_rounded, size: 18),
      backgroundColor: colorScheme.primary,
      foregroundColor: colorScheme.onPrimary,
      elevation: 4,
    );
  }

  Widget _buildInputArea() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            border: Border(
                top: BorderSide(color: Theme.of(context).dividerTheme.color!))),
        child: SafeArea(
            child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isAgentConnected && _contextController.text.isNotEmpty)
              _buildContextPanel(),
            if (_isStartingSession)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: const LinearProgressIndicator(minHeight: 2),
                ),
              ),
            if (_statusMessage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4, left: 4),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 10, color: colorScheme.secondary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(_statusMessage!,
                          style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 10,
                              color: colorScheme.secondary.withOpacity(0.8))),
                    ),
                  ],
                ),
              ),
            Stack(
              children: [
                Row(children: [
                  if (_isAgentConnected) ...[
                    IconButton(
                      icon: Icon(Icons.psychology_outlined,
                          color: _contextController.text.isNotEmpty
                              ? colorScheme.primary
                              : colorScheme.onSurface
                                  .withOpacity(AppConstants.mediumEmphasis)),
                      onPressed: () => _wsService.getContext(),
                      tooltip: UICopy.injectSystemContext,
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      icon: Icon(Icons.bolt_rounded,
                          color: _commandOverlay != null
                              ? colorScheme.primary
                              : colorScheme.onSurface
                                  .withOpacity(AppConstants.mediumEmphasis)),
                      onPressed: _toggleCommandsOverlay,
                      tooltip: UICopy.slashCommands,
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
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
                              hintText: _isAgentConnected
                                  ? UICopy.chatHint
                                  : UICopy.connectAgentHint,
                              contentPadding:
                                  const EdgeInsets.fromLTRB(16, 12, 16, 8)),
                          onSubmitted: (_) => _handleSend())),
                  const SizedBox(width: AppConstants.space8),
                  IconButton.filled(
                    onPressed: _isAgentProcessing
                        ? _handleStop
                        : (_isAgentConnected ? _handleSend : null),
                    icon: Icon(_isAgentProcessing
                        ? Icons.stop_rounded
                        : Icons.arrow_upward_rounded),
                    style: IconButton.styleFrom(
                      backgroundColor: _isAgentProcessing
                          ? colorScheme.error
                          : (_isAgentConnected
                              ? colorScheme.primary
                              : colorScheme.surfaceContainerHigh),
                      foregroundColor: colorScheme.onPrimary,
                    ),
                  ),
                ]),
                if (_isAgentConnected &&
                    (_inputTokens > 0 || _outputTokens > 0))
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
              style: TextStyle(
                  fontSize: 9,
                  color: colorScheme.onSurface.withOpacity(0.6),
                  fontWeight: FontWeight.w500)),
          const SizedBox(width: 4),
          Text('↓${_formatTokenCount(_outputTokens)}',
              style: TextStyle(
                  fontSize: 9,
                  color: colorScheme.onSurface.withOpacity(0.6),
                  fontWeight: FontWeight.w500)),
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
        border: Border.all(
            color: Theme.of(context).colorScheme.primary.withOpacity(0.2)),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withOpacity(0.05),
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(AppConstants.radiusMedium)),
            ),
            child: Row(
              children: [
                Icon(Icons.psychology_outlined,
                    size: 14, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text(UICopy.contextInjection,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(fontWeight: FontWeight.bold)),
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
                    style:
                        const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                    decoration: const InputDecoration(
                      hintText: UICopy.editContextHint,
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 150),
                    child: SingleChildScrollView(
                      child: Text(
                        _contextController.text,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(fontFamily: 'monospace', height: 1.4),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => setState(
                          () => _isEditingContext = !_isEditingContext),
                      child: Text(
                          _isEditingContext ? UICopy.preview : UICopy.edit),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _sendContextPrompt,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        foregroundColor:
                            Theme.of(context).colorScheme.onPrimary,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                      ),
                      child: const Text(UICopy.sendToAgent),
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
        if (result != null &&
            result['summary'] != null &&
            result['summary'].isNotEmpty) {
          AppFeedback.showSuccess(context, UICopy.summaryGenerated);
          _loadSummary();
        } else {
          AppFeedback.showInfo(
              context, result?['message'] ?? UICopy.noMessagesToSummarize);
        }
      }
    } catch (e) {
      if (mounted) {
        AppFeedback.showError(context, ErrorCopy.mapError(null, e.toString()));
      }
    } finally {
      if (mounted) setState(() => _isSavingSummary = false);
    }
  }

  Future<void> _saveSummary() async {
    setState(() => _isSavingSummary = true);
    try {
      await _projectService.updateCardSummary(
          _card.id, _summaryController.text);
      if (mounted) {
        setState(() {
          _summary = _summaryController.text;
          _isEditingSummary = false;
        });
      }
    } catch (e) {
      if (mounted) {
        AppFeedback.showError(context, ErrorCopy.mapError(null, e.toString()));
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
      final updated = await _projectService.getCard(_card.id);
      if (mounted && updated != null) {
        setState(() => _card = updated);
        AppFeedback.showSuccess(context, UICopy.cardStatusUpdate);
        if (_card.isCompleted) {
          Future.delayed(const Duration(seconds: 2), () => _loadSummary());
        }
      } else if (mounted) {
        AppFeedback.showError(context, UICopy.failedToReloadCard);
      }
    } catch (e) {
      if (mounted) {
        AppFeedback.showError(context, ErrorCopy.mapError(null, e.toString()));
      }
    }
  }

  Future<void> _onFeatureSelected(ProjectFeature? feature) async {
    try {
      await _projectService.updateCard(
        _card.id,
        featureId: feature?.id,
      );
      if (mounted) {
        setState(() {
          _selectedFeature = feature;
          _card = _card.copyWith(featureId: feature?.id);
        });
      }
    } catch (e) {
      if (mounted) {
        AppFeedback.showError(context, ErrorCopy.mapError(null, e.toString()));
      }
    }
  }

  Future<void> _onDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text(UICopy.deleteCard),
        content: Text('${UICopy.confirmDeleteCard} ("${_card.title}")'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text(UICopy.cancel)),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(UICopy.delete,
                  style: const TextStyle(color: Colors.red))),
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
          AppFeedback.showError(
              context, ErrorCopy.mapError(null, e.toString()));
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
              AppFeedback.showError(
                  context, ErrorCopy.mapError(null, e.toString()));
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
