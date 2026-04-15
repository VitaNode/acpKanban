import 'package:flutter/material.dart';
import '../models/kanban_column.dart';
import '../services/project_service.dart';

class ColorEditResult {
  final String name;
  final String color;
  final String? promptTemplate;

  ColorEditResult({required this.name, required this.color, this.promptTemplate});
}

class ColumnEditDialog extends StatefulWidget {
  final String initialName;
  final String initialColor;
  final String? initialPromptTemplate;

  const ColumnEditDialog({
    super.key,
    required this.initialName,
    required this.initialColor,
    this.initialPromptTemplate,
  });

  @override
  State<ColumnEditDialog> createState() => _ColumnEditDialogState();
}

class _ColumnEditDialogState extends State<ColumnEditDialog> {
  late TextEditingController _nameController;
  late TextEditingController _promptTemplateController;
  late String _selectedColor;

  static const List<String> _colors = [
    '#FF6B6B',
    '#4ECDC4',
    '#45B7D1',
    '#96CEB4',
    '#FFEAA7',
    '#DDA0DD',
    '#98D8C8',
    '#F7DC6F',
    '#BB8FCE',
    '#85C1E9',
    '#F8B500',
    '#00CED1',
    '#FF69B4',
    '#32CD32',
    '#FF4500',
    '#6B5B95',
  ];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName);
    _selectedColor = widget.initialColor;
    _promptTemplateController =
        TextEditingController(text: widget.initialPromptTemplate ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _promptTemplateController.dispose();
    super.dispose();
  }

  Color _parseColor(String colorHex) {
    final hex = colorHex.replaceFirst('#', '');
    if (hex.length == 6) {
      return Color(int.parse('FF$hex', radix: 16));
    }
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Column'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Column Name'),
            ),
            const SizedBox(height: 20),
            const Text('Color',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _colors.map((color) {
                final isSelected =
                    color.toUpperCase() == _selectedColor.toUpperCase();
                return GestureDetector(
                  onTap: () => setState(() => _selectedColor = color),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: _parseColor(color),
                      shape: BoxShape.circle,
                      border: isSelected
                          ? Border.all(color: Colors.black, width: 3)
                          : null,
                    ),
                    child: isSelected
                        ? const Icon(Icons.check, color: Colors.white, size: 20)
                        : null,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Text('Preview: ', style: TextStyle(fontSize: 12)),
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: _parseColor(_selectedColor),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.grey[300]!),
                  ),
                ),
                const SizedBox(width: 8),
                Text(_selectedColor, style: const TextStyle(fontSize: 12)),
              ],
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _promptTemplateController,
              decoration: const InputDecoration(
                labelText: 'Prompt Template (optional)',
                hintText: 'Instructions for AI when working in this column...',
                border: OutlineInputBorder(),
              ),
              maxLines: 4,
            ),
            const SizedBox(height: 8),
            Text(
              '💡 This prompt will be included in the context sent to LLM for cards in this column.',
              style: TextStyle(fontSize: 11, color: Colors.blue[700]),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            final name = _nameController.text.trim();
            if (name.isNotEmpty) {
              final promptTemplate = _promptTemplateController.text.trim();
              Navigator.pop(
                  context, ColorEditResult(
                      name: name,
                      color: _selectedColor,
                      promptTemplate: promptTemplate.isEmpty ? null : promptTemplate));
            }
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _AddColumnDialog extends StatefulWidget {
  const _AddColumnDialog();

  @override
  State<_AddColumnDialog> createState() => _AddColumnDialogState();
}

class _AddColumnDialogState extends State<_AddColumnDialog> {
  final _nameController = TextEditingController();
  final _promptTemplateController = TextEditingController();
  String _selectedColor = '#808080';

  static const List<String> _colors = [
    '#FF6B6B', '#4ECDC4', '#45B7D1', '#96CEB4', '#FFEAA7',
    '#DDA0DD', '#98D8C8', '#F7DC6F', '#BB8FCE', '#85C1E9',
    '#F8B500', '#00CED1', '#FF69B4', '#32CD32', '#FF4500',
    '#6B5B95', '#808080',
  ];

  @override
  void dispose() {
    _nameController.dispose();
    _promptTemplateController.dispose();
    super.dispose();
  }

  Color _parseColor(String colorHex) {
    final hex = colorHex.replaceFirst('#', '');
    if (hex.length == 6) return Color(int.parse('FF$hex', radix: 16));
    return Colors.grey;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Column'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Column Name'),
            ),
            const SizedBox(height: 16),
            const Text('Color',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _colors.map((color) {
                final isSelected =
                    color.toUpperCase() == _selectedColor.toUpperCase();
                return GestureDetector(
                  onTap: () => setState(() => _selectedColor = color),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: _parseColor(color),
                      shape: BoxShape.circle,
                      border: isSelected
                          ? Border.all(color: Colors.black, width: 3)
                          : Border.all(color: Colors.grey[300]!),
                    ),
                    child: isSelected
                        ? const Icon(Icons.check, color: Colors.white, size: 16)
                        : null,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _promptTemplateController,
              decoration: const InputDecoration(
                labelText: 'Prompt Template (optional)',
                hintText: 'Instructions for AI when working in this column...',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 8),
            Text(
              '💡 This prompt will be included in the context sent to LLM for cards in this column.',
              style: TextStyle(fontSize: 11, color: Colors.blue[700]),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            final name = _nameController.text.trim();
            if (name.isNotEmpty) {
              final promptTemplate = _promptTemplateController.text.trim();
              Navigator.pop(
                  context,
                  ColorEditResult(
                      name: name,
                      color: _selectedColor,
                      promptTemplate: promptTemplate.isEmpty ? null : promptTemplate));
            }
          },
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

  @override
  void initState() {
    super.initState();
    _columns = List.from(widget.columns)
      ..sort((a, b) => a.position.compareTo(b.position));
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
      builder: (context) => _AddColumnDialog(),
    );
    if (result != null) {
      setState(() => _isLoading = true);
      await _projectService.createColumn(
        widget.projectId,
        result.name,
        color: result.color,
        promptTemplate: result.promptTemplate,
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
      ),
    );
    if (result != null) {
      setState(() => _isLoading = true);
      await _projectService.updateColumn(
        column.id,
        name: result.name,
        color: result.color,
        promptTemplate: result.promptTemplate,
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
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Move cards in "${column.name}" to:'),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              items: otherColumns
                  .map((c) => DropdownMenuItem(
                        value: c.id,
                        child: Text(c.name),
                      ))
                  .toList(),
              onChanged: (v) => moveToId = v,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              hint: const Text('Select target column'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
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
      widget.onUpdated();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.view_column_outlined),
          SizedBox(width: 8),
          Text('Manage Columns'),
        ],
      ),
      content: SizedBox(
        width: 400,
        height: 500,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8.0),
                    child: Text('Drag to reorder columns',
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                  ),
                  Expanded(
                    child: ReorderableListView.builder(
                      itemCount: _columns.length,
                      onReorder: _onReorder,
                      itemBuilder: (context, index) {
                        final col = _columns[index];
                        return ListTile(
                          key: ValueKey(col.id),
                          leading: const Icon(Icons.drag_handle),
                          title: Text(col.name),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit_outlined, size: 20),
                                onPressed: () => _editColumn(col),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    size: 20, color: Colors.redAccent),
                                onPressed: () => _deleteColumn(col),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton.icon(
            onPressed: _addColumn,
            icon: const Icon(Icons.add),
            label: const Text('Add Column')),
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close')),
      ],
    );
  }
}
