import 'dart:async';
import 'package:flutter/material.dart';
import '../models/project.dart';
import '../services/project_service.dart';
import '../services/kanban_refresh_service.dart';
import '../constants/app_constants.dart';
import '../services/acp_client.dart';

class ProjectIndexingWidget extends StatefulWidget {
  final Project project;

  const ProjectIndexingWidget({
    super.key,
    required this.project,
  });

  @override
  State<ProjectIndexingWidget> createState() => _ProjectIndexingWidgetState();
}

class _ProjectIndexingWidgetState extends State<ProjectIndexingWidget> {
  final _projectService = ProjectService();
  final _acpClient = ACPClient();
  Map<String, dynamic>? _status;
  Timer? _statusTimer;
  bool _isDisposed = false;

  @override
  void initState() {
    super.initState();
    _fetchStatus();
    _startStatusPolling();
    _subscribeToProgress();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _statusTimer?.cancel();
    super.dispose();
  }

  void _startStatusPolling() {
    _statusTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (!_isDisposed) _fetchStatus();
    });
  }

  Future<void> _fetchStatus() async {
    final status = await _projectService.getIndexingStatus(widget.project.id);
    if (status != null && !_isDisposed) {
      setState(() {
        _status = status;
      });
      
      // If completed, refresh the main view
      if (status['index_status'] == 'idle' && _status?['index_status'] == 'running') {
        KanbanRefreshService().markNeedsRefresh();
      }
    }
  }

  void _subscribeToProgress() {
    // Phase 4: Listen to WebSocket messages
    // The main screen usually handles the stream, but we can listen specifically here too if ACPClient exposes it
    // For simplicity, we use polling for now and complement with manual refresh
  }

  Future<void> _startIndexing({bool forceFull = false}) async {
    // Validate config first
    final config = await _acpClient.getSystemConfig();
    if (config == null || config['openai_api_key'] == null || config['openai_api_key'].isEmpty) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Embedding Not Configured'),
            content: const Text('You need to configure OpenAI API Key in Connection Settings to use semantic search indexing.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  // We could navigate to settings here but we are in a dialog
                },
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      return;
    }

    final success = await _projectService.startIndexing(widget.project.id, forceFull: forceFull);
    if (success) {
      _fetchStatus();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to start indexing')),
        );
      }
    }
  }

  Future<void> _cancelIndexing() async {
    await _projectService.cancelIndexing(widget.project.id);
    _fetchStatus();
  }

  @override
  Widget build(BuildContext context) {
    if (_status == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final indexStatus = _status!['index_status'] ?? 'idle';
    final isRunning = indexStatus == 'running';
    final progress = _status!['progress'];
    final stats = _status!['stats'] ?? {};
    final lastIndexed = _status!['last_indexed_at'];

    return Card(
      elevation: 0,
      color: Colors.grey.shade50,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Colors.grey.shade200),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.analytics_outlined, color: AppConstants.primaryColor, size: 20),
                const SizedBox(width: 8),
                Text(
                  'Codebase Indexing',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                _buildStatusChip(indexStatus),
              ],
            ),
            const SizedBox(height: 16),
            
            if (isRunning && progress != null) ...[
              LinearProgressIndicator(
                value: (progress['percent'] ?? 0).toDouble() / 100,
                backgroundColor: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Processing: ${progress['current']}/${progress['total']}',
                    style: const TextStyle(fontSize: 12, color: AppConstants.textHint),
                  ),
                  Text(
                    '${progress['percent']}%',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              if (progress['current_file'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4.0),
                  child: Text(
                    progress['current_file'],
                    style: const TextStyle(fontSize: 10, color: AppConstants.textHint, fontStyle: FontStyle.italic),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              const SizedBox(height: 16),
            ] else ...[
              _buildStatRow('Files Indexed', '${stats['total_files'] ?? 0}'),
              _buildStatRow('Symbols Found', '${stats['total_symbols'] ?? 0}'),
              if (lastIndexed != null)
                _buildStatRow('Last Updated', _formatDate(lastIndexed)),
              const SizedBox(height: 16),
            ],

            Row(
              children: [
                if (isRunning)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _cancelIndexing,
                      icon: const Icon(Icons.stop_circle_outlined, size: 18),
                      label: const Text('Cancel'),
                      style: OutlinedButton.styleFrom(foregroundColor: AppConstants.errorColor),
                    ),
                  )
                else ...[
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _startIndexing(forceFull: false),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: Text(stats['total_files'] == 0 ? 'Start Indexing' : 'Incremental Update'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () => _startIndexing(forceFull: true),
                    icon: const Icon(Icons.restart_alt_rounded),
                    tooltip: 'Full Re-index',
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusChip(String status) {
    Color color = Colors.grey;
    String label = status.toUpperCase();
    
    switch (status) {
      case 'idle':
        color = Colors.green;
        label = 'READY';
        break;
      case 'running':
        color = Colors.orange;
        label = 'INDEXING';
        break;
      case 'error':
        color = Colors.red;
        label = 'ERROR';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: BorderSide(color: color.withOpacity(0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, color: AppConstants.textSecondary)),
          Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  String _formatDate(String iso) {
    try {
      final dt = DateTime.parse(iso);
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (e) {
      return iso;
    }
  }
}
