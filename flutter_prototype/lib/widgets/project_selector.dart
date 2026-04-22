import 'package:flutter/material.dart';
import '../models/project.dart';
import '../constants/app_constants.dart';

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
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    if (projects.isEmpty) {
      return TextButton.icon(
        onPressed: onCreateProject,
        icon: const Icon(Icons.add_rounded, size: 18),
        label: const Text('New Project'),
      );
    }

    return PopupMenuButton<String>(
      tooltip: 'Switch Project',
      offset: const Offset(0, 45),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.space12)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppConstants.space12, vertical: AppConstants.space6),
        decoration: BoxDecoration(
          color: AppConstants.primaryColor.withOpacity(0.08),
          borderRadius: BorderRadius.circular(AppConstants.space8),
          border: Border.all(color: AppConstants.primaryColor.withOpacity(0.15)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder_rounded, size: 16, color: AppConstants.primaryColor),
            const SizedBox(width: AppConstants.space8),
            Text(
              currentProject?.name ?? 'Select Project',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: AppConstants.primaryColor,
              ),
            ),
            const SizedBox(width: AppConstants.space4),
            const Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: AppConstants.primaryColor),
          ],
        ),
      ),
      itemBuilder: (context) => [
        ...projects.map((project) {
          final isCurrent = project.id == currentProject?.id;
          return PopupMenuItem<String>(
            value: project.id,
            child: Row(
              children: [
                Icon(
                  isCurrent ? Icons.folder_open_rounded : Icons.folder_rounded,
                  size: 20,
                  color: isCurrent ? AppConstants.primaryColor : AppConstants.textHint,
                ),
                const SizedBox(width: AppConstants.space12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        project.name,
                        style: TextStyle(
                          fontWeight: isCurrent ? FontWeight.bold : FontWeight.w600,
                          color: isCurrent ? AppConstants.primaryColor : AppConstants.textPrimary,
                        ),
                      ),
                      Text(
                        'Last active: ${project.lastActive}',
                        style: const TextStyle(fontSize: 10, color: AppConstants.textHint),
                      ),
                    ],
                  ),
                ),
                if (isCurrent)
                  const Icon(Icons.check_rounded, size: 18, color: AppConstants.primaryColor),
              ],
            ),
          );
        }),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: '_manage_',
          child: Row(
            children: [
              const Icon(Icons.settings_suggest_rounded, size: 20, color: AppConstants.primaryColor),
              const SizedBox(width: AppConstants.space12),
              Text('Manage Projects...', style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: '_create_',
          child: Row(
            children: [
              const Icon(Icons.add_rounded, size: 20, color: AppConstants.primaryColor),
              const SizedBox(width: AppConstants.space12),
              Text('New Project', style: Theme.of(context).textTheme.bodyMedium),
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
    final size = MediaQuery.of(context).size;
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.create_new_folder_rounded, color: AppConstants.primaryColor),
          const SizedBox(width: AppConstants.space12),
          Text('New Project', style: Theme.of(context).textTheme.headlineMedium),
        ],
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.space16)),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 450,
          maxHeight: size.height * 0.7,
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
                    hintText: 'e.g., My App Development',
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
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppConstants.primaryColor),
                ),
                const SizedBox(height: AppConstants.space16),
                TextField(
                  controller: _workspaceController,
                  decoration: const InputDecoration(
                    labelText: 'Workspace Path',
                    prefixIcon: Icon(Icons.folder_open_rounded),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isCreating ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isCreating ? null : _handleCreate,
          child: _isCreating
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text('Create'),
        ),
      ],
    );
  }
}
