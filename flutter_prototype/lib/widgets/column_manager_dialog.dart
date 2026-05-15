import 'dart:async';
import 'package:flutter/material.dart';
import '../models/kanban_column.dart';
import '../services/project_service.dart';
import '../constants/app_constants.dart';
import '../utils/icon_util.dart';
import '../models/acp_provider.dart';
import '../theme/app_theme.dart';

class ColorEditResult {
  final String name;
  final String color;
  final String? promptTemplate;
  final String? acpProviderId;

  ColorEditResult({required this.name, required this.color, this.promptTemplate, this.acpProviderId});
}

class ColumnEditDialog extends StatefulWidget {
  final String initialName;
  final String initialColor;
  final String? initialPromptTemplate;
  final String? initialProviderId;

  const ColumnEditDialog({
    super.key,
    required this.initialName,
    required this.initialColor,
    this.initialPromptTemplate,
    this.initialProviderId,
  });

  @override
  State<ColumnEditDialog> createState() => _ColumnEditDialogState();
}

class _ColumnEditDialogState extends State<ColumnEditDialog> {
  final _projectService = ProjectService();
  late TextEditingController _nameController;
  late TextEditingController _promptTemplateController;
  late String _selectedColor;
  String? _selectedProviderId;
  List<ACPProvider> _providers = [];
  bool _isLoadingProviders = true;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName);
    _selectedColor = widget.initialColor;
    _promptTemplateController =
        TextEditingController(text: widget.initialPromptTemplate ?? '');
    _selectedProviderId = widget.initialProviderId;
    _loadProviders();
  }

  Future<void> _loadProviders() async {
    try {
      final data = await _projectService.getProviders();
      if (data != null && mounted) {
        final List<dynamic> providersJson = data['providers'] ?? [];
        setState(() {
          _providers = providersJson.map((p) => ACPProvider.fromJson(p)).toList();
          _isLoadingProviders = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingProviders = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _promptTemplateController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final size = MediaQuery.of(context).size;
    final isMobile = size.width < 600;

    return AlertDialog(
      title: const Text('Edit Column'),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusMedium)),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: isMobile ? size.width * 0.9 : 450,
          maxHeight: size.height * 0.8,
        ),
        child: SizedBox(
          width: size.width * 0.9,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _nameController,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Column Name'),
                ),
                const SizedBox(height: AppConstants.space24),
                if (_isLoadingProviders)
                  const Center(child: CircularProgressIndicator())
                else
                  DropdownButtonFormField<String>(
                    value: _selectedProviderId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Default AI Provider',
                      hintText: 'Select an agent for this column',
                    ),
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('None (Manual selection)', overflow: TextOverflow.ellipsis),
                      ),
                      ..._providers.map((p) => DropdownMenuItem(
                            value: p.id,
                            child: Row(
                              children: [
                                Icon(IconUtil.getProviderIcon(p.icon), size: 18),
                                const SizedBox(width: 8),
                                Expanded(child: Text(p.name, overflow: TextOverflow.ellipsis)),
                              ],
                            ),
                          )),
                    ],
                    onChanged: (v) => setState(() => _selectedProviderId = v),
                  ),                const SizedBox(height: AppConstants.space24),
                TextField(
                  controller: _promptTemplateController,
                  decoration: const InputDecoration(
                    labelText: 'Prompt Template',
                    hintText: 'Instructions for AI in this column...',
                  ),
                  maxLines: 6,
                ),
                const SizedBox(height: AppConstants.space8),
                Text(
                  '💡 Custom prompt for cards in this column.',
                  style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.primary),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            final name = _nameController.text.trim();
            if (name.isNotEmpty) {
              final promptTemplate = _promptTemplateController.text.trim();
              Navigator.pop(
                  context,
                  ColorEditResult(
                      name: name,
                      color: _selectedColor,
                      promptTemplate: promptTemplate.isEmpty ? null : promptTemplate,
                      acpProviderId: _selectedProviderId));
            }
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: colorScheme.primary,
            foregroundColor: colorScheme.onPrimary,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusSmall)),
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _AddColumnDialog extends StatefulWidget {
  final int existingColumnCount;
  const _AddColumnDialog({required this.existingColumnCount});

  @override
  State<_AddColumnDialog> createState() => _AddColumnDialogState();
}

class _AddColumnDialogState extends State<_AddColumnDialog> {
  final _projectService = ProjectService();
  final _nameController = TextEditingController();
  final _promptTemplateController = TextEditingController();
  late String _selectedColor;
  String? _selectedProviderId;
  List<ACPProvider> _providers = [];
  bool _isLoadingProviders = true;

  static const List<String> _colors = [
    '#4ECDC4', '#45B7D1', '#FF6B6B', '#96CEB4', '#BB8FCE', 
    '#F7DC6F', '#98D8C8', '#85C1E9', '#F8B500', '#00CED1', 
    '#FF69B4', '#32CD32', '#FF4500', '#6B5B95', '#008080',
  ];

  @override
  void initState() {
    super.initState();
    _selectedColor = _colors[widget.existingColumnCount % _colors.length];
    _loadProviders();
  }

  Future<void> _loadProviders() async {
    try {
      final data = await _projectService.getProviders();
      if (data != null && mounted) {
        final List<dynamic> providersJson = data['providers'] ?? [];
        setState(() {
          _providers = providersJson.map((p) => ACPProvider.fromJson(p)).toList();
          _isLoadingProviders = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingProviders = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _promptTemplateController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final size = MediaQuery.of(context).size;
    final isMobile = size.width < 600;

    return AlertDialog(
      title: const Text('Add Column'),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusMedium)),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: isMobile ? size.width * 0.9 : 450,
          maxHeight: size.height * 0.8,
        ),
        child: SizedBox(
          width: size.width * 0.9,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _nameController,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Column Name'),
                ),
                const SizedBox(height: AppConstants.space24),
                if (_isLoadingProviders)
                  const Center(child: CircularProgressIndicator())
                else
                  DropdownButtonFormField<String>(
                    value: _selectedProviderId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Default AI Provider',
                    ),
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('None (Manual selection)', overflow: TextOverflow.ellipsis),
                      ),
                      ..._providers.map((p) => DropdownMenuItem(
                            value: p.id,
                            child: Row(
                              children: [
                                Icon(IconUtil.getProviderIcon(p.icon), size: 18),
                                const SizedBox(width: 8),
                                Expanded(child: Text(p.name, overflow: TextOverflow.ellipsis)),
                              ],
                            ),
                          )),
                    ],
                    onChanged: (v) => setState(() => _selectedProviderId = v),
                  ),
                const SizedBox(height: AppConstants.space24),
                TextField(
                  controller: _promptTemplateController,
                  decoration: const InputDecoration(
                    labelText: 'Prompt Template',
                    hintText: 'Instructions for AI...',
                  ),
                  maxLines: 5,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            final name = _nameController.text.trim();
            if (name.isNotEmpty) {
              final promptTemplate = _promptTemplateController.text.trim();
              Navigator.pop(
                  context,
                  ColorEditResult(
                      name: name,
                      color: _selectedColor,
                      promptTemplate: promptTemplate.isEmpty ? null : promptTemplate,
                      acpProviderId: _selectedProviderId));
            }
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: colorScheme.primary,
            foregroundColor: colorScheme.onPrimary,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusSmall)),
          ),
          child: const Text('Create'),
        ),
      ],
    );
  }
}

class ColumnManagerDialog extends StatefulWidget {
  final String projectId;
  final List<KanbanColumn> columns;
  final VoidCallback onUpdated;

  const ColumnManagerDialog({
    super.key,
    required this.projectId,
    required this.columns,
    required this.onUpdated,
  });

  @override
  State<ColumnManagerDialog> createState() => _ColumnManagerDialogState();
}

class _ColumnManagerDialogState extends State<ColumnManagerDialog> {
  final _projectService = ProjectService();
  late List<KanbanColumn> _columns;
  bool _isLoading = false;
  Map<String, dynamic> _providerStatuses = {};
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    _columns = List.from(widget.columns)
      ..sort((a, b) => a.position.compareTo(b.position));
    _loadProviderStatuses();
    _statusTimer = Timer.periodic(const Duration(seconds: 5), (_) => _loadProviderStatuses());
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadProviderStatuses() async {
    try {
      final data = await _projectService.getProviderInitStatus(widget.projectId);
      if (data != null && data['providers'] != null && mounted) {
        final Map<String, dynamic> statuses = {};
        for (var p in data['providers']) {
          statuses[p['provider_id']] = p;
        }
        setState(() => _providerStatuses = statuses);
      }
    } catch (e) {
      debugPrint('Error loading provider statuses: $e');
    }
  }

  Future<void> _initializeProvider(String providerId) async {
    try {
      setState(() => _providerStatuses[providerId] = {...(_providerStatuses[providerId] ?? {}), 'status': 'initializing'});
      await _projectService.initializeProvider(providerId);
      _loadProviderStatuses();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to initialize: $e')));
      }
    }
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1;
    setState(() {
      final item = _columns.removeAt(oldIndex);
      _columns.insert(newIndex, item);
    });

    await _projectService.reorderColumns(widget.projectId, _columns);
    widget.onUpdated();
  }

  Future<void> _addColumn() async {
    final result = await showDialog<ColorEditResult>(
      context: context,
      builder: (context) => _AddColumnDialog(existingColumnCount: _columns.length),
    );
    if (result != null) {
      setState(() => _isLoading = true);
      await _projectService.createColumn(
        widget.projectId,
        result.name,
        color: result.color,
        promptTemplate: result.promptTemplate,
        acpProviderId: result.acpProviderId,
      );
      _refreshColumns();
    }
  }

  Future<void> _editColumn(KanbanColumn column) async {
    final result = await showDialog<ColorEditResult>(
      context: context,
      builder: (context) => ColumnEditDialog(
        initialName: column.name,
        initialColor: column.color,
        initialPromptTemplate: column.promptTemplate,
        initialProviderId: column.acpProviderId,
      ),
    );
    if (result != null) {
      setState(() => _isLoading = true);
      await _projectService.updateColumn(
        column.id,
        name: result.name,
        color: result.color,
        promptTemplate: result.promptTemplate,
        acpProviderId: result.acpProviderId,
      );
      _refreshColumns();
    }
  }

  Future<void> _deleteColumn(KanbanColumn column) async {
    if (_columns.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot delete the last column')),
      );
      return;
    }

    String? moveToId;
    final otherColumns = _columns.where((c) => c.id != column.id).toList();

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Column'),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusMedium)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Move cards in "${column.name}" to:', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: AppConstants.space16),
            DropdownButtonFormField<String>(
              isExpanded: true,
              items: otherColumns
                  .map((c) => DropdownMenuItem(
                        value: c.id,
                        child: Text(c.name, overflow: TextOverflow.ellipsis),
                      ))
                  .toList(),
              onChanged: (v) => moveToId = v,
              decoration: const InputDecoration(labelText: 'Target Column'),
              hint: const Text('Select target column', overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true && moveToId != null) {
      setState(() => _isLoading = true);
      await _projectService.deleteColumn(column.id, moveToColumnId: moveToId);
      _refreshColumns();
    }
  }

  Future<void> _refreshColumns() async {
    final updated = await _projectService.getColumns(widget.projectId);
    if (mounted) {
      setState(() {
        _columns = updated..sort((a, b) => a.position.compareTo(b.position));
        _isLoading = false;
      });
      _loadProviderStatuses();
      widget.onUpdated();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final size = MediaQuery.of(context).size;
    final isMobile = size.width < 600;

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.view_column_rounded, color: colorScheme.primary),
          const SizedBox(width: AppConstants.space12),
          Expanded(child: Text('Manage Columns', style: theme.textTheme.headlineMedium, overflow: TextOverflow.ellipsis)),
        ],
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusMedium)),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: isMobile ? size.width * 0.95 : size.width * 0.8,
          maxHeight: isMobile ? size.height * 0.9 : size.height * 0.8,
        ),
        child: SizedBox(
          width: size.width * 0.9,
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('DRAG TO REORDER', style: theme.textTheme.labelLarge),
                    const SizedBox(height: AppConstants.space8),
                    Flexible(
                      child: ReorderableListView.builder(
                        shrinkWrap: true,
                        itemCount: _columns.length,
                        onReorder: _onReorder,
                        itemBuilder: (context, index) {
                          final col = _columns[index];
                          final providerId = col.acpProviderId;
                          final statusInfo = providerId != null ? _providerStatuses[providerId] : null;
                          final status = statusInfo?['status'] ?? 'unknown';

                          return Container(
                            key: ValueKey(col.id),
                            margin: const EdgeInsets.symmetric(vertical: AppConstants.space4),
                            decoration: BoxDecoration(
                              color: colorScheme.surfaceContainer,
                              borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
                            ),
                            child: ListTile(
                              leading: Icon(Icons.drag_indicator_rounded, 
                                  color: colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis)),
                              title: Row(
                                children: [
                                  Expanded(child: Text(col.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                                  if (providerId != null) ...[
                                    _buildStatusBadge(status, theme, colorScheme),
                                    const SizedBox(width: 8),
                                    if (status != 'ready' && status != 'initializing')
                                      TextButton(
                                        onPressed: () => _initializeProvider(providerId),
                                        style: TextButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                                          minimumSize: Size.zero,
                                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                          textStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                                        ),
                                        child: const Text('INIT'),
                                      )
                                    else if (status == 'initializing')
                                      const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                                  ],
                                ],
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.edit_outlined, size: 20),
                                    onPressed: () => _editColumn(col),
                                  ),
                                  IconButton(
                                    icon: Icon(Icons.delete_outline_rounded,
                                        size: 20, color: colorScheme.error),
                                    onPressed: () => _deleteColumn(col),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
        ),
      ),
      actions: [
        TextButton.icon(
            onPressed: _addColumn,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add Column')),
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close')),
      ],
    );
  }

  Widget _buildStatusBadge(String status, ThemeData theme, ColorScheme colorScheme) {
    Color color;
    String label;
    switch (status) {
      case 'ready':
        color = Colors.green;
        label = 'READY';
        break;
      case 'degraded':
        color = Colors.orange;
        label = 'ERR';
        break;
      case 'initializing':
        color = colorScheme.primary;
        label = 'INIT...';
        break;
      case 'uninitialized':
        color = Colors.grey;
        label = 'OFFLINE';
        break;
      default:
        color = Colors.grey;
        label = status.toUpperCase();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.3), width: 0.5),
      ),
      child: Text(label, style: TextStyle(fontSize: 9, color: color, fontWeight: FontWeight.bold)),
    );
  }
}
