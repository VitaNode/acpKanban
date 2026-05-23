import 'package:flutter/material.dart';
import '../services/acp_client.dart';
import '../models/project_roadmap.dart';
import '../constants/app_constants.dart';
import '../utils/app_logger.dart';

class RoadmapManagerDialog extends StatefulWidget {
  final String projectId;
  final String? initialFeatureId;
  final Function(ProjectMilestone milestone, ProjectFeature? feature)?
      onFeatureSelected;

  const RoadmapManagerDialog({
    Key? key,
    required this.projectId,
    this.initialFeatureId,
    this.onFeatureSelected,
  }) : super(key: key);

  @override
  State<RoadmapManagerDialog> createState() => _RoadmapManagerDialogState();
}

class _RoadmapManagerDialogState extends State<RoadmapManagerDialog> {
  List<ProjectMilestone> _milestones = [];
  ProjectMilestone? _selectedMilestone;
  ProjectFeature? _selectedFeature;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final data =
          await ACPClient().getProjectProgress(widget.projectId, depth: 2);
      final milestones = data.map((m) => ProjectMilestone.fromJson(m)).toList();

      ProjectMilestone? foundMilestone;
      ProjectFeature? foundFeature;

      if (widget.initialFeatureId != null) {
        for (var m in milestones) {
          for (var f in m.features) {
            if (f.id == widget.initialFeatureId) {
              foundMilestone = m;
              foundFeature = f;
              break;
            }
          }
          if (foundFeature != null) break;
        }
      }

      setState(() {
        _milestones = milestones;
        _selectedMilestone =
            foundMilestone ?? (milestones.isNotEmpty ? milestones.first : null);
        _selectedFeature = foundFeature;
        _isLoading = false;
      });
    } catch (e) {
      AppLogger.error('Load roadmap error', e);
      setState(() => _isLoading = false);
    }
  }

  Future<String?> _showInputDialog({
    required String title,
    required String label,
    String? initialValue,
    String confirmLabel = 'Confirm',
  }) async {
    final controller = TextEditingController(text: initialValue ?? '');
    final focusNode = FocusNode();
    String? errorText;

    return showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(title),
              content: TextField(
                controller: controller,
                focusNode: focusNode,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: label,
                  errorText: errorText,
                ),
                onChanged: (_) {
                  if (errorText != null) {
                    setDialogState(() => errorText = null);
                  }
                },
                onSubmitted: (value) {
                  if (value.trim().isEmpty) {
                    setDialogState(() => errorText = 'Title cannot be empty');
                  } else {
                    Navigator.pop(ctx, value.trim());
                  }
                },
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    final text = controller.text.trim();
                    if (text.isEmpty) {
                      setDialogState(() => errorText = 'Title cannot be empty');
                    } else {
                      Navigator.pop(ctx, text);
                    }
                  },
                  child: Text(confirmLabel),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<bool> _showDeleteConfirmation({
    required String type,
    required String name,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete $type'),
        content: Text(
          'Are you sure you want to delete "$name"?\n\n'
          'Cards linked to this $type will be unlinked (feature set to empty), '
          'but will NOT be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _addMilestone() async {
    final result = await _showInputDialog(
      title: 'New Milestone',
      label: 'Milestone Title',
      confirmLabel: 'Create',
    );
    if (result != null) {
      await ACPClient().createMilestone(widget.projectId, result);
      _loadData();
    }
  }

  Future<void> _editMilestone(ProjectMilestone milestone) async {
    final result = await _showInputDialog(
      title: 'Edit Milestone',
      label: 'Milestone Title',
      initialValue: milestone.title,
      confirmLabel: 'Save',
    );
    if (result != null && result != milestone.title) {
      await ACPClient().updateMilestone(milestone.id, title: result);
      _loadData();
    }
  }

  Future<void> _deleteMilestone(ProjectMilestone milestone) async {
    final confirmed = await _showDeleteConfirmation(
      type: 'milestone',
      name: milestone.title,
    );
    if (!confirmed) return;
    await ACPClient().deleteMilestone(milestone.id);
    setState(() {
      _selectedMilestone =
          _selectedMilestone?.id == milestone.id ? null : _selectedMilestone;
    });
    _loadData();
  }

  Future<void> _addFeature() async {
    if (_selectedMilestone == null) return;

    final result = await _showInputDialog(
      title: 'New Feature for ${_selectedMilestone!.title}',
      label: 'Feature Title',
      confirmLabel: 'Create',
    );
    if (result != null) {
      await ACPClient().createFeature(_selectedMilestone!.id, result);
      _loadData();
    }
  }

  Future<void> _editFeature(ProjectFeature feature) async {
    final result = await _showInputDialog(
      title: 'Edit Feature',
      label: 'Feature Title',
      initialValue: feature.title,
      confirmLabel: 'Save',
    );
    if (result != null && result != feature.title) {
      await ACPClient().updateFeature(feature.id, title: result);
      _loadData();
    }
  }

  Future<void> _deleteFeature(ProjectFeature feature) async {
    final confirmed = await _showDeleteConfirmation(
      type: 'feature',
      name: feature.title,
    );
    if (!confirmed) return;
    await ACPClient().deleteFeature(feature.id);
    _loadData();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final size = MediaQuery.of(context).size;
    final isMobile = size.width < 600;

    return Dialog(
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppConstants.radiusLarge)),
      child: Container(
        width: isMobile ? size.width * 0.95 : size.width * 0.8,
        height: isMobile ? size.height * 0.9 : size.height * 0.8,
        padding: const EdgeInsets.all(AppConstants.space16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'Roadmap Planning',
                    style: theme.textTheme.headlineSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close)),
              ],
            ),
            const Divider(),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : isMobile
                      ? _buildMobileLayout(theme, colorScheme)
                      : _buildDesktopLayout(theme, colorScheme),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDesktopLayout(ThemeData theme, ColorScheme colorScheme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: _buildMilestonesColumn(theme, colorScheme),
        ),
        const VerticalDivider(),
        Expanded(
          flex: 3,
          child: _buildFeaturesColumn(theme, colorScheme),
        ),
      ],
    );
  }

  Widget _buildMobileLayout(ThemeData theme, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 200,
          child: _buildMilestonesColumn(theme, colorScheme),
        ),
        const Divider(),
        Expanded(
          child: _buildFeaturesColumn(theme, colorScheme),
        ),
      ],
    );
  }

  Widget _buildMilestonesColumn(ThemeData theme, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Milestones', style: theme.textTheme.titleMedium),
              IconButton(
                icon: const Icon(Icons.add_circle_outline, size: 20),
                onPressed: _addMilestone,
                tooltip: 'Add Milestone',
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _milestones.length,
            itemBuilder: (context, index) {
              final m = _milestones[index];
              final isSelected = _selectedMilestone?.id == m.id;
              return ListTile(
                title: Text(
                  m.title,
                  style: TextStyle(
                      fontWeight: isSelected ? FontWeight.bold : null,
                      fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
                selected: isSelected,
                selectedTileColor:
                    colorScheme.primaryContainer.withOpacity(0.3),
                onTap: () => setState(() {
                  _selectedMilestone = m;
                  if (_selectedFeature != null &&
                      !m.features.any((f) => f.id == _selectedFeature!.id)) {
                    _selectedFeature = null;
                  }
                }),
                trailing: PopupMenuButton<String>(
                  icon: Icon(
                    Icons.more_vert,
                    size: 16,
                    color: isSelected
                        ? colorScheme.primary
                        : colorScheme.onSurface.withOpacity(0.5),
                  ),
                  onSelected: (action) {
                    switch (action) {
                      case 'edit':
                        _editMilestone(m);
                      case 'delete':
                        _deleteMilestone(m);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'edit',
                      child: ListTile(
                        leading: Icon(Icons.edit_outlined, size: 18),
                        title: Text('Edit'),
                        dense: true,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: ListTile(
                        leading:
                            Icon(Icons.delete_outline, size: 18, color: Colors.red),
                        title: Text('Delete', style: TextStyle(color: Colors.red)),
                        dense: true,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
                dense: true,
                visualDensity: VisualDensity.compact,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildFeaturesColumn(ThemeData theme, ColorScheme colorScheme) {
    if (_selectedMilestone == null) {
      return const Center(child: Text('Select a milestone to manage features'));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  'Features: ${_selectedMilestone!.title}',
                  style: theme.textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_circle_outline, size: 20),
                onPressed: _addFeature,
                tooltip: 'Add Feature',
              ),
            ],
          ),
        ),
        Expanded(
          child: _selectedMilestone!.features.isEmpty
              ? const Center(
                  child: Text('No features defined for this milestone.'))
              : ListView.builder(
                  itemCount: _selectedMilestone!.features.length,
                  itemBuilder: (context, index) {
                    final f = _selectedMilestone!.features[index];
                    final isSelected = _selectedFeature?.id == f.id;
                    return ListTile(
                      leading: Icon(
                        Icons.extension_outlined,
                        size: 16,
                        color: isSelected ? colorScheme.primary : null,
                      ),
                      title: Text(
                        f.title,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: isSelected ? FontWeight.bold : null,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      selected: isSelected,
                      selectedTileColor:
                          colorScheme.primaryContainer.withOpacity(0.3),
                      subtitle: Text(
                          'Progress: ${f.progress.toStringAsFixed(1)}%',
                          style: const TextStyle(fontSize: 11)),
                      trailing: PopupMenuButton<String>(
                        icon: Icon(Icons.more_vert, size: 16,
                            color: colorScheme.onSurface.withOpacity(0.5)),
                        onSelected: (action) {
                          switch (action) {
                            case 'edit':
                              _editFeature(f);
                            case 'delete':
                              _deleteFeature(f);
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: 'edit',
                            child: ListTile(
                              leading: Icon(Icons.edit_outlined, size: 18),
                              title: Text('Edit'),
                              dense: true,
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'delete',
                            child: ListTile(
                              leading: Icon(Icons.delete_outline, size: 18,
                                  color: Colors.red),
                              title: Text('Delete',
                                  style: TextStyle(color: Colors.red)),
                              dense: true,
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                        ],
                      ),
                      onTap: () {
                        setState(() => _selectedFeature = f);
                        if (widget.onFeatureSelected != null) {
                          widget.onFeatureSelected!(_selectedMilestone!, f);
                        }
                      },
                      dense: true,
                      visualDensity: VisualDensity.compact,
                    );
                  },
                ),
        ),
      ],
    );
  }
}
