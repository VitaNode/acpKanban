import 'package:flutter/material.dart';
import '../models/project.dart';

class ProjectManagementDialog extends StatefulWidget {
  final List<Project> projects;
  final Function(Project, String name, String? workspacePath) onUpdate;
  final Function(Project) onDelete;
  final Project? currentProject;

  const ProjectManagementDialog({
    super.key,
    required this.projects,
    required this.onUpdate,
    required this.onDelete,
    this.currentProject,
  });

  @override
  State<ProjectManagementDialog> createState() => _ProjectManagementDialogState();
}

class _ProjectManagementDialogState extends State<ProjectManagementDialog> {
  late List<Project> _localProjects;

  @override
  void initState() {
    super.initState();
    _localProjects = List.from(widget.projects);
  }

  @override
  void didUpdateWidget(ProjectManagementDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.projects != oldWidget.projects) {
      setState(() {
        _localProjects = List.from(widget.projects);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.settings_suggest, color: Theme.of(context).primaryColor),
          const SizedBox(width: 8),
          const Text('Manage Projects'),
        ],
      ),
      content: SizedBox(
        width: 500,
        height: 400,
        child: _localProjects.isEmpty
            ? const Center(child: Text('No projects available.'))
            : ListView.separated(
                itemCount: _localProjects.length,
                separatorBuilder: (context, index) => const Divider(),
                itemBuilder: (context, index) {
                  final project = _localProjects[index];
                  final isCurrent = project.id == widget.currentProject?.id;
                  return ListTile(
                    leading: Icon(
                      isCurrent ? Icons.folder_open : Icons.folder,
                      color: isCurrent ? Theme.of(context).primaryColor : null,
                    ),
                    title: Text(
                      project.name,
                      style: TextStyle(
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    subtitle: Text(
                      'Path: ${project.workspacePath ?? "Not set"}\nLast active: ${project.lastActive}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    isThreeLine: true,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          tooltip: 'Edit Project',
                          onPressed: () {
                            showDialog(
                              context: context,
                              builder: (context) => ProjectEditDialog(
                                project: project,
                                onUpdate: (name, path) async {
                                  await widget.onUpdate(project, name, path);
                                  // The parent will call setState, but since we are a separate dialog,
                                  // we might need to update locally if the parent doesn't trigger a rebuild of the dialog.
                                  // But wait, the dialog IS the one holding the list.
                                  // Let's update locally for immediate feedback.
                                  setState(() {
                                    final idx = _localProjects.indexWhere((p) => p.id == project.id);
                                    if (idx != -1) {
                                      _localProjects[idx] = project.copyWith(
                                        name: name,
                                        workspacePath: path,
                                      );
                                    }
                                  });
                                },
                              ),
                            );
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline,
                              size: 20, color: Colors.red),
                          tooltip: isCurrent
                              ? 'Cannot delete active project'
                              : 'Delete Project',
                          onPressed: isCurrent
                              ? null
                              : () {
                                  _showDeleteConfirmation(context, project);
                                },
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  void _showDeleteConfirmation(BuildContext context, Project project) {
    showDialog(
      context: context,
      builder: (context) => DeleteConfirmationDialog(
        project: project,
        onConfirm: () async {
          await widget.onDelete(project);
          setState(() {
            _localProjects.removeWhere((p) => p.id == project.id);
          });
        },
      ),
    );
  }
}

class DeleteConfirmationDialog extends StatefulWidget {
  final Project project;
  final VoidCallback onConfirm;

  const DeleteConfirmationDialog({
    super.key,
    required this.project,
    required this.onConfirm,
  });

  @override
  State<DeleteConfirmationDialog> createState() =>
      _DeleteConfirmationDialogState();
}

class _DeleteConfirmationDialogState extends State<DeleteConfirmationDialog> {
  final _confirmController = TextEditingController();
  bool _isNameMatched = false;

  @override
  void dispose() {
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Delete Project?'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Are you sure you want to delete "${widget.project.name}"?',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            _buildInfoRow('Created', widget.project.createdAt),
            _buildInfoRow('Cards', widget.project.cardCount.toString()),
            if (widget.project.workspacePath != null)
              _buildInfoRow('Workspace', widget.project.workspacePath!),
            const SizedBox(height: 16),
            const Text(
              'This action cannot be undone and will delete all cards, columns, and history associated with this project.',
              style: TextStyle(color: Colors.red, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _confirmController,
              decoration: InputDecoration(
                labelText: 'Type project name to confirm',
                hintText: widget.project.name,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (value) {
                setState(() {
                  _isNameMatched = value == widget.project.name;
                });
              },
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
          onPressed: _isNameMatched
              ? () {
                  Navigator.pop(context);
                  widget.onConfirm();
                }
              : null,
          style: TextButton.styleFrom(foregroundColor: Colors.red),
          child: const Text('Delete Permanently'),
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text('$label: ', style: const TextStyle(fontWeight: FontWeight.w500)),
          Text(value),
        ],
      ),
    );
  }
}

class ProjectEditDialog extends StatefulWidget {
  final Project project;
  final Function(String name, String? workspacePath) onUpdate;

  const ProjectEditDialog({
    super.key,
    required this.project,
    required this.onUpdate,
  });

  @override
  State<ProjectEditDialog> createState() => _ProjectEditDialogState();
}

class _ProjectEditDialogState extends State<ProjectEditDialog> {
  late TextEditingController _nameController;
  late TextEditingController _workspaceController;
  bool _isUpdating = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.project.name);
    _workspaceController =
        TextEditingController(text: widget.project.workspacePath ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _workspaceController.dispose();
    super.dispose();
  }

  void _handleUpdate() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a project name')),
      );
      return;
    }

    setState(() => _isUpdating = true);
    widget.onUpdate(
      name,
      _workspaceController.text.trim().isEmpty
          ? null
          : _workspaceController.text.trim(),
    );
    Navigator.pop(context); // Close edit dialog
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.edit, color: Theme.of(context).primaryColor),
          const SizedBox(width: 8),
          const Text('Edit Project'),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Project Name',
                prefixIcon: Icon(Icons.folder),
                border: OutlineInputBorder(),
              ),
              autofocus: true,
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _workspaceController,
              decoration: const InputDecoration(
                labelText: 'Workspace Path',
                prefixIcon: Icon(Icons.folder_open),
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isUpdating ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isUpdating ? null : _handleUpdate,
          child: _isUpdating
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save Changes'),
        ),
      ],
    );
  }
}
