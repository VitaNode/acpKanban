import 'dart:async';
import 'package:flutter/material.dart';
import 'services/acp_client.dart';
import 'services/smart_connect.dart';
import 'services/connection_config_manager.dart';
import 'services/project_service.dart';
import 'services/kanban_refresh_service.dart';
import 'models/connection_config.dart';
import 'models/kanban_card.dart';
import 'models/kanban_column.dart';
import 'models/project.dart';
import 'screens/connection_settings_screen.dart';
import 'screens/card_detail_screen.dart';
import 'widgets/project_selector.dart';
import 'widgets/project_management_dialog.dart';
import 'widgets/kanban_column_widget.dart';
import 'widgets/column_manager_dialog.dart';
import 'widgets/timeline_view.dart';
import 'widgets/status_summary_widget.dart';
import 'widgets/project_roadmap_view.dart';
import 'widgets/roadmap_manager_dialog.dart';
import 'models/timeline_event.dart';
import 'theme/app_theme.dart';
import 'constants/app_constants.dart';
import 'constants/ui_copy.dart';
import 'constants/error_copy.dart';
import 'services/theme_service.dart';
import 'widgets/app_feedback.dart';
import 'widgets/app_state_view.dart';
import 'models/app_funnel_state.dart';
import 'utils/app_logger.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeService().init();
  runApp(const KanbanApp());
}

class KanbanApp extends StatelessWidget {
  const KanbanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeService(),
      builder: (context, _) {
        return GestureDetector(
          onTap: () {
            FocusScopeNode currentFocus = FocusScope.of(context);
            if (!currentFocus.hasPrimaryFocus &&
                currentFocus.focusedChild != null) {
              FocusManager.instance.primaryFocus?.unfocus();
            }
          },
          child: MaterialApp(
            title: UICopy.appTitle,
            debugShowCheckedModeBanner: false,
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: ThemeService().themeMode,
            home: const MainScreen(),
          ),
        );
      },
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final _acpClient = ACPClient();
  final _projectService = ProjectService();
  List<KanbanCard> _cards = [];
  List<TimelineEvent> _timelineEvents = [];
  List<ProjectAgentStatus> _agentStatuses = [];
  String? _userId;

  AppFunnelState _funnelState = AppFunnelState.needsConnection;
  String? _errorMessage;

  List<Project> _projects = [];
  Project? _currentProject;
  List<KanbanColumn> _columns = [];
  bool _isLoadingProjects = false;
  bool _isLoadingTimeline = false;

  List<ACPProvider> _providers = [];
  String _defaultProviderId = 'gemini';
  String? _lastSelectedProviderId;

  String _currentView = 'board';
  bool _isSidebarExpanded = false;
  KanbanCard? _selectedCard;

  @override
  void initState() {
    super.initState();
    _initApp();
    _setupRefreshService();
  }

  void _setupRefreshService() {
    final refreshService = KanbanRefreshService();
    refreshService.addListener((_) {
      if (mounted && _currentProject != null) {
        _loadProjectData(_currentProject!.id);
      }
    });
  }

  void _refreshFunnelState() {
    if (!mounted) return;
    setState(() {
      if (_acpClient.activeMode == ConnectionPath.none) {
        _funnelState = AppFunnelState.needsConnection;
      } else if (_projects.isEmpty) {
        _funnelState = AppFunnelState.connectedNoProjects;
      } else if (_currentProject == null) {
        _funnelState = AppFunnelState.connectedNoProjects;
      } else if (_columns.isEmpty) {
        _funnelState = AppFunnelState.projectSelectedNoColumns;
      } else if (_cards.isEmpty) {
        _funnelState = AppFunnelState.columnsNoCards;
      } else {
        _funnelState = AppFunnelState.ready;
      }
    });
  }

  Future<void> _initApp() async {
    try {
      _acpClient.disconnect();

      final configManager = await ConnectionConfigManager.getInstance();
      final savedConfig = await configManager.loadConfig();
      _userId = savedConfig.userId;

      if (_userId == null ||
          _userId!.isEmpty ||
          savedConfig.relayToken == null ||
          savedConfig.relayToken!.isEmpty) {
        AppLogger.info('Missing credentials, redirecting to settings');
        if (mounted) {
          setState(() {
            _funnelState = AppFunnelState.needsConnection;
            _currentView = 'connection';
          });
          AppFeedback.showInfo(context, UICopy.configureCredentials);
        }
        return;
      }

      final acpConfig = ACPConfig.fromConnectionConfig(
        savedConfig,
        _userId!,
      );
      await _acpClient.smartConnect(acpConfig);

      if (_acpClient.activeUrl != null) {
        _projectService.updateBaseUrl(_acpClient.activeUrl!,
            apiToken: savedConfig.apiToken);
      }

      await _acpClient.initialize(acpConfig.systemConfig);

      // Phase 5.5: Hydrate system config from server after successful connection
      try {
        final serverSysConfig = await _projectService.getSystemConfig();
        if (serverSysConfig != null && serverSysConfig.containsKey('api_key')) {
          final updatedSysConfig = SystemProxyConfig.fromJson({
            'provider_id': 'openai',
            'api_key': serverSysConfig['api_key'],
            'base_url': serverSysConfig['base_url'],
            'summary_model': serverSysConfig['summary_model'],
            'embedding_model': serverSysConfig['embedding_model'],
          });

          final newConfig =
              savedConfig.copyWith(systemConfig: updatedSysConfig);
          await configManager.saveConfig(newConfig);
          AppLogger.info('System config hydrated from server');
        }
      } catch (e) {
        AppLogger.warning('Failed to hydrate system config from server', e);
      }

      await Future.wait([
        _loadProjects(),
        _loadProviders(),
      ]);

      _refreshFunnelState();
    } catch (e) {
      AppLogger.error('Init Error', e);
      if (mounted) {
        setState(() {
          _funnelState = AppFunnelState.error;
          _errorMessage = ErrorCopy.mapError(null, e.toString());
        });
      }
    }
  }

  void _openCardById(String cardId) {
    try {
      final card = _cards.firstWhere((c) => c.id == cardId);
      setState(() {
        _selectedCard = card;
        _currentView = 'card_detail';
      });
    } catch (e) {
      AppLogger.error('Card $cardId not found in local state', e);
      AppFeedback.showError(context, UICopy.cardNotFound);
    }
  }

  Future<void> _loadProviders() async {
    try {
      final data = await _projectService.getProviders();
      if (data != null) {
        final List<dynamic> providersJson = data['providers'] ?? [];
        final configManager = await ConnectionConfigManager.getInstance();
        final lastProvider = configManager.getLastProvider();
        if (mounted) {
          setState(() {
            _providers =
                providersJson.map((p) => ACPProvider.fromJson(p)).toList();
            _defaultProviderId = data['default_provider'] ?? 'gemini';
            _lastSelectedProviderId = lastProvider;
          });
        }
      }
    } catch (e) {
      AppLogger.error('Load providers error', e);
    }
  }

  Future<void> _addCard(KanbanColumn column) async {
    final titleController = TextEditingController();
    final descriptionController = TextEditingController();

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) {
        final size = MediaQuery.of(context).size;
        final isMobile = size.width < 600;
        return AlertDialog(
          title: Text('${UICopy.addCardTo} ${column.name}'),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppConstants.radiusMedium)),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: isMobile ? size.width * 0.95 : size.width * 0.8,
              maxHeight: isMobile ? size.height * 0.9 : size.height * 0.8,
            ),
            child: SizedBox(
              width: size.width * 0.9,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: titleController,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: UICopy.cardTitleLabel,
                        hintText: UICopy.enterCardTitle,
                      ),
                      maxLines: 1,
                    ),
                    const SizedBox(height: AppConstants.space24),
                    TextField(
                      controller: descriptionController,
                      decoration: const InputDecoration(
                        labelText: UICopy.projectDescription,
                        hintText: UICopy.enterCardDescription,
                      ),
                      maxLines: 8,
                      minLines: 4,
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text(UICopy.cancel)),
            ElevatedButton(
                onPressed: () {
                  if (titleController.text.trim().isEmpty) {
                    AppFeedback.showError(context, UICopy.titleRequired);
                    return;
                  }
                  Navigator.pop(context, {
                    'title': titleController.text.trim(),
                    'description': descriptionController.text.trim(),
                  });
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  shape: RoundedRectangleBorder(
                      borderRadius:
                          BorderRadius.circular(AppConstants.radiusSmall)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
                child: const Text(UICopy.addCard)),
          ],
        );
      },
    );

    if (result != null && result['title']!.isNotEmpty) {
      final card = await _projectService.createCard(
        column.id,
        result['title']!,
        description: result['description'],
      );
      if (card != null && _currentProject != null) {
        if (mounted) {
          await _loadProjectData(_currentProject!.id);
        }
      }
    }
  }

  Future<void> _loadProjects() async {
    setState(() => _isLoadingProjects = true);
    try {
      final projects = await _projectService.getProjects();
      projects.sort((a, b) {
        final aTime = DateTime.tryParse(a.updatedAt) ?? DateTime(0);
        final bTime = DateTime.tryParse(b.updatedAt) ?? DateTime(0);
        return bTime.compareTo(aTime);
      });

      if (mounted) {
        final configManager = await ConnectionConfigManager.getInstance();
        final lastProjectId = configManager.getLastProjectId();

        setState(() {
          _projects = projects;
          if (_currentProject == null && projects.isNotEmpty) {
            if (lastProjectId != null) {
              final lastProject = projects.firstWhere(
                (p) => p.id == lastProjectId,
                orElse: () => projects.first,
              );
              _currentProject = lastProject;
            } else {
              _currentProject = projects.first;
            }
          }
        });

        if (_currentProject != null) {
          final stillExists = projects.any((p) => p.id == _currentProject!.id);
          if (stillExists) {
            await _switchProject(_currentProject!);
          } else {
            setState(() =>
                _currentProject = projects.isNotEmpty ? projects.first : null);
            if (_currentProject != null) await _switchProject(_currentProject!);
          }
        }
      }
    } catch (e) {
      AppLogger.error('Load projects error', e);
    } finally {
      if (mounted) setState(() => _isLoadingProjects = false);
    }
  }

  Future<void> _loadProjectData(String projectId) async {
    try {
      final columns = await _projectService.getColumns(projectId);
      columns.sort((a, b) => a.position.compareTo(b.position));
      final List<KanbanCard> allCards = [];
      for (var col in columns) {
        final cards = await _projectService.getCardsByColumn(col.id,
            includeCompleted: true);
        allCards.addAll(cards);
      }
      if (mounted) {
        setState(() {
          _columns = columns;
          _cards = allCards..sort((a, b) => a.position.compareTo(b.position));
        });
        await _loadTimeline(projectId);
      }
    } catch (e) {
      AppLogger.error('Load project data error', e);
    }
  }

  Future<void> _loadTimeline(String projectId) async {
    setState(() => _isLoadingTimeline = true);
    try {
      final events = await _projectService.getTimeline(projectId);
      if (mounted) {
        setState(() {
          _timelineEvents = events;
          _updateAgentStatuses();
        });
      }
    } catch (e) {
      AppLogger.error('Load timeline error', e);
    } finally {
      if (mounted) setState(() => _isLoadingTimeline = false);
    }
  }

  Future<void> _updateAgentStatuses() async {
    if (_projects.isEmpty) return;
    try {
      final statuses = await _projectService.getAllProjectStatuses();
      if (!mounted) return;

      setState(() {
        _agentStatuses = statuses.map((s) {
          final project = _projects.firstWhere(
            (p) => p.id == s['project_id'],
            orElse: () => _projects.first,
          );
          return ProjectAgentStatus(
            project: project,
            state: _parseAgentState(s['state'] as String?),
            startTime: s['start_time'] != null
                ? DateTime.tryParse(s['start_time'] as String)
                : null,
            lastMessage: s['last_message'] as String?,
          );
        }).toList();
      });
    } catch (e) {
      AppLogger.error('Failed to update agent statuses', e);
    }
  }

  AgentState _parseAgentState(String? state) {
    switch (state) {
      case 'working':
        return AgentState.working;
      case 'needsAuthorization':
        return AgentState.needsAuthorization;
      case 'completed':
        return AgentState.completed;
      default:
        return AgentState.idle;
    }
  }

  Future<void> _switchProject(Project project) async {
    setState(() => _isLoadingProjects = true);
    try {
      final switchData = await _projectService.switchToProject(project.id);
      if (switchData != null && mounted) {
        setState(() {
          _currentProject = switchData.project;
          _columns = switchData.columns.map((c) => c.column).toList()
            ..sort((a, b) => a.position.compareTo(b.position));
          _cards = switchData.columns.expand((c) => c.cards).toList()
            ..sort((a, b) => a.position.compareTo(b.position));
          _timelineEvents = switchData.timeline;
        });
        _updateAgentStatuses();

        final configManager = await ConnectionConfigManager.getInstance();
        await configManager.setLastProjectId(project.id);

        await _loadProjectData(project.id);
      } else {
        await _loadProjectData(project.id);

        final configManager = await ConnectionConfigManager.getInstance();
        await configManager.setLastProjectId(project.id);
      }
    } catch (e) {
      AppLogger.error('Switch project error', e);
      await _loadProjectData(project.id);
    } finally {
      if (mounted) {
        setState(() => _isLoadingProjects = false);
      }
    }
  }

  Future<void> _onCardMoved(KanbanCard card, String targetColumnId,
      {int? targetPosition}) async {
    final oldColumnId = card.columnId;
    final oldPosition = card.position;

    int newPosition;
    final targetCards = _cards
        .where((c) => c.columnId == targetColumnId)
        .toList()
      ..sort((a, b) => a.position.compareTo(b.position));

    if (targetPosition != null) {
      newPosition = targetPosition;
    } else {
      if (targetCards.isEmpty) {
        newPosition = 0;
      } else {
        newPosition = targetCards.last.position + 1;
      }
    }

    setState(() {
      _cards.removeWhere((c) => c.id == card.id);

      for (var i = 0; i < _cards.length; i++) {
        if (_cards[i].columnId == oldColumnId &&
            _cards[i].position > oldPosition) {
          _cards[i] = _cards[i].copyWith(position: _cards[i].position - 1);
        }
      }

      for (var i = 0; i < _cards.length; i++) {
        if (_cards[i].columnId == targetColumnId &&
            _cards[i].position >= newPosition) {
          _cards[i] = _cards[i].copyWith(position: _cards[i].position + 1);
        }
      }

      _cards.add(card.copyWith(
        columnId: targetColumnId,
        position: newPosition,
      ));
      _cards.sort((a, b) => a.position.compareTo(b.position));
    });

    final success =
        await _projectService.moveCard(card.id, targetColumnId, newPosition);
    if (!success && mounted) {
      await _loadProjectData(_currentProject!.id);
      AppFeedback.showError(context, UICopy.failedToMoveCard);
    } else if (mounted) {
      await _loadProjectData(_currentProject!.id);
      KanbanRefreshService().markNeedsRefresh(RefreshSource.cardMoved);
    }
  }

  Future<void> _onColumnReordered(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    setState(() {
      final KanbanColumn item = _columns.removeAt(oldIndex);
      _columns.insert(newIndex, item);
    });

    if (_currentProject != null) {
      await _projectService.reorderColumns(_currentProject!.id, _columns);
    }
  }

  Future<void> _createProject(String name, String? workspacePath,
      {String? description}) async {
    final project = await _projectService.createProject(
      name,
      workspacePath: workspacePath,
      description: description,
    );
    if (project != null && mounted) {
      setState(() {
        _projects.add(project);
        _currentProject = project;
      });
      await _switchProject(project);
    }
  }

  Future<void> _handleProjectUpdate(Project project, String name, String? path,
      {String? description}) async {
    final isDuplicate = _projects.any((p) =>
        p.name.toLowerCase() == name.toLowerCase() && p.id != project.id);

    if (isDuplicate) {
      AppFeedback.showError(context, UICopy.projectNameUnique);
      return;
    }

    final updatedProject = await _projectService.updateProject(
      project.id,
      name: name,
      workspacePath: path,
      description: description,
    );
    if (updatedProject != null && mounted) {
      setState(() {
        final index = _projects.indexWhere((p) => p.id == project.id);
        if (index != -1) {
          _projects[index] = updatedProject;
          if (_currentProject?.id == project.id) {
            _currentProject = updatedProject;
          }
        }
        _projects.sort((a, b) {
          final aTime = DateTime.tryParse(a.updatedAt) ?? DateTime(0);
          final bTime = DateTime.tryParse(b.updatedAt) ?? DateTime(0);
          return bTime.compareTo(aTime);
        });
      });
      AppFeedback.showSuccess(context, UICopy.projectUpdated);
    }
  }

  void _showProjectManager() {
    showDialog(
      context: context,
      builder: (context) => ProjectManagementDialog(
        projects: _projects,
        currentProject: _currentProject,
        onUpdate: (project, name, path, {description}) =>
            _handleProjectUpdate(project, name, path, description: description),
        onDelete: (project) async {
          final success = await _projectService.deleteProject(project.id);
          if (success && mounted) {
            final isCurrent = _currentProject?.id == project.id;
            setState(() {
              _projects.removeWhere((p) => p.id == project.id);
              if (isCurrent) {
                _currentProject = null;
                _columns = [];
                _cards = [];
                _timelineEvents = [];
              }
            });
            AppFeedback.showSuccess(context,
                '${UICopy.projectDescription} "${project.name}" ${UICopy.cardDeleted}');
          }
        },
      ),
    );
  }

  void _showColumnManager() {
    if (_currentProject == null) return;
    showDialog(
      context: context,
      builder: (context) => ColumnManagerDialog(
        projectId: _currentProject!.id,
        columns: _columns,
        onUpdated: () => _loadProjectData(_currentProject!.id),
      ),
    );
  }

  Future<void> _showAddColumnDialog() async {
    if (_currentProject == null) return;
    try {
      final result = await showDialog<ColorEditResult>(
        context: context,
        builder: (context) =>
            AddColumnDialog(existingColumnCount: _columns.length),
      );
      if (result != null) {
        await _projectService.createColumn(
          _currentProject!.id,
          result.name,
          color: result.color,
          promptTemplate: result.promptTemplate,
          acpProviderId: result.acpProviderId,
        );
        _loadProjectData(_currentProject!.id);
      }
    } catch (_) {
      _showColumnManager();
    }
  }

  void _showCreateProjectDialog() {
    showDialog(
      context: context,
      builder: (context) => ProjectCreationDialog(
        onCreate: (name, workspacePath, description) {
          Navigator.pop(context);
          _createProject(name, workspacePath, description: description);
        },
      ),
    );
  }

  void _showRoadmapManager() {
    if (_currentProject == null) return;
    showDialog(
      context: context,
      builder: (context) => RoadmapManagerDialog(
        projectId: _currentProject!.id,
      ),
    ).then((_) {
      if (_currentProject != null) {
        _loadProjectData(_currentProject!.id);
      }
    });
  }

  int _viewToIndex(String view) {
    switch (view) {
      case 'board':
        return 0;
      case 'roadmap':
        return 1;
      case 'timeline':
        return 2;
      case 'connection':
        return 3;
      default:
        return 0;
    }
  }

  String _indexToView(int index) {
    switch (index) {
      case 0:
        return 'board';
      case 1:
        return 'roadmap';
      case 2:
        return 'timeline';
      case 3:
        return 'connection';
      default:
        return 'board';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final size = MediaQuery.of(context).size;
    final isMobile = size.width < 600;

    final showBottomNav = isMobile && _currentView != 'card_detail';

    return Scaffold(
      appBar: AppBar(
        title: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              const Text(UICopy.appTitle),
              const SizedBox(width: 8),
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _getStatusDotColor(),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: _getStatusDotColor().withOpacity(0.4),
                      blurRadius: 4,
                      spreadRadius: 1,
                    )
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Text(
                _acpClient.activeMode.name.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: UICopy.refreshTooltip,
            onPressed: () async {
              await _loadProjects();
              if (_currentProject != null) {
                await _loadProjectData(_currentProject!.id);
              }
              if (mounted) {
                AppFeedback.showSuccess(context, UICopy.dataRefreshed);
              }
            },
          ),
          IconButton(
            icon: Icon(ThemeService().isDarkMode
                ? Icons.light_mode_outlined
                : Icons.dark_mode_outlined),
            tooltip: UICopy.toggleTheme,
            onPressed: () => ThemeService().toggleTheme(),
          ),
        ],
      ),
      body: Row(
        children: [
          if (!isMobile) ...[
            _buildSidebar(theme, colorScheme),
            const VerticalDivider(width: 1),
          ],
          Expanded(
            child: _buildMainContent(theme, colorScheme),
          ),
        ],
      ),
      bottomNavigationBar:
          showBottomNav ? _buildBottomNavigationBar(theme, colorScheme) : null,
    );
  }

  Widget _buildBottomNavigationBar(ThemeData theme, ColorScheme colorScheme) {
    return BottomNavigationBar(
      type: BottomNavigationBarType.fixed,
      currentIndex: _viewToIndex(_currentView),
      onTap: (idx) {
        setState(() {
          _currentView = _indexToView(idx);
          _selectedCard = null;
        });
      },
      selectedItemColor: colorScheme.primary,
      unselectedItemColor:
          colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis),
      showUnselectedLabels: true,
      selectedLabelStyle:
          const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
      unselectedLabelStyle: const TextStyle(fontSize: 12),
      items: [
        const BottomNavigationBarItem(
          icon: Icon(Icons.dashboard_rounded),
          label: UICopy.board,
        ),
        const BottomNavigationBarItem(
          icon: Icon(Icons.alt_route_rounded),
          label: UICopy.roadmap,
        ),
        const BottomNavigationBarItem(
          icon: Icon(Icons.history_rounded),
          label: UICopy.timeline,
        ),
        BottomNavigationBarItem(
          icon: Stack(
            children: [
              const Icon(Icons.settings_outlined),
              Positioned(
                right: 0,
                top: 0,
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: _getStatusDotColor(),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ),
          label: UICopy.connection,
        ),
      ],
    );
  }

  Widget _buildMainContent(ThemeData theme, ColorScheme colorScheme) {
    if (_currentView == 'connection') {
      return ConnectionSettingsView(
        acpClient: _acpClient,
        currentMode: _getCurrentConnectionMode(),
        userId: _userId ?? 'test_user',
        onConnectionChanged: (newMode, url) async {
          await _initApp();
        },
      );
    }

    if (_currentView == 'card_detail' &&
        _selectedCard != null &&
        _currentProject != null) {
      return CardDetailView(
        card: _selectedCard!,
        projectId: _currentProject!.id,
        onBack: () => setState(() {
          _currentView = 'board';
          _selectedCard = null;
          KanbanRefreshService().markNeedsRefresh(RefreshSource.manual);
        }),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppConstants.space16,
              vertical: AppConstants.space8),
          child: Row(
            children: [
              Flexible(
                child: ProjectSelector(
                  currentProject: _currentProject,
                  projects: _projects,
                  onProjectSelected: _switchProject,
                  onCreateProject: _showCreateProjectDialog,
                  onManageProjects: _showProjectManager,
                  isLoading: _isLoadingProjects,
                ),
              ),
              if (_currentProject != null) ...[
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: _showColumnManager,
                  icon: const Icon(Icons.view_column_rounded, size: 18),
                  label: const Text(UICopy.manageColumns),
                ),
              ],
            ],
          ),
        ),
        StatusSummaryWidget(statuses: _agentStatuses),
        Expanded(
          child: _currentView == 'board'
              ? _buildBoardView()
              : _currentView == 'roadmap'
                  ? ProjectRoadmapView(
                      projectId: _currentProject!.id,
                      onCardTap: _openCardById,
                      onManageTap: _showRoadmapManager,
                    )
                  : TimelineView(
                      events: _timelineEvents,
                      isLoading: _isLoadingTimeline,
                      onRefresh: () {
                        if (_currentProject != null) {
                          _loadTimeline(_currentProject!.id);
                        }
                      },
                    ),
        ),
      ],
    );
  }

  Widget _buildSidebar(ThemeData theme, ColorScheme colorScheme) {
    return NavigationRail(
      extended: _isSidebarExpanded,
      backgroundColor: theme.scaffoldBackgroundColor,
      unselectedIconTheme: IconThemeData(
          color:
              colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis)),
      selectedIconTheme: IconThemeData(color: colorScheme.primary),
      unselectedLabelTextStyle: theme.textTheme.bodySmall?.copyWith(
        color: colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis),
      ),
      selectedLabelTextStyle: theme.textTheme.bodySmall?.copyWith(
        color: colorScheme.primary,
        fontWeight: FontWeight.bold,
      ),
      leading: Column(
        children: [
          const SizedBox(height: 8),
          IconButton(
            icon: Icon(_isSidebarExpanded
                ? Icons.menu_open_rounded
                : Icons.menu_rounded),
            onPressed: () =>
                setState(() => _isSidebarExpanded = !_isSidebarExpanded),
            tooltip: _isSidebarExpanded
                ? UICopy.collapseSidebar
                : UICopy.expandSidebar,
          ),
          if (_isSidebarExpanded) ...[
            const SizedBox(height: 16),
            Icon(Icons.psychology_rounded,
                size: 32, color: colorScheme.primary),
            const SizedBox(height: 8),
            Text(UICopy.appTitle,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.bold,
                )),
            const SizedBox(height: 24),
          ],
        ],
      ),
      destinations: [
        const NavigationRailDestination(
          icon: Icon(Icons.dashboard_rounded),
          selectedIcon: Icon(Icons.dashboard_rounded),
          label: Text(UICopy.board),
        ),
        const NavigationRailDestination(
          icon: Icon(Icons.alt_route_rounded),
          selectedIcon: Icon(Icons.alt_route_rounded),
          label: Text(UICopy.roadmap),
        ),
        const NavigationRailDestination(
          icon: Icon(Icons.history_rounded),
          selectedIcon: Icon(Icons.history_rounded),
          label: Text(UICopy.timeline),
        ),
        NavigationRailDestination(
          icon: Stack(
            children: [
              const Icon(Icons.settings_outlined),
              Positioned(
                right: 0,
                top: 0,
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: _getStatusDotColor(),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ),
          label: const Text(UICopy.connection),
        ),
      ],
      selectedIndex: _viewToIndex(_currentView),
      onDestinationSelected: (idx) {
        setState(() {
          _currentView = _indexToView(idx);
          _selectedCard = null;
        });
      },
      trailing: Expanded(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (_isSidebarExpanded)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(UICopy.appVersion,
                    style: theme.textTheme.bodySmall?.copyWith(fontSize: 10)),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Color _getStatusDotColor() {
    final customColors = Theme.of(context).extension<CustomColors>()!;
    if (_acpClient.activeMode == ConnectionPath.local) {
      return customColors.success!;
    } else if (_acpClient.activeMode == ConnectionPath.relay) {
      return customColors.warning!;
    } else if (_acpClient.activeMode == ConnectionPath.cloud) {
      return customColors.info!;
    } else {
      return Theme.of(context).colorScheme.error;
    }
  }

  ConnectionMode _getCurrentConnectionMode() {
    if (_acpClient.activeMode == ConnectionPath.local) {
      return ConnectionMode.local;
    } else if (_acpClient.activeMode == ConnectionPath.relay) {
      return ConnectionMode.relay;
    } else if (_acpClient.activeMode == ConnectionPath.cloud) {
      return ConnectionMode.cloud;
    } else {
      return ConnectionMode.local;
    }
  }

  Widget _buildBoardView() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (_isLoadingProjects && _columns.isEmpty) {
      return AppStateView.loading();
    }

    switch (_funnelState) {
      case AppFunnelState.needsConnection:
        return AppStateView.empty(
          icon: Icons.link_off_rounded,
          message: UICopy.connectionRequired,
          action: FilledButton.icon(
            onPressed: () => setState(() => _currentView = 'connection'),
            icon: const Icon(Icons.settings_rounded),
            label: const Text(UICopy.openSettings),
          ),
        );

      case AppFunnelState.connectedNoProjects:
        return AppStateView.empty(
          icon: Icons.folder_off_rounded,
          message: UICopy.noProjectSelected,
          action: FilledButton.icon(
            onPressed: _showCreateProjectDialog,
            icon: const Icon(Icons.add_rounded),
            label: const Text(UICopy.createProject),
          ),
        );

      case AppFunnelState.projectSelectedNoColumns:
        return AppStateView.empty(
          icon: Icons.view_column_outlined,
          message: UICopy.noColumnsFound,
          action: FilledButton.icon(
            onPressed: _showAddColumnDialog,
            icon: const Icon(Icons.add_rounded),
            label: const Text(UICopy.addColumn),
          ),
        );

      case AppFunnelState.columnsNoCards:
        return AppStateView.empty(
          icon: Icons.note_add_outlined,
          message: UICopy.noCardsYet,
          action: FilledButton.icon(
            onPressed: () => _addCard(_columns.first),
            icon: const Icon(Icons.add_task_rounded),
            label: const Text(UICopy.addFirstCard),
          ),
        );

      case AppFunnelState.error:
        return AppStateView.error(
          message: _errorMessage ?? UICopy.unknownErrorOccurred,
          onRetry: _initApp,
        );

      case AppFunnelState.ready:
        if (_columns.isEmpty) {
          return AppStateView.empty(
            icon: Icons.view_column_outlined,
            message: UICopy.noColumnsFound,
            action: FilledButton.icon(
              onPressed: _showAddColumnDialog,
              icon: const Icon(Icons.add_rounded),
              label: const Text(UICopy.addColumn),
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: () async {
            await _loadProjectData(_currentProject!.id);
          },
          child: ReorderableListView.builder(
            key: PageStorageKey('board_list_${_currentProject?.id}'),
            scrollDirection: Axis.horizontal,
            padding:
                const EdgeInsets.symmetric(horizontal: AppConstants.space8),
            itemCount: _columns.length,
            onReorder: _onColumnReordered,
            itemBuilder: (context, index) {
              final column = _columns[index];
              final columnCards =
                  _cards.where((c) => c.columnId == column.id).toList();
              return KanbanColumnWidget(
                key: ValueKey(column.id),
                column: column,
                cards: columnCards,
                onCardTap: (card) => _openCardById(card.id),
                onCardSessionTap: (card) => _openCardById(card.id),
                onAddCard: () => _addCard(column),
                onCardMoved: _onCardMoved,
                onCardComplete: (card) async {
                  final updated = await _projectService.completeCard(card.id);
                  if (updated != null) {
                    _loadProjectData(_currentProject!.id);
                    if (mounted) {
                      AppFeedback.showSuccess(context, UICopy.cardCompleted);
                    }
                  }
                },
                onCardUncomplete: (card) async {
                  final updated = await _projectService.uncompleteCard(card.id);
                  if (updated != null) {
                    _loadProjectData(_currentProject!.id);
                    if (mounted) {
                      AppFeedback.showSuccess(context, UICopy.cardReactivated);
                    }
                  }
                },
                onCardDelete: (card) async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text(UICopy.deleteCard),
                      content: const Text(UICopy.confirmDeleteCard),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text(UICopy.cancel)),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: Text(UICopy.delete,
                              style: TextStyle(color: colorScheme.error)),
                        ),
                      ],
                    ),
                  );

                  if (confirmed == true) {
                    final success = await _projectService.deleteCard(card.id);
                    if (success) {
                      _loadProjectData(_currentProject!.id);
                      if (mounted) {
                        AppFeedback.showSuccess(context, UICopy.cardDeleted);
                      }
                    }
                  }
                },
              );
            },
          ),
        );
    }
  }
}
