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
import 'services/theme_service.dart';

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
            if (!currentFocus.hasPrimaryFocus && currentFocus.focusedChild != null) {
              FocusManager.instance.primaryFocus?.unfocus();
            }
          },
          child: MaterialApp(
            title: 'AI Kanban',
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

  // Project state
  List<Project> _projects = [];
  Project? _currentProject;
  List<KanbanColumn> _columns = [];
  bool _isLoadingProjects = false;
  bool _isLoadingTimeline = false;

  // Provider state
  List<ACPProvider> _providers = [];
  String _defaultProviderId = 'gemini';
  String? _lastSelectedProviderId;

  // View state
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
    refreshService.addRefreshListener(() {
      if (mounted && _currentProject != null) {
        _loadProjectData(_currentProject!.id);
      }
    });
  }

  Future<void> _initApp() async {
    try {
      final configManager = await ConnectionConfigManager.getInstance();
      final savedConfig = await configManager.loadConfig();
      _userId = savedConfig.userId;

      final acpConfig = ACPConfig.fromConnectionConfig(
        savedConfig,
        _userId ?? 'test_user',
      );
      await _acpClient.smartConnect(acpConfig);
      
      if (_acpClient.activeUrl != null) {
        _projectService.updateBaseUrl(_acpClient.activeUrl!);
      }
      
      await _acpClient.initialize(acpConfig.systemConfig);

      await Future.wait([
        _loadProjects(),
        _loadProviders(),
      ]);
    } catch (e) {
      debugPrint('Init Error: $e');
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
      debugPrint('Card $cardId not found in local state: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Card not found in current project view')),
      );
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
      debugPrint('Load providers error: $e');
    }
  }

  Future<void> _addCard(KanbanColumn column) async {
    final titleController = TextEditingController();
    final descriptionController = TextEditingController();

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) {
        final size = MediaQuery.of(context).size;
        return AlertDialog(
          title: Text('Add Card to ${column.name}'),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusMedium)),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 450,
              maxHeight: size.height * 0.7,
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
                        labelText: 'Title *',
                        hintText: 'Enter card title',
                      ),
                      maxLines: 1,
                    ),
                    const SizedBox(height: AppConstants.space16),
                    TextField(
                      controller: descriptionController,
                      decoration: const InputDecoration(
                        labelText: 'Description',
                        hintText: 'Enter card description',
                      ),
                      maxLines: 4,
                      minLines: 2,
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            ElevatedButton(
                onPressed: () {
                  if (titleController.text.trim().isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Title is required')),
                    );
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
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusSmall)),
                ),
                child: const Text('Add')),
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
      debugPrint('Load projects error: $e');
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
        final cards = await _projectService.getCardsByColumn(col.id, includeCompleted: true);
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
      debugPrint('Load project data error: $e');
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
      debugPrint('Load timeline error: $e');
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
      debugPrint('Failed to update agent statuses: $e');
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
        
        // Save last project ID
        final configManager = await ConnectionConfigManager.getInstance();
        await configManager.setLastProjectId(project.id);
      } else {
        await _loadProjectData(project.id);
        
        // Even if full switch data failed, if we loaded columns/cards, we consider it the active project
        final configManager = await ConnectionConfigManager.getInstance();
        await configManager.setLastProjectId(project.id);
      }
    } catch (e) {
      debugPrint('Switch project error: $e');
      await _loadProjectData(project.id);
    } finally {
      if (mounted) {
        setState(() => _isLoadingProjects = false);
      }
    }
  }

  Future<void> _onCardMoved(KanbanCard card, String targetColumnId, {int? targetPosition}) async {
    final oldColumnId = card.columnId;
    final oldPosition = card.position;
    
    int newPosition;
    final targetCards = _cards.where((c) => c.columnId == targetColumnId).toList()
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
      
      // If moving within the same column, we need to handle the shift carefully
      // First, normalize the current column by removing the gap left by the card
      for (var i = 0; i < _cards.length; i++) {
        if (_cards[i].columnId == oldColumnId && _cards[i].position > oldPosition) {
          _cards[i] = _cards[i].copyWith(position: _cards[i].position - 1);
        }
      }
      
      // If the targetPosition was based on a card that shifted, we should adjust it
      // However, if we pass the target card's position value from the UI, we don't need to adjust.
      
      // Shift cards in the target column to make room for the new card
      for (var i = 0; i < _cards.length; i++) {
        if (_cards[i].columnId == targetColumnId && _cards[i].position >= newPosition) {
          _cards[i] = _cards[i].copyWith(position: _cards[i].position + 1);
        }
      }
      
      _cards.add(card.copyWith(
        columnId: targetColumnId,
        position: newPosition,
      ));
      _cards.sort((a, b) => a.position.compareTo(b.position));
    });

    final success = await _projectService.moveCard(card.id, targetColumnId, newPosition);
    if (!success && mounted) {
      await _loadProjectData(_currentProject!.id);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to move card')),
      );
    } else if (mounted) {
      await _loadProjectData(_currentProject!.id);
      KanbanRefreshService().markNeedsRefresh();
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

  Future<void> _createProject(String name, String? workspacePath, {String? description}) async {
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

  Future<void> _handleProjectUpdate(
      Project project, String name, String? path, {String? description}) async {
    final isDuplicate = _projects.any(
        (p) => p.name.toLowerCase() == name.toLowerCase() && p.id != project.id);

    if (isDuplicate) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Project name must be unique')),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Project "${project.name}" updated')),
      );
    }
  }

  void _showProjectManager() {
    showDialog(
      context: context,
      builder: (context) => ProjectManagementDialog(
        projects: _projects,
        currentProject: _currentProject,
        onUpdate: (project, name, path, {description}) => _handleProjectUpdate(project, name, path, description: description),
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
            
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Project "${project.name}" deleted')),
            );
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
      case 'board': return 0;
      case 'roadmap': return 1;
      case 'timeline': return 2;
      case 'connection': return 3;
      default: return 0;
    }
  }

  String _indexToView(int index) {
    switch (index) {
      case 0: return 'board';
      case 1: return 'roadmap';
      case 2: return 'timeline';
      case 3: return 'connection';
      default: return 'board';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final size = MediaQuery.of(context).size;
    final isMobile = size.width < 600;

    // Determine if we should show the bottom navigation bar
    // Hide it on desktop or when viewing card details on mobile
    final showBottomNav = isMobile && _currentView != 'card_detail';

    return Scaffold(
      appBar: AppBar(
        title: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              const Text('AI Kanban'),
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
          if (_currentProject != null && !isMobile) ...[
            IconButton(
              icon: const Icon(Icons.alt_route_rounded),
              tooltip: 'Project Roadmap',
              onPressed: _showRoadmapManager,
            ),
            IconButton(
              icon: const Icon(Icons.view_column_outlined),
              tooltip: 'Manage Columns',
              onPressed: _showColumnManager,
            ),
            IconButton(
              icon: const Icon(Icons.settings_suggest_outlined),
              tooltip: 'Manage Projects',
              onPressed: _showProjectManager,
            ),
          ],
          IconButton(
            icon: Icon(ThemeService().isDarkMode
                ? Icons.light_mode_outlined
                : Icons.dark_mode_outlined),
            tooltip: 'Toggle Theme',
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
      bottomNavigationBar: showBottomNav ? _buildBottomNavigationBar(theme, colorScheme) : null,
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
      unselectedItemColor: colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis),
      showUnselectedLabels: true,
      selectedLabelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
      unselectedLabelStyle: const TextStyle(fontSize: 12),
      items: [
        const BottomNavigationBarItem(
          icon: Icon(Icons.dashboard_rounded),
          label: 'Board',
        ),
        const BottomNavigationBarItem(
          icon: Icon(Icons.alt_route_rounded),
          label: 'Roadmap',
        ),
        const BottomNavigationBarItem(
          icon: Icon(Icons.history_rounded),
          label: 'Timeline',
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
          label: 'Connection',
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
          final configManager = await ConnectionConfigManager.getInstance();
          final savedConfig = await configManager.loadConfig();
          if (mounted) {
            setState(() {
              _userId = savedConfig.userId;
            });
            _loadProjects();
          }
        },
      );
    }

    if (_currentView == 'card_detail' && _selectedCard != null && _currentProject != null) {
      return CardDetailView(
        card: _selectedCard!,
        projectId: _currentProject!.id,
        onBack: () => setState(() {
          _currentView = 'board';
          _selectedCard = null;
          KanbanRefreshService().markNeedsRefresh();
        }),
      );
    }

    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppConstants.space16, vertical: AppConstants.space8),
            child: ProjectSelector(
              currentProject: _currentProject,
              projects: _projects,
              onProjectSelected: _switchProject,
              onCreateProject: _showCreateProjectDialog,
              onManageProjects: _showProjectManager,
              isLoading: _isLoadingProjects,
            ),
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
      unselectedIconTheme: IconThemeData(color: colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis)),
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
            icon: Icon(_isSidebarExpanded ? Icons.menu_open_rounded : Icons.menu_rounded),
            onPressed: () => setState(() => _isSidebarExpanded = !_isSidebarExpanded),
            tooltip: _isSidebarExpanded ? 'Collapse Sidebar' : 'Expand Sidebar',
          ),
          if (_isSidebarExpanded) ...[
            const SizedBox(height: 16),
            Icon(Icons.psychology_rounded, size: 32, color: colorScheme.primary),
            const SizedBox(height: 8),
            Text('AI Kanban', 
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
          label: Text('Board'),
        ),
        const NavigationRailDestination(
          icon: Icon(Icons.alt_route_rounded),
          selectedIcon: Icon(Icons.alt_route_rounded),
          label: Text('Roadmap'),
        ),
        const NavigationRailDestination(
          icon: Icon(Icons.history_rounded),
          selectedIcon: Icon(Icons.history_rounded),
          label: Text('Timeline'),
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
          label: const Text('Connection'),
        ),
      ],
      selectedIndex: _viewToIndex(_currentView),
      onDestinationSelected: (idx) {
        setState(() {
          _currentView = _indexToView(idx);
          _selectedCard = null; // Clear card when navigating via sidebar
        });
      },
      trailing: Expanded(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (_isSidebarExpanded)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('v1.2.0', style: theme.textTheme.bodySmall?.copyWith(fontSize: 10)),
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

    if (_currentProject == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder_off_rounded, size: 64, color: colorScheme.onSurface.withOpacity(AppConstants.disabledOpacity)),
            const SizedBox(height: AppConstants.space16),
            Text('No project selected', style: theme.textTheme.bodyLarge),
            const SizedBox(height: AppConstants.space8),
            FilledButton.icon(
              onPressed: _showCreateProjectDialog,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Create Project'),
            ),
          ],
        ),
      );
    }

    if (_isLoadingProjects && _columns.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_columns.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('No columns found for this project.', style: theme.textTheme.bodyMedium),
            const SizedBox(height: AppConstants.space8),
            TextButton.icon(
              onPressed: () => _loadProjectData(_currentProject!.id),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async {
        await _loadProjectData(_currentProject!.id);
      },
      child: ReorderableListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppConstants.space8),
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
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Card "${card.title}" completed')),
                  );
                }
              }
            },
            onCardUncomplete: (card) async {
              final updated = await _projectService.uncompleteCard(card.id);
              if (updated != null) {
                _loadProjectData(_currentProject!.id);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Card "${card.title}" reactivated')),
                  );
                }
              }
            },
            onCardDelete: (card) async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Delete Card'),
                  content: Text('Are you sure you want to delete "${card.title}"?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true), 
                      child: Text('Delete', style: TextStyle(color: colorScheme.error)),
                    ),
                  ],
                ),
              );

              if (confirmed == true) {
                final success = await _projectService.deleteCard(card.id);
                if (success) {
                  _loadProjectData(_currentProject!.id);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Card "${card.title}" deleted')),
                    );
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
