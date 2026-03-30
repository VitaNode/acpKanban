import 'dart:convert';
import 'package:flutter/material.dart';
import 'services/acp_client.dart';
import 'services/smart_connect.dart';
import 'services/connection_config_manager.dart';
import 'services/project_service.dart';
import 'models/connection_config.dart';
import 'models/kanban_card.dart';
import 'models/kanban_column.dart';
import 'models/project.dart';
import 'screens/connection_settings_screen.dart';
import 'screens/card_session_screen.dart';
import 'widgets/project_selector.dart';
import 'widgets/kanban_column_widget.dart';

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
  final List<Map<String, String>> _chatHistory = [];
  final _textController = TextEditingController();
  bool _isLoading = false;
  String? _userId;

  // Project state
  List<Project> _projects = [];
  Project? _currentProject;
  List<KanbanColumn> _columns = [];
  bool _isLoadingProjects = false;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    setState(() => _isLoading = true);
    try {
      final configManager = await ConnectionConfigManager.getInstance();
      final savedConfig = await configManager.loadConfig();
      _userId = savedConfig.userId;

      final acpConfig = ACPConfig.fromConnectionConfig(
        savedConfig,
        _userId ?? 'test_user',
      );
      await _acpClient.smartConnect(acpConfig);
      await _acpClient.initialize();

      // Load projects after connection
      await _loadProjects();
    } catch (e) {
      debugPrint('Init Error: $e');
      _chatHistory.add({'role': 'error', 'message': 'Connection failed: $e'});
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadProjects() async {
    setState(() => _isLoadingProjects = true);
    try {
      final projects = await _projectService.getProjects();
      if (mounted) {
        setState(() {
          _projects = projects;
          if (_currentProject == null && projects.isNotEmpty) {
            _currentProject = projects.first;
          }
        });
        if (_currentProject != null) {
          await _switchProject(_currentProject!);
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
      }
    } catch (e) {
      debugPrint('Load project data error: $e');
    }
  }

  Future<void> _switchProject(Project project) async {
    setState(() => _isLoadingProjects = true);
    try {
      final switchData = await _projectService.switchToProject(project.id);
      if (switchData != null && mounted) {
        setState(() {
          _currentProject = switchData.project;
          _columns = switchData.columns.map((c) => c.column).toList();
          _cards = switchData.columns.expand((c) => c.cards).toList();
        });
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
      await _loadProjectData(project.id);
    }
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

  Future<void> _loadTasks() async {
    try {
      final response = await _acpClient.sendMessage(
          "Please provide the current list of all kanban tasks in a valid JSON array format. Only return the JSON.");
      final match = RegExp(r'\[.*\]', dotAll: true).stringMatch(response);
      if (match != null) {
        final List<dynamic> data = jsonDecode(match);
        setState(() => _cards = data.map((t) => KanbanCard.fromJson(t)).toList());
      }
    } catch (e) {
      debugPrint('Load Tasks Error: $e');
    }
  }

  Future<void> _handleSendMessage() async {
    final text = _textController.text;
    if (text.isEmpty) return;
    setState(() {
      _chatHistory.add({'role': 'user', 'message': text});
      _textController.clear();
      _isLoading = true;
    });
    try {
      final response = await _acpClient.sendMessage(text);
      setState(() => _chatHistory.add({'role': 'ai', 'message': response}));
      if (_currentProject != null) {
        await _loadProjectData(_currentProject!.id);
      }
    } catch (e) {
      setState(
          () => _chatHistory.add({'role': 'error', 'message': 'Failed: $e'}));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _getStatusDot() {
    Color color;
    switch (_acpClient.activeMode) {
      case ConnectionPath.local:
        color = Colors.green;
        break;
      case ConnectionPath.relay:
        color = Colors.orange;
        break;
      case ConnectionPath.cloud:
        color = Colors.blue;
        break;
      default:
        color = Colors.red;
    }
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          leading: Builder(
            builder: (context) => IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () => Scaffold.of(context).openDrawer(),
            ),
          ),
          title: Row(
            children: [
              const Text('AI Kanban'),
              const SizedBox(width: 10),
              _getStatusDot(),
              const SizedBox(width: 5),
              Text(
                _acpClient.activeMode.name.toUpperCase(),
                style:
                    const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ProjectSelector(
                  currentProject: _currentProject,
                  projects: _projects,
                  onProjectSelected: _switchProject,
                  onCreateProject: _showCreateProjectDialog,
                  isLoading: _isLoadingProjects,
                ),
              ),
            ],
          ),
          actions: [
            if (_currentProject != null) ...[
              IconButton(
                icon: const Icon(Icons.folder_open),
                tooltip:
                    'Workspace: ${_currentProject?.workspacePath ?? "Not set"}',
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                          'Workspace: ${_currentProject?.workspacePath ?? "Not set"}'),
                    ),
                  );
                },
              ),
            ],
            IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () {
                  if (_currentProject != null) {
                    _loadProjectData(_currentProject!.id);
                  }
                }),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.dashboard), text: 'Board'),
              Tab(icon: Icon(Icons.history), text: 'Timeline'),
            ],
          ),
        ),
        drawer: _buildDrawer(),
        body: TabBarView(
          children: [
            _buildBoardView(),
            _buildChatView(),
          ],
        ),
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
            selected: true,
            onTap: () => Navigator.pop(context),
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Timeline'),
            onTap: () => Navigator.pop(context),
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
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _columns.map((column) {
            final columnCards = _cards
                .where((c) => c.columnId == column.id)
                .toList()
              ..sort((a, b) => a.position.compareTo(b.position));
            return KanbanColumnWidget(
              column: column,
              cards: columnCards,
              onCardTap: (card) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => CardSessionScreen(card: card),
                  ),
                );
              },
              onAddCard: () {
                // TODO: Implement add card
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildChatView() {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            itemCount: _chatHistory.length,
            padding: const EdgeInsets.all(16),
            itemBuilder: (context, index) {
              final item = _chatHistory[index];
              final isUser = item['role'] == 'user';
              return Align(
                alignment:
                    isUser ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.75),
                  padding: const EdgeInsets.all(14),
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    color: isUser ? Colors.indigo : Colors.white,
                    border:
                        isUser ? null : Border.all(color: Colors.grey[300]!),
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(isUser ? 16 : 0),
                      bottomRight: Radius.circular(isUser ? 0 : 16),
                    ),
                  ),
                  child: Text(item['message']!,
                      style: TextStyle(
                          color: isUser ? Colors.white : Colors.black87)),
                ),
              );
            },
          ),
        ),
        if (_isLoading) const LinearProgressIndicator(),
        _buildInputArea(),
      ],
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white, boxShadow: [
        BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, -2))
      ]),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _textController,
                decoration: InputDecoration(
                  hintText: 'Discuss or manage tasks...',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none),
                  filled: true,
                  fillColor: Colors.grey[100],
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                ),
                onSubmitted: (_) => _handleSendMessage(),
              ),
            ),
            const SizedBox(width: 8),
            FloatingActionButton.small(
                onPressed: _handleSendMessage, child: const Icon(Icons.send)),
          ],
        ),
      ),
    );
  }
}
