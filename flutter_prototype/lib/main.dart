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
import 'models/timeline_event.dart';
import 'utils/icon_util.dart';

void main() {
  runApp(const KanbanApp());
}

class KanbanApp extends StatelessWidget {
  const KanbanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Kanban',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const MainScreen(),
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
      await _acpClient.initialize(acpConfig.systemConfig);

      // Load projects and providers in parallel to avoid blocking UI
      await Future.wait([
        _loadProjects(),
        _loadProviders(),
      ]);
    } catch (e) {
      debugPrint('Init Error: $e');
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
          debugPrint(
              'Loaded ${_providers.length} providers, default: $_defaultProviderId, last: $_lastSelectedProviderId');
        }
      }
    } catch (e) {
      debugPrint('Load providers error: $e');
    }
  }

  Future<void> _addCard(KanbanColumn column) async {
    final titleController = TextEditingController();
    final descriptionController = TextEditingController();
    String selectedProviderId = _lastSelectedProviderId ?? _defaultProviderId;

    // If _providers is still loading, try loading it now
    if (_providers.isEmpty) {
      await _loadProviders();
    }

    final showProviderSelector = _providers.length > 1;

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Add Card to ${column.name}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Title *',
                  hintText: 'Enter card title',
                  border: OutlineInputBorder(),
                ),
                maxLines: 1,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                  hintText: 'Enter card description',
                  border: OutlineInputBorder(),
                ),
                maxLines: 4,
                minLines: 2,
              ),
              if (showProviderSelector) ...[
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  value: selectedProviderId,
                  decoration: const InputDecoration(
                    labelText: 'AI Provider',
                    border: OutlineInputBorder(),
                  ),
                  items: _providers.map((p) {
                    return DropdownMenuItem(
                      value: p.id,
                      child: Row(
                        children: [
                          Icon(
                            IconUtil.getProviderIcon(p.icon),
                            size: 18,
                            color: Theme.of(context).primaryColor,
                          ),
                          const SizedBox(width: 8),
                          Text(p.name),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) selectedProviderId = value;
                  },
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
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
                  'provider_id': selectedProviderId,
                });
              },
              child: const Text('Add')),
        ],
      ),
    );

    if (result != null && result['title']!.isNotEmpty) {
      final card = await _projectService.createCard(
        column.id,
        result['title']!,
        description: result['description'],
        acpProviderId: result['provider_id'],
      );
      if (card != null && _currentProject != null) {
        final configManager = await ConnectionConfigManager.getInstance();
        configManager.setLastProvider(result['provider_id']!);
        if (mounted) {
          setState(() {
            _lastSelectedProviderId = result['provider_id'];
          });
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
        setState(() {
          _projects = projects;
          if (_currentProject == null && projects.isNotEmpty) {
            _currentProject = projects.first;
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
        final cards = await _projectService.getCardsByColumn(col.id);
        allCards.addAll(cards);
      }
      if (mounted) {
        setState(() {
          _columns = columns;
          _cards = allCards;
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
          // Mock status updates for demo
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
          _cards = switchData.columns.expand((c) => c.cards).toList();
          _timelineEvents = switchData.timeline;
        });
        _updateAgentStatuses();
      } else {
        await _loadProjectData(project.id);
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

  Future<void> _onCardMoved(KanbanCard card, String targetColumnId) async {
    final oldColumnId = card.columnId;
    final targetCards =
        _cards.where((c) => c.columnId == targetColumnId).toList();
    final newPosition = targetCards.length;

    // Optimistic update
    setState(() {
      _cards = _cards.map((c) {
        if (c.id == card.id) {
          return c.copyWith(columnId: targetColumnId, position: newPosition);
        }
        return c;
      }).toList();
    });

    final success =
        await _projectService.moveCard(card.id, targetColumnId, newPosition);
    if (!success && mounted) {
      // Revert on failure
      setState(() {
        _cards = _cards.map((c) {
          if (c.id == card.id) {
            return c.copyWith(columnId: oldColumnId, position: card.position);
          }
          return c;
        }).toList();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to move card')),
      );
    } else {
      // Trigger refresh on success
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

  Future<void> _createProject(String name, String? workspacePath) async {
    final project = await _projectService.createProject(
      name,
      workspacePath: workspacePath,
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
      Project project, String name, String? path) async {
    // Check for unique name (excluding current project)
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
        // Re-sort after update
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
        onUpdate: (project, name, path) => _handleProjectUpdate(project, name, path),
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
        onCreate: (name, workspacePath) {
          Navigator.pop(context);
          _createProject(name, workspacePath);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              const Text('AI Kanban'),
              const SizedBox(width: 6),
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: _getStatusDotColor(),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                _acpClient.activeMode.name.toUpperCase(),
                style:
                    const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        actions: [
          if (_currentProject != null) ...[
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
        ],
      ),
      drawer: _buildDrawer(),
      body: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
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
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              color: Theme.of(context).primaryColor,
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Icon(Icons.psychology, size: 48, color: Colors.white),
                SizedBox(height: 8),
                Text(
                  'AI Kanban',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.dashboard),
            title: const Text('Board'),
            selected: _currentView == 'board',
            onTap: () {
              setState(() => _currentView = 'board');
              Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Timeline'),
            selected: _currentView == 'timeline',
            onTap: () {
              setState(() => _currentView = 'timeline');
              Navigator.pop(context);
            },
          ),
          const Divider(),
          ListTile(
            leading: Icon(_getStatusIcon()),
            title: const Text('Connection'),
            subtitle: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _getStatusDotColor(),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(_acpClient.activeMode.name.toUpperCase()),
              ],
            ),
            onTap: () {
              Navigator.pop(context);
              _openConnectionSettings();
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text('Settings'),
            onTap: () {
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }

  IconData _getStatusIcon() {
    switch (_acpClient.activeMode) {
      case ConnectionPath.local:
        return Icons.home;
      case ConnectionPath.relay:
        return Icons.cloud;
      case ConnectionPath.cloud:
        return Icons.public;
      default:
        return Icons.cloud_off;
    }
  }

  Color _getStatusDotColor() {
    switch (_acpClient.activeMode) {
      case ConnectionPath.local:
        return Colors.green;
      case ConnectionPath.relay:
        return Colors.orange;
      case ConnectionPath.cloud:
        return Colors.blue;
      default:
        return Colors.red;
    }
  }

  void _openConnectionSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ConnectionSettingsScreen(
          acpClient: _acpClient,
          currentMode: _getCurrentConnectionMode(),
          userId: _userId ?? 'test_user',
          onConnectionChanged: (newMode, url) {
            setState(() {});
          },
        ),
      ),
    );
  }

  ConnectionMode _getCurrentConnectionMode() {
    switch (_acpClient.activeMode) {
      case ConnectionPath.local:
        return ConnectionMode.local;
      case ConnectionPath.relay:
        return ConnectionMode.relay;
      case ConnectionPath.cloud:
        return ConnectionMode.cloud;
      default:
        return ConnectionMode.local;
    }
  }

  Widget _buildBoardView() {
    if (_currentProject == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.folder_off, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('No project selected'),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _showCreateProjectDialog,
              icon: const Icon(Icons.add),
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
            const Text('No columns found for this project.'),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => _loadProjectData(_currentProject!.id),
              icon: const Icon(Icons.refresh),
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
        padding: const EdgeInsets.symmetric(horizontal: 8),
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
            onCardTap: (card) {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => CardDetailScreen(
                    card: card,
                    projectId: _currentProject!.id,
                    workspacePath: _currentProject?.workspacePath,
                    acpClient: _acpClient,
                    providers: _providers,
                  ),
                  ),
                  ).then((_) {
                  // Refresh when returning from card detail
                  KanbanRefreshService().markNeedsRefresh();
                  });
                  },
                  onCardSessionTap: (card) {
                  // Now both taps go to the same Unified Task Hub
                  Navigator.push(
                  context,
                  MaterialPageRoute(
                  builder: (context) => CardDetailScreen(
                    card: card,
                    projectId: _currentProject!.id,
                    workspacePath: _currentProject?.workspacePath,
                    acpClient: _acpClient,
                    providers: _providers,
                  ),
                  ),              ).then((_) {
                KanbanRefreshService().markNeedsRefresh();
              });
            },
            onAddCard: () => _addCard(column),
            onCardMoved: _onCardMoved,
          );
        },
      ),
    );
  }
}
