import 'dart:convert';
import 'package:flutter/material.dart';
import 'services/acp_client.dart';
import 'models/task.dart';

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
  List<KanbanTask> _tasks = [];
  final List<Map<String, String>> _chatHistory = [];
  final _textController = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    setState(() => _isLoading = true);
    try {
      // Configure Smart Connect (Replace with actual values or use a config screen later)
      final config = ACPConfig(
        localIp: 'localhost', // or actual Mac IP
        relayHost: 'localhost', // or actual Relay server
        userId: 'test_user',
      );

      await _acpClient.smartConnect(config);
      await _acpClient.initialize();
      await _loadTasks();
    } catch (e) {
      debugPrint('Init Error: $e');
      _chatHistory.add({'role': 'error', 'message': 'Connection failed: $e'});
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // Issue 1: Fetch and sync tasks from AI context
  Future<void> _loadTasks() async {
    try {
      // We ask the AI to provide the current tasks in a JSON format we can parse.
      // This leverages the "Living Timeline" and current DB state.
      final response = await _acpClient.sendMessage(
        "Please provide the current list of all kanban tasks in a valid JSON array format. "
        "Only return the JSON, nothing else."
      );
      
      // Basic JSON extraction (looking for [...])
      final match = RegExp(r'\[.*\]', dotAll: true).stringMatch(response);
      if (match != null) {
        final List<dynamic> data = jsonDecode(match);
        setState(() {
          _tasks = data.map((t) => KanbanTask.fromJson(t)).toList();
        });
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
      setState(() {
        _chatHistory.add({'role': 'ai', 'message': response});
      });
      // Issue 2: Sync tasks after every message in case AI modified the board
      await _loadTasks();
    } catch (e) {
      setState(() {
        _chatHistory.add({'role': 'error', 'message': 'Failed: $e'});
      });
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Widget _getStatusDot() {
    Color color;
    switch (_acpClient.activeMode) {
      case ConnectionMode.local: color = Colors.green; break;
      case ConnectionMode.relay: color = Colors.orange; break;
      case ConnectionMode.cloud: color = Colors.blue; break;
      default: color = Colors.red;
    }
    return Container(
      width: 10, height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              const Text('AI Kanban'),
              const SizedBox(width: 10),
              _getStatusDot(),
              const SizedBox(width: 5),
              Text(
                _acpClient.activeMode.name.toUpperCase(),
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          actions: [
            IconButton(icon: const Icon(Icons.refresh), onPressed: _loadTasks),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.dashboard), text: 'Board'),
              Tab(icon: Icon(Icons.history), text: 'Timeline'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildBoardView(),
            _buildChatView(),
          ],
        ),
      ),
    );
  }

  // Issue 3: Added RefreshIndicator
  Widget _buildBoardView() {
    return RefreshIndicator(
      onRefresh: _loadTasks,
      child: Row(
        children: [
          _buildColumn('Todo', _tasks.where((t) => t.isTodo).toList()),
          _buildColumn('Doing', _tasks.where((t) => t.isInProgress).toList()),
          _buildColumn('Done', _tasks.where((t) => t.isDone).toList()),
        ],
      ),
    );
  }

  // Issue 4 & 5: Improved Empty State and Card Info
  Widget _buildColumn(String title, List<KanbanTask> tasks) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.grey[100],
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            Expanded(
              child: tasks.isEmpty
                  ? Center(child: Text('Empty', style: TextStyle(color: Colors.grey[400])))
                  : ListView.builder(
                      itemCount: tasks.length,
                      itemBuilder: (context, index) => _buildTaskCard(tasks[index]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTaskCard(KanbanTask task) {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        title: Text(task.title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(task.description, maxLines: 2, overflow: TextOverflow.ellipsis),
        isThreeLine: true,
        dense: true,
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
                alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                  padding: const EdgeInsets.all(14),
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    color: isUser ? Colors.indigo : Colors.white,
                    border: isUser ? null : Border.all(color: Colors.grey[300]!),
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(isUser ? 16 : 0),
                      bottomRight: Radius.circular(isUser ? 0 : 16),
                    ),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 4, offset: const Offset(0, 2))
                    ]
                  ),
                  child: Text(
                    item['message']!,
                    style: TextStyle(color: isUser ? Colors.white : Colors.black87),
                  ),
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
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, -2))],
      ),
      child: SafeArea(
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _textController,
                decoration: InputDecoration(
                  hintText: 'Discuss or manage tasks...',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                  filled: true,
                  fillColor: Colors.grey[100],
                  contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                ),
                onSubmitted: (_) => _handleSendMessage(),
              ),
            ),
            const SizedBox(width: 8),
            FloatingActionButton.small(
              onPressed: _handleSendMessage,
              child: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
