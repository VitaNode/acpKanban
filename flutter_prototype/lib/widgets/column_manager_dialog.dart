import 'package:flutter/material.dart';
import '../models/kanban_column.dart';
import '../services/project_service.dart';

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
    _columns = List.from(widget.columns)..sort((a, b) => a.position.compareTo(b.position));
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
    final name = await _showNameDialog('Add Column');
    if (name != null && name.isNotEmpty) {
      setState(() => _isLoading = true);
      await _projectService.createColumn(widget.projectId, name);
      _refreshColumns();
    }
  }

  Future<void> _editColumn(KanbanColumn column) async {
    final name = await _showNameDialog('Edit Column', initialValue: column.name);
    if (name != null && name.isNotEmpty) {
      setState(() => _isLoading = true);
      await _projectService.updateColumn(column.id, name: name);
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
              items: otherColumns.map((c) => DropdownMenuItem(
                value: c.id,
                child: Text(c.name),
              )).toList(),
              onChanged: (v) => moveToId = v,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              hint: const Text('Select target column'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
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

  Future<String?> _showNameDialog(String title, {String initialValue = ''}) {
    final controller = TextEditingController(text: initialValue);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Column Name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('OK')),
        ],
      ),
    );
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
                  child: Text('Drag to reorder columns', style: TextStyle(fontSize: 12, color: Colors.grey)),
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
                              icon: const Icon(Icons.delete_outline, size: 20, color: Colors.redAccent),
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
          label: const Text('Add Column')
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}
