import 'package:flutter/material.dart';
import '../models/project.dart';
import '../constants/app_constants.dart';
import '../theme/app_theme.dart';
import '../constants/ui_copy.dart';
import 'app_feedback.dart';

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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

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
        label: const Text(UICopy.newProject),
      );
    }

    return PopupMenuButton<String>(
      tooltip: UICopy.switchProject,
      offset: const Offset(0, 45),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusMedium)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppConstants.space12, vertical: AppConstants.space8),
        decoration: BoxDecoration(
          color: colorScheme.primary.withOpacity(0.08),
          borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
          border: Border.all(color: colorScheme.primary.withOpacity(0.15)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_rounded, size: 16, color: colorScheme.primary),
            const SizedBox(width: AppConstants.space8),
            Text(
              currentProject?.name ?? UICopy.selectProject,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(width: AppConstants.space4),
            Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: colorScheme.primary),
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
                  color: isCurrent ? colorScheme.primary : colorScheme.onSurface.withOpacity(AppConstants.mediumEmphasis),
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
                          color: isCurrent ? colorScheme.primary : colorScheme.onSurface,
                        ),
                      ),
                      Text(
                        '${UICopy.lastActive}: ${project.lastActive}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (isCurrent)
                  Icon(Icons.check_rounded, size: 18, color: colorScheme.primary),
              ],
            ),
          );
        }),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: '_manage_',
          child: Row(
            children: [
              Icon(Icons.settings_suggest_rounded, size: 20, color: colorScheme.primary),
              const SizedBox(width: AppConstants.space12),
              Text(UICopy.manageProjects, style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: '_create_',
          child: Row(
            children: [
              Icon(Icons.add_rounded, size: 20, color: colorScheme.primary),
              const SizedBox(width: AppConstants.space12),
              Text(UICopy.newProject, style: theme.textTheme.bodyMedium),
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
      AppFeedback.showError(context, UICopy.enterProjectName);
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final size = MediaQuery.of(context).size;
    
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.create_new_folder_rounded, color: colorScheme.primary),
          const SizedBox(width: AppConstants.space12),
          Text(UICopy.newProject, style: theme.textTheme.headlineMedium),
        ],
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusMedium)),
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
                    labelText: UICopy.projectName,
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
                    labelText: UICopy.projectDescription,
                    hintText: UICopy.briefDescription,
                    prefixIcon: Icon(Icons.description_rounded),
                  ),
                  maxLines: 3,
                ),
                const SizedBox(height: AppConstants.space8),
                Text(
                  UICopy.descriptionHint,
                  style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.primary),
                ),
                const SizedBox(height: AppConstants.space16),
                TextField(
                  controller: _workspaceController,
                  decoration: const InputDecoration(
                    labelText: UICopy.workspacePath,
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
          child: const Text(UICopy.cancel),
        ),
        ElevatedButton(
          onPressed: _isCreating ? null : _handleCreate,
          style: ElevatedButton.styleFrom(
            backgroundColor: colorScheme.primary,
            foregroundColor: colorScheme.onPrimary,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusSmall)),
          ),
          child: _isCreating
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text(UICopy.create),
        ),
      ],
    );
  }
}
