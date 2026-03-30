import 'dart:convert';
import 'dart:io';
import '../models/project.dart';

class ProjectService {
  static const String _baseUrl = 'http://localhost:8000';

  Future<List<Project>> getProjects() async {
    try {
      final response = await _get('/api/projects');
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((p) => Project.fromJson(p)).toList();
      }
      throw Exception('Failed to load projects: ${response.statusCode}');
    } catch (e) {
      debugPrint('getProjects error: $e');
      return [];
    }
  }

  Future<Project?> getProject(String projectId) async {
    try {
      final response = await _get('/api/projects/$projectId');
      if (response.statusCode == 200) {
        return Project.fromJson(jsonDecode(response.body));
      }
      return null;
    } catch (e) {
      debugPrint('getProject error: $e');
      return null;
    }
  }

  Future<Project?> createProject(String name, {String? workspacePath}) async {
    try {
      final response = await _post('/api/projects', {
        'name': name,
        if (workspacePath != null) 'workspace_path': workspacePath,
      });
      if (response.statusCode == 201) {
        return Project.fromJson(jsonDecode(response.body));
      }
      throw Exception('Failed to create project: ${response.statusCode}');
    } catch (e) {
      debugPrint('createProject error: $e');
      return null;
    }
  }

  Future<bool> updateProject(String projectId,
      {String? name, String? workspacePath}) async {
    try {
      final body = <String, dynamic>{};
      if (name != null) body['name'] = name;
      if (workspacePath != null) body['workspace_path'] = workspacePath;

      final response = await _put('/api/projects/$projectId', body);
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('updateProject error: $e');
      return false;
    }
  }

  Future<bool> deleteProject(String projectId) async {
    try {
      final response = await _delete('/api/projects/$projectId');
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('deleteProject error: $e');
      return false;
    }
  }

  Future<List<KanbanColumn>> getColumns(String projectId) async {
    try {
      final response = await _get('/api/projects/$projectId/columns');
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((c) => KanbanColumn.fromJson(c)).toList();
      }
      return [];
    } catch (e) {
      debugPrint('getColumns error: $e');
      return [];
    }
  }

  Future<ProjectSwitchData?> switchToProject(String projectId) async {
    try {
      final response = await _post('/api/projects/$projectId/switch', {});
      if (response.statusCode == 200) {
        return ProjectSwitchData.fromJson(jsonDecode(response.body));
      }
      return null;
    } catch (e) {
      debugPrint('switchToProject error: $e');
      return null;
    }
  }

  Future<KanbanColumn?> createColumn(String projectId, String name,
      {String? color}) async {
    try {
      final response = await _post('/api/projects/$projectId/columns', {
        'name': name,
        if (color != null) 'color': color,
      });
      if (response.statusCode == 201) {
        return KanbanColumn.fromJson(jsonDecode(response.body));
      }
      return null;
    } catch (e) {
      debugPrint('createColumn error: $e');
      return null;
    }
  }

  Future<List<KanbanCard>> getCardsByColumn(String columnId) async {
    try {
      final response = await _get('/api/columns/$columnId/cards');
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body)['cards'] ?? [];
        return data.map((c) => KanbanCard.fromJson(c)).toList();
      }
      return [];
    } catch (e) {
      debugPrint('getCardsByColumn error: $e');
      return [];
    }
  }

  Future<KanbanCard?> createCard(String columnId, String title,
      {String? description}) async {
    try {
      final response = await _post('/api/cards', {
        'column_id': columnId,
        'title': title,
        if (description != null) 'description': description,
      });
      if (response.statusCode == 201) {
        return KanbanCard.fromJson(jsonDecode(response.body));
      }
      return null;
    } catch (e) {
      debugPrint('createCard error: $e');
      return null;
    }
  }

  Future<List<TimelineEvent>> getTimeline(String projectId,
      {int limit = 100}) async {
    try {
      final response =
          await _get('/api/projects/$projectId/timeline?limit=$limit');
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic> events = data['events'] ?? [];
        return events.map((e) => TimelineEvent.fromJson(e)).toList();
      }
      return [];
    } catch (e) {
      debugPrint('getTimeline error: $e');
      return [];
    }
  }

  Future<Map<String, dynamic>?> getSessionHistory(String cardId) async {
    try {
      final response = await _get('/api/cards/$cardId/session');
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return null;
    } catch (e) {
      debugPrint('getSessionHistory error: $e');
      return null;
    }
  }

  Future<bool> addSessionMessage(
      String cardId, String role, String content) async {
    try {
      final response = await _post('/api/cards/$cardId/session', {
        'role': role,
        'content': content,
      });
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('addSessionMessage error: $e');
      return false;
    }
  }

  // HTTP helpers using dart:io
  Future<dynamic> _get(String path) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('$_baseUrl$path');
      final request = await client.getUrl(uri);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      return _HttpResponse(response.statusCode, body);
    } finally {
      client.close();
    }
  }

  Future<dynamic> _post(String path, Map<String, dynamic> body) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('$_baseUrl$path');
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close();
      final respBody = await response.transform(utf8.decoder).join();
      return _HttpResponse(response.statusCode, respBody);
    } finally {
      client.close();
    }
  }

  Future<dynamic> _put(String path, Map<String, dynamic> body) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('$_baseUrl$path');
      final request = await client.putUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close();
      final respBody = await response.transform(utf8.decoder).join();
      return _HttpResponse(response.statusCode, respBody);
    } finally {
      client.close();
    }
  }

  Future<dynamic> _delete(String path) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('$_baseUrl$path');
      final request = await client.deleteUrl(uri);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      return _HttpResponse(response.statusCode, body);
    } finally {
      client.close();
    }
  }

  void debugPrint(String msg) {
    // ignore: avoid_print
    print('[ProjectService] $msg');
  }
}

// Supporting models
class KanbanColumn {
  final String id;
  final String projectId;
  final String name;
  final int position;
  final String color;
  final int cardCount;

  KanbanColumn({
    required this.id,
    required this.projectId,
    required this.name,
    required this.position,
    required this.color,
    this.cardCount = 0,
  });

  factory KanbanColumn.fromJson(Map<String, dynamic> json) {
    return KanbanColumn(
      id: json['id'] ?? '',
      projectId: json['project_id'] ?? '',
      name: json['name'] ?? '',
      position: json['position'] ?? 0,
      color: json['color'] ?? '#808080',
      cardCount: json['card_count'] ?? 0,
    );
  }
}

class KanbanCard {
  final String id;
  final String columnId;
  final String title;
  final String description;
  final int position;
  final int sessionCount;
  final String createdAt;
  final String updatedAt;

  KanbanCard({
    required this.id,
    required this.columnId,
    required this.title,
    required this.description,
    required this.position,
    this.sessionCount = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  factory KanbanCard.fromJson(Map<String, dynamic> json) {
    return KanbanCard(
      id: json['id'] ?? '',
      columnId: json['column_id'] ?? '',
      title: json['title'] ?? '',
      description: json['description'] ?? '',
      position: json['position'] ?? 0,
      sessionCount: json['session_count'] ?? 0,
      createdAt: json['created_at'] ?? '',
      updatedAt: json['updated_at'] ?? '',
    );
  }
}

class TimelineEvent {
  final int id;
  final String projectId;
  final String? cardId;
  final String? cardTitle;
  final String eventType;
  final String? content;
  final Map<String, dynamic>? metadata;
  final String timestamp;

  TimelineEvent({
    required this.id,
    required this.projectId,
    this.cardId,
    this.cardTitle,
    required this.eventType,
    this.content,
    this.metadata,
    required this.timestamp,
  });

  factory TimelineEvent.fromJson(Map<String, dynamic> json) {
    return TimelineEvent(
      id: json['id'] ?? 0,
      projectId: json['project_id'] ?? '',
      cardId: json['card_id'],
      cardTitle: json['card_title'],
      eventType: json['event_type'] ?? '',
      content: json['content'],
      metadata: json['metadata'],
      timestamp: json['timestamp'] ?? '',
    );
  }

  String get icon {
    switch (eventType) {
      case 'card_created':
      case 'card_updated':
      case 'card_deleted':
        return '📋';
      case 'card_moved':
        return '🔄';
      case 'ai_action':
        return '🤖';
      case 'column_created':
      case 'column_updated':
      case 'column_deleted':
        return '📝';
      default:
        return '👤';
    }
  }
}

class _HttpResponse {
  final int statusCode;
  final String body;

  _HttpResponse(this.statusCode, this.body);
}

class ProjectSwitchData {
  final Project project;
  final List<ProjectColumnWithCards> columns;
  final List<TimelineEvent> timeline;
  final String message;

  ProjectSwitchData({
    required this.project,
    required this.columns,
    required this.timeline,
    required this.message,
  });

  factory ProjectSwitchData.fromJson(Map<String, dynamic> json) {
    return ProjectSwitchData(
      project: Project.fromJson(json['project']),
      columns: (json['columns'] as List)
          .map((c) => ProjectColumnWithCards.fromJson(c))
          .toList(),
      timeline: (json['timeline'] as List)
          .map((t) => TimelineEvent.fromJson(t))
          .toList(),
      message: json['message'] ?? '',
    );
  }
}

class ProjectColumnWithCards {
  final String id;
  final String name;
  final int position;
  final String color;
  final int cardCount;
  final List<ProjectCard> cards;

  ProjectColumnWithCards({
    required this.id,
    required this.name,
    required this.position,
    required this.color,
    required this.cardCount,
    required this.cards,
  });

  factory ProjectColumnWithCards.fromJson(Map<String, dynamic> json) {
    return ProjectColumnWithCards(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      position: json['position'] ?? 0,
      color: json['color'] ?? '#808080',
      cardCount: json['card_count'] ?? 0,
      cards: (json['cards'] as List?)
              ?.map((c) => ProjectCard.fromJson(c))
              .toList() ??
          [],
    );
  }
}

class ProjectCard {
  final String id;
  final String title;
  final String description;
  final int position;
  final int sessionCount;

  ProjectCard({
    required this.id,
    required this.title,
    required this.description,
    required this.position,
    required this.sessionCount,
  });

  factory ProjectCard.fromJson(Map<String, dynamic> json) {
    return ProjectCard(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      description: json['description'] ?? '',
      position: json['position'] ?? 0,
      sessionCount: json['session_count'] ?? 0,
    );
  }
}
