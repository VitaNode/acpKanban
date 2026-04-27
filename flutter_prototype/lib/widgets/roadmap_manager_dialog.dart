import 'package:flutter/material.dart';
import '../services/acp_client.dart';
import '../models/project_roadmap.dart';
import '../constants/app_constants.dart';

class RoadmapManagerDialog extends StatefulWidget {
  final String projectId;

  const RoadmapManagerDialog({
    Key? key,
    required this.projectId,
  }) : super(key: key);

  @override
  State<RoadmapManagerDialog> createState() => _RoadmapManagerDialogState();
}

class _RoadmapManagerDialogState extends State<RoadmapManagerDialog> {
  List<ProjectMilestone> _milestones = [];
  ProjectMilestone? _selectedMilestone;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final data = await ACPClient().getProjectProgress(widget.projectId, depth: 2);
      final milestones = data.map((m) => ProjectMilestone.fromJson(m)).toList();
      setState(() {
        _milestones = milestones;
        if (_selectedMilestone != null) {
          _selectedMilestone = milestones.firstWhere(
            (m) => m.id == _selectedMilestone!.id,
            orElse: () => milestones.isNotEmpty ? milestones.first : null!,
          );
        } else if (milestones.isNotEmpty) {
          _selectedMilestone = milestones.first;
        }
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Load roadmap error: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _addMilestone() async {
    final titleController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Milestone'),
        content: TextField(
          controller: titleController,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Milestone Title'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, titleController.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      await ACPClient().createMilestone(widget.projectId, result);
      _loadData();
    }
  }

  Future<void> _addFeature() async {
    if (_selectedMilestone == null) return;
    
    final titleController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('New Feature for ${_selectedMilestone!.title}'),
        content: TextField(
          controller: titleController,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Feature Title'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, titleController.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      await ACPClient().createFeature(_selectedMilestone!.id, result);
      _loadData();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final size = MediaQuery.of(context).size;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusLarge)),
      child: Container(
        width: size.width * 0.8,
        height: size.height * 0.8,
        padding: const EdgeInsets.all(AppConstants.space16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Project Roadmap Planning', style: theme.textTheme.headlineSmall),
                IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
              ],
            ),
            const Divider(),
            Expanded(
              child: _isLoading 
                ? const Center(child: CircularProgressIndicator())
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // L1: Milestones
                      Expanded(
                        flex: 2,
                        child: Column(
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
                                    title: Text(m.title, style: TextStyle(fontWeight: isSelected ? FontWeight.bold : null)),
                                    selected: isSelected,
                                    selectedTileColor: colorScheme.primaryContainer.withOpacity(0.3),
                                    onTap: () => setState(() => _selectedMilestone = m),
                                    trailing: isSelected ? const Icon(Icons.chevron_right) : null,
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      const VerticalDivider(),
                      // L2: Features
                      Expanded(
                        flex: 3,
                        child: _selectedMilestone == null
                          ? const Center(child: Text('Select a milestone to manage features'))
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.all(8.0),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text('Features under ${_selectedMilestone!.title}', style: theme.textTheme.titleMedium),
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
                                    ? const Center(child: Text('No features defined for this milestone.'))
                                    : ListView.builder(
                                        itemCount: _selectedMilestone!.features.length,
                                        itemBuilder: (context, index) {
                                          final f = _selectedMilestone!.features[index];
                                          return ListTile(
                                            leading: const Icon(Icons.extension_outlined, size: 18),
                                            title: Text(f.title),
                                            subtitle: Text('Progress: ${f.progress.toStringAsFixed(1)}%'),
                                            trailing: IconButton(
                                              icon: const Icon(Icons.delete_outline, size: 18),
                                              onPressed: () async {
                                                await ACPClient().deleteFeature(f.id);
                                                _loadData();
                                              },
                                            ),
                                          );
                                        },
                                      ),
                                ),
                              ],
                            ),
                      ),
                    ],
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
