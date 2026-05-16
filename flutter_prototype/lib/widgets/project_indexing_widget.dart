import 'dart:async';
import 'package:flutter/material.dart';
import '../models/project.dart';
import '../services/project_service.dart';
import '../services/kanban_refresh_service.dart';
import '../constants/app_constants.dart';
import '../services/acp_client.dart';
import '../utils/app_logger.dart';
import '../theme/app_theme.dart';

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
      
      if (status['index_status'] == 'idle' && _status?['index_status'] == 'running') {
        KanbanRefreshService().markNeedsRefresh();
      }
    }
  }

  Future<void> _startIndexing({bool forceFull = false}) async {
    Map<String, dynamic>? config;
    
    try {
      config = await _acpClient.getSystemConfig();
    } catch (e) {
      AppLogger.error('ACP Config check failed', e);
    }

    if (config == null || config.isEmpty) {
      config = await _projectService.getSystemConfig();
    }

    final apiKey = config?['openai_api_key'] ?? config?['api_key'] ?? config?['apiKey'];

    if (apiKey == null || apiKey.toString().isEmpty) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Embedding Not Configured'),
            content: const Text('You need to configure OpenAI API Key in Connection Settings to use semantic search indexing.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
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

    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final indexStatus = _status!['index_status'] ?? 'idle';
    final isRunning = indexStatus == 'running';
    final progress = _status!['progress'];
    final stats = _status!['stats'] ?? {};
    final lastIndexed = _status!['last_indexed_at'];

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: theme.dividerTheme.color!),
        borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppConstants.space16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.analytics_outlined, color: colorScheme.primary, size: 20),
                const SizedBox(width: AppConstants.space8),
                Text(
                  'Codebase Indexing',
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                _buildStatusChip(context, indexStatus),
              ],
            ),
            const SizedBox(height: AppConstants.space16),
            
            if (isRunning && progress != null) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
                child: LinearProgressIndicator(
                  value: (progress['percent'] ?? 0).toDouble() / 100,
                  backgroundColor: colorScheme.surfaceContainerHighest,
                  color: colorScheme.primary,
                  minHeight: 4,
                ),
              ),
              const SizedBox(height: AppConstants.space8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Processing: ${progress['current']}/${progress['total']}',
                    style: theme.textTheme.bodySmall,
                  ),
                  Text(
                    '${progress['percent']}%',
                    style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              if (progress['current_file'] != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4.0),
                  child: Text(
                    progress['current_file'],
                    style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              const SizedBox(height: AppConstants.space16),
            ] else ...[
              _buildStatRow(context, 'Files Indexed', '${stats['total_files'] ?? 0}'),
              _buildStatRow(context, 'Symbols Found', '${stats['total_symbols'] ?? 0}'),
              _buildStatRow(context, 'Symbols Vectorized', '${stats['total_vectorized_symbols'] ?? 0}'),
              if (lastIndexed != null)
                _buildStatRow(context, 'Last Updated', _formatDate(lastIndexed)),
              const SizedBox(height: AppConstants.space16),
            ],

            Row(
              children: [
                if (isRunning)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _cancelIndexing,
                      icon: const Icon(Icons.stop_circle_outlined, size: 18),
                      label: const Text('Cancel'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: colorScheme.error,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusSmall)),
                      ),
                    ),
                  )
                else ...[
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _startIndexing(forceFull: false),
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: Text(stats['total_files'] == 0 ? 'Start Indexing' : 'Incremental Update'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colorScheme.primary,
                        foregroundColor: colorScheme.onPrimary,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusSmall)),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppConstants.space8),
                  IconButton.outlined(
                    onPressed: () => _startIndexing(forceFull: true),
                    icon: const Icon(Icons.restart_alt_rounded),
                    tooltip: 'Full Re-index',
                    style: OutlinedButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusSmall)),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusChip(BuildContext context, String status) {
    final theme = Theme.of(context);
    final customColors = theme.extension<CustomColors>()!;
    final colorScheme = theme.colorScheme;
    
    Color color = colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis);
    String label = status.toUpperCase();
    
    switch (status) {
      case 'idle':
        color = customColors.success!;
        label = 'READY';
        break;
      case 'running':
        color = customColors.warning!;
        label = 'INDEXING';
        break;
      case 'error':
        color = colorScheme.error;
        label = 'ERROR';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(AppConstants.radiusFull),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildStatRow(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          Text(value, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface)),
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
