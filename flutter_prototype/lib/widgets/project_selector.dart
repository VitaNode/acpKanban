import 'package:flutter/material.dart';
import '../models/project.dart';

class ProjectSelector extends StatelessWidget {
  final Project? currentProject;
  final List<Project> projects;
  final Function(Project) onProjectSelected;
  final VoidCallback onCreateProject;
  final VoidCallback? onManageProjects;
  final bool isLoading;

  const ProjectSelector({
    super.key,
    this.currentProject,
    required this.projects,
    required this.onProjectSelected,
    required this.onCreateProject,
    this.onManageProjects,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    if (projects.isEmpty) {
      return TextButton.icon(
        onPressed: onCreateProject,
        icon: const Icon(Icons.add, size: 18),
        label: const Text('New Project'),
      );
    }

    return PopupMenuButton<String>(
      tooltip: 'Switch Project',
      offset: const Offset(0, 45),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Theme.of(context).primaryColor.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder, size: 18),
            const SizedBox(width: 8),
            Text(
              currentProject?.name ?? 'Select Project',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down, size: 20),
          ],
        ),
      ),
      itemBuilder: (context) => [
        ...projects.map((project) => PopupMenuItem<String>(
              value: project.id,
              child: Row(
                children: [
                  Icon(
                    project.id == currentProject?.id
                        ? Icons.folder_open
                        : Icons.folder,
                    size: 20,
                    color: project.id == currentProject?.id
                        ? Theme.of(context).primaryColor
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          project.name,
                          style: TextStyle(
                            fontWeight: project.id == currentProject?.id
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                        Text(
                          project.lastActive,
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (project.id == currentProject?.id)
                    Icon(Icons.check,
                        size: 18, color: Theme.of(context).primaryColor),
                ],
              ),
            )),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: '_manage_',
          child: Row(
            children: [
              Icon(Icons.settings_suggest, color: Theme.of(context).primaryColor),
              const SizedBox(width: 12),
              const Text('Manage Projects...'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: '_create_',
          child: Row(
            children: [
              Icon(Icons.add, color: Theme.of(context).primaryColor),
              const SizedBox(width: 12),
              const Text('New Project'),
            ],
          ),
        ),
      ],
      onSelected: (value) {
        if (value == '_create_') {
          onCreateProject();
        } else if (value == '_manage_') {
          if (onManageProjects != null) onManageProjects!();
        } else {
          final project = projects.firstWhere((p) => p.id == value);
          onProjectSelected(project);
        }
      },
    );
  }
}

class ProjectCreationDialog extends StatefulWidget {
  final Function(String name, String? workspacePath, String? description) onCreate;

  const ProjectCreationDialog({
    super.key,
    required this.onCreate,
  });

  @override
  State<ProjectCreationDialog> createState() => _ProjectCreationDialogState();
}

class _ProjectCreationDialogState extends State<ProjectCreationDialog> {
  final _nameController = TextEditingController();
  final _workspaceController = TextEditingController();
  final _descriptionController = TextEditingController();
  bool _isCreating = false;

  @override
  void dispose() {
    _nameController.dispose();
    _workspaceController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _handleCreate() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a project name')),
      );
      return;
    }

    setState(() => _isCreating = true);
    final desc = _descriptionController.text.trim();
    widget.onCreate(
      name,
      _workspaceController.text.trim().isEmpty
          ? null
          : _workspaceController.text.trim(),
      desc.isEmpty ? null : desc,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.create_new_folder, color: Theme.of(context).primaryColor),
          const SizedBox(width: 8),
          const Text('New Project'),
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
                hintText: 'e.g., My App Development',
                prefixIcon: Icon(Icons.folder),
                border: OutlineInputBorder(),
              ),
              autofocus: true,
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: 'Project Description',
                hintText: 'Brief description of this project...',
                prefixIcon: Icon(Icons.description),
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 8),
            Text(
              '💡 Project description will be included in the context sent to LLM during card conversations.',
              style: TextStyle(fontSize: 11, color: Colors.blue[700]),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _workspaceController,
              decoration: const InputDecoration(
                labelText: 'Workspace Path (optional)',
                hintText: 'e.g., /Users/username/projects/myapp',
                prefixIcon: Icon(Icons.folder_open),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'The workspace path is the root directory for this project\'s files.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isCreating ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isCreating ? null : _handleCreate,
          child: _isCreating
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create'),
        ),
      ],
    );
  }
}
