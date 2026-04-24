import 'package:flutter/material.dart';
import '../models/project.dart';
import '../constants/app_constants.dart';
import '../theme/app_theme.dart';
import 'project_indexing_widget.dart';

class ProjectManagementDialog extends StatefulWidget {
  final List<Project> projects;
  final Function(Project, String name, String? workspacePath, {String? description}) onUpdate;
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final size = MediaQuery.of(context).size;

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.settings_suggest_rounded, color: colorScheme.primary),
          const SizedBox(width: AppConstants.space12),
          Text('Manage Projects', style: theme.textTheme.headlineMedium),
        ],
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusMedium)),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 500,
          maxHeight: size.height * 0.7,
        ),
        child: SizedBox(
          width: size.width * 0.9,
          child: _localProjects.isEmpty
              ? const Center(child: Text('No projects available.'))
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: _localProjects.length,
                  separatorBuilder: (context, index) => const SizedBox(height: AppConstants.space8),
                  itemBuilder: (context, index) {
                    final project = _localProjects[index];
                    final isCurrent = project.id == widget.currentProject?.id;
                    return Container(
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainer,
                        borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: AppConstants.space12, vertical: AppConstants.space4),
                        leading: Icon(
                          isCurrent ? Icons.folder_open_rounded : Icons.folder_rounded,
                          color: isCurrent ? colorScheme.primary : colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis),
                        ),
                        title: Text(
                          project.name,
                          style: TextStyle(
                            fontWeight: isCurrent ? FontWeight.bold : FontWeight.w600,
                            color: isCurrent ? colorScheme.primary : theme.textTheme.bodyLarge?.color,
                          ),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 2),
                            Text(
                              project.workspacePath ?? "No workspace path set",
                              style: theme.textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              'Last active: ${project.lastActive}',
                              style: theme.textTheme.bodySmall?.copyWith(fontSize: 10),
                            ),
                          ],
                        ),
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
                                    onUpdate: (name, path, desc) async {
                                      await widget.onUpdate(project, name, path, description: desc);
                                      setState(() {
                                        final idx = _localProjects.indexWhere((p) => p.id == project.id);
                                        if (idx != -1) {
                                          _localProjects[idx] = project.copyWith(
                                            name: name,
                                            workspacePath: path,
                                            description: desc,
                                          );
                                        }
                                      });
                                    },
                                  ),
                                );
                              },
                            ),
                            IconButton(
                              icon: Icon(Icons.delete_outline_rounded,
                                  size: 20, color: colorScheme.error),
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
                      ),
                    );
                  },
                ),
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final size = MediaQuery.of(context).size;

    return AlertDialog(
      title: const Text('Delete Project?'),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusMedium)),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 400,
          maxHeight: size.height * 0.7,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Are you sure you want to delete "${widget.project.name}"?',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: AppConstants.space16),
              _buildInfoRow('Created', widget.project.createdAt),
              _buildInfoRow('Cards', widget.project.cardCount.toString()),
              if (widget.project.workspacePath != null)
                _buildInfoRow('Workspace', widget.project.workspacePath!),
              const SizedBox(height: AppConstants.space16),
              Text(
                'This action cannot be undone and will delete all cards, columns, and history associated with this project.',
                style: TextStyle(color: colorScheme.error, fontSize: 12),
              ),
              const SizedBox(height: AppConstants.space16),
              TextField(
                controller: _confirmController,
                decoration: InputDecoration(
                  labelText: 'Type project name to confirm',
                  hintText: widget.project.name,
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
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isNameMatched
              ? () {
                  Navigator.pop(context);
                  widget.onConfirm();
                }
              : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: colorScheme.error,
            foregroundColor: colorScheme.onError,
          ),
          child: const Text('Delete Permanently'),
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$label: ', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }
}

class ProjectEditDialog extends StatefulWidget {
  final Project project;
  final Function(String name, String? workspacePath, String? description) onUpdate;

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
  late TextEditingController _descriptionController;
  bool _isUpdating = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.project.name);
    _workspaceController =
        TextEditingController(text: widget.project.workspacePath ?? '');
    _descriptionController =
        TextEditingController(text: widget.project.description ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _workspaceController.dispose();
    _descriptionController.dispose();
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
    final desc = _descriptionController.text.trim();
    widget.onUpdate(
      name,
      _workspaceController.text.trim().isEmpty
          ? null
          : _workspaceController.text.trim(),
      desc.isEmpty ? null : desc,
    );
    Navigator.pop(context); // Close edit dialog
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final size = MediaQuery.of(context).size;

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.edit_rounded, color: colorScheme.primary),
          const SizedBox(width: AppConstants.space12),
          Text('Edit Project', style: theme.textTheme.headlineMedium),
        ],
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusMedium)),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 450,
          maxHeight: size.height * 0.75,
        ),
        child: SizedBox(
          width: size.width * 0.9,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Project Name',
                    prefixIcon: Icon(Icons.folder_rounded),
                  ),
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                ),
                const SizedBox(height: AppConstants.space16),
                TextField(
                  controller: _descriptionController,
                  decoration: const InputDecoration(
                    labelText: 'Project Description',
                    hintText: 'Brief description...',
                    prefixIcon: Icon(Icons.description_rounded),
                  ),
                  maxLines: 3,
                ),
                const SizedBox(height: AppConstants.space8),
                Text(
                  '💡 Description is included in the AI context.',
                  style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.primary),
                ),
                const SizedBox(height: AppConstants.space16),
                TextField(
                  controller: _workspaceController,
                  decoration: const InputDecoration(
                    labelText: 'Workspace Path',
                    prefixIcon: Icon(Icons.folder_open_rounded),
                  ),
                ),
                const SizedBox(height: AppConstants.space16),
                ProjectIndexingWidget(project: widget.project),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isUpdating ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isUpdating ? null : _handleUpdate,
          style: ElevatedButton.styleFrom(
            backgroundColor: colorScheme.primary,
            foregroundColor: colorScheme.onPrimary,
          ),
          child: _isUpdating
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Save Changes'),
        ),
      ],
    );
  }
}
