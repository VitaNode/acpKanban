import 'package:flutter/material.dart';
import '../models/project_roadmap.dart';
import '../services/acp_client.dart';

class ProjectRoadmapView extends StatefulWidget {
  final String projectId;
  final Function(String cardId) onCardTap;
  final VoidCallback? onManageTap;

  const ProjectRoadmapView({
    Key? key,
    required this.projectId,
    required this.onCardTap,
    this.onManageTap,
  }) : super(key: key);

  @override
  State<ProjectRoadmapView> createState() => _ProjectRoadmapViewState();
}

class _ProjectRoadmapViewState extends State<ProjectRoadmapView> {
  List<ProjectMilestone>? _roadmap;
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRoadmap();
  }

  Future<void> _loadRoadmap() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final data =
          await ACPClient().getProjectProgress(widget.projectId, depth: 3);
      setState(() {
        _roadmap = data.map((m) => ProjectMilestone.fromJson(m)).toList();
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Error: $_error', style: const TextStyle(color: Colors.red)),
            ElevatedButton(onPressed: _loadRoadmap, child: const Text('Retry')),
          ],
        ),
      );
    }

    return Column(
      children: [
        if (widget.onManageTap != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.alt_route_rounded, size: 20),
                const SizedBox(width: 12),
                const Text('PROJECT ROADMAP',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        letterSpacing: 0.5)),
                const Spacer(),
                TextButton.icon(
                  onPressed: widget.onManageTap,
                  icon: const Icon(Icons.edit_note_rounded, size: 18),
                  label: const Text('Manage'),
                  style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact),
                ),
              ],
            ),
          ),
        Expanded(
          child: (_roadmap == null || _roadmap!.isEmpty)
              ? const Center(child: Text('No roadmap items defined.'))
              : RefreshIndicator(
                  onRefresh: _loadRoadmap,
                  child: ListView.builder(
                    itemCount: _roadmap!.length,
                    itemBuilder: (context, index) {
                      final milestone = _roadmap![index];
                      return _buildMilestoneTile(milestone);
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildMilestoneTile(ProjectMilestone milestone) {
    return ExpansionTile(
      title: Text(
        milestone.title,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      subtitle: Text('Progress: ${milestone.progress.toStringAsFixed(1)}%'),
      leading: const Icon(Icons.flag),
      children: milestone.features.map((f) => _buildFeatureTile(f)).toList(),
    );
  }

  Widget _buildFeatureTile(ProjectFeature feature) {
    return Padding(
      padding: const EdgeInsets.only(left: 16.0),
      child: ExpansionTile(
        title: Text(
          feature.title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        subtitle: Text('Progress: ${feature.progress.toStringAsFixed(1)}%'),
        leading: const Icon(Icons.extension, size: 18),
        children: [
          _buildStatusGroup('Completed', feature.counts['completed'] ?? 0,
              Colors.green, feature.cards, 'completed'),
          _buildStatusGroup('Active', feature.counts['active'] ?? 0,
              Colors.blue, feature.cards, 'active'),
          _buildStatusGroup('Plan', feature.counts['plan'] ?? 0, Colors.grey,
              feature.cards, 'plan'),
        ],
      ),
    );
  }

  Widget _buildStatusGroup(String label, int count, Color color,
      List<RoadmapCardSummary>? allCards, String status) {
    final statusCards =
        allCards?.where((c) => c.planStatus == status).toList() ?? [];

    return Padding(
      padding: const EdgeInsets.only(left: 32.0),
      child: ExpansionTile(
        title: Text(
          '$label ($count cards)',
          style: TextStyle(fontSize: 13, color: color),
        ),
        dense: true,
        children: statusCards
            .map((c) => ListTile(
                  title: Text(c.title, style: const TextStyle(fontSize: 12)),
                  onTap: () => widget.onCardTap(c.id),
                  dense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 48.0, vertical: 0),
                  visualDensity: VisualDensity.compact,
                ))
            .toList(),
      ),
    );
  }
}
