import 'dart:convert';
import 'dart:io';
import '../models/project.dart';
import '../models/kanban_column.dart';
import '../models/kanban_card.dart';
import '../models/timeline_event.dart';

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
      final body = <String, dynamic>{'name': name};
      if (workspacePath != null && workspacePath.trim().isNotEmpty) {
        body['workspace_path'] = workspacePath.trim();
      }
      final response = await _post('/api/projects', body);
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

  Future<Map<String, dynamic>?> getProjectStatus(String projectId) async {
    try {
      final response = await _get('/api/projects/$projectId/status');
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      return null;
    } catch (e) {
      debugPrint('getProjectStatus error: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> getAllProjectStatuses() async {
    try {
      final response = await _get('/api/projects/status');
      if (response.statusCode == 200) {
        return List<Map<String, dynamic>>.from(jsonDecode(response.body));
      }
      return [];
    } catch (e) {
      debugPrint('getAllProjectStatuses error: $e');
      return [];
    }
  }

  Future<ProjectSwitchData?> switchToProject(String projectId) async {
    try {
      final response = await _post('/api/projects/$projectId/switch', {});
      if (response.statusCode == 200) {
        return ProjectSwitchData.fromJsonWithColumnId(
            jsonDecode(response.body));
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

  Future<bool> updateColumn(String columnId,
      {String? name, String? color}) async {
    try {
      final body = <String, dynamic>{};
      if (name != null) body['name'] = name;
      if (color != null) body['color'] = color;
      final response = await _put('/api/columns/$columnId', body);
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('updateColumn error: $e');
      return false;
    }
  }

  Future<bool> deleteColumn(String columnId, {String? moveToColumnId}) async {
    try {
      final path = moveToColumnId != null
          ? '/api/columns/$columnId?move_to_column_id=$moveToColumnId'
          : '/api/columns/$columnId';
      final response = await _delete(path);
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('deleteColumn error: $e');
      return false;
    }
  }

  Future<List<KanbanCard>> getCardsByColumn(String columnId) async {
    try {
      final response = await _get('/api/columns/$columnId/cards');
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body)['cards'] ?? [];
        return data.map((c) {
          final cardMap = Map<String, dynamic>.from(c);
          cardMap['column_id'] = columnId;
          return KanbanCard.fromJson(cardMap);
        }).toList();
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

  Future<bool> updateCardSessionId(String cardId, String sessionId) async {
    try {
      final response = await _put('/api/cards/$cardId/acp-session', {
        'session_id': sessionId,
      });
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('updateCardSessionId error: $e');
      return false;
    }
  }

  Future<KanbanCard?> updateCard(String cardId,
      {String? title, String? description}) async {
    try {
      final body = <String, dynamic>{};
      if (title != null) body['title'] = title;
      if (description != null) body['description'] = description;

      // Debug logging
      debugPrint('[ProjectService] updateCard request:');
      debugPrint('  - cardId: $cardId');
      debugPrint('  - body: $body');
      debugPrint('  - title: "$title"');
      debugPrint('  - description: "$description"');

      final response = await _put('/api/cards/$cardId', body);

      debugPrint('[ProjectService] updateCard response:');
      debugPrint('  - statusCode: ${response.statusCode}');
      debugPrint('  - body: ${response.body}');

      if (response.statusCode == 200) {
        return KanbanCard.fromJson(jsonDecode(response.body));
      }
      return null;
    } catch (e) {
      debugPrint('updateCard error: $e');
      return null;
    }
  }

  Future<bool> moveCard(
      String cardId, String targetColumnId, int position) async {
    try {
      final response = await _patch('/api/cards/$cardId/move', {
        'target_column_id': targetColumnId,
        'target_position': position,
      });
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('moveCard error: $e');
      return false;
    }
  }

  Future<bool> reorderColumns(
      String projectId, List<KanbanColumn> allColumns) async {
    try {
      final List<Map<String, dynamic>> positions = [];
      for (int i = 0; i < allColumns.length; i++) {
        positions.add({
          'id': allColumns[i].id,
          'position': i,
        });
      }

      final response =
          await _patch('/api/projects/$projectId/columns/reorder', {
        'positions': positions,
      });
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('reorderColumns error: $e');
      return false;
    }
  }

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
      debugPrint('[HTTP PUT] $uri');
      debugPrint('[HTTP PUT body] ${jsonEncode(body)}');
      final request = await client.putUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close();
      final respBody = await response.transform(utf8.decoder).join();
      debugPrint('[HTTP PUT response] ${response.statusCode}: $respBody');
      return _HttpResponse(response.statusCode, respBody);
    } finally {
      client.close();
    }
  }

  Future<dynamic> _patch(String path, Map<String, dynamic> body) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse('$_baseUrl$path');
      debugPrint('[HTTP PATCH] $uri');
      debugPrint('[HTTP PATCH body] ${jsonEncode(body)}');
      final request = await client.patchUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close();
      final respBody = await response.transform(utf8.decoder).join();
      debugPrint('[HTTP PATCH response] ${response.statusCode}: $respBody');
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

class _HttpResponse {
  final int statusCode;
  final String body;

  _HttpResponse(this.statusCode, this.body);
}

class ProjectSwitchData {
  final Project project;
  final List<KanbanColumnWithCards> columns;
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
          .map((c) => KanbanColumnWithCards.fromJson(c))
          .toList(),
      timeline: (json['timeline'] as List)
          .map((t) => TimelineEvent.fromJson(t))
          .toList(),
      message: json['message'] ?? '',
    );
  }

  factory ProjectSwitchData.fromJsonWithColumnId(Map<String, dynamic> json) {
    return ProjectSwitchData(
      project: Project.fromJson(json['project']),
      columns: (json['columns'] as List)
          .map((c) => KanbanColumnWithCards.fromJsonWithColumnId(c))
          .toList(),
      timeline: (json['timeline'] as List)
          .map((t) => TimelineEvent.fromJson(t))
          .toList(),
      message: json['message'] ?? '',
    );
  }
}

class KanbanColumnWithCards {
  final KanbanColumn column;
  final List<KanbanCard> cards;

  KanbanColumnWithCards({
    required this.column,
    required this.cards,
  });

  factory KanbanColumnWithCards.fromJson(Map<String, dynamic> json) {
    return KanbanColumnWithCards(
      column: KanbanColumn.fromJson(json),
      cards: (json['cards'] as List?)
              ?.map((c) => KanbanCard.fromJson(c))
              .toList() ??
          [],
    );
  }

  factory KanbanColumnWithCards.fromJsonWithColumnId(
      Map<String, dynamic> json) {
    final column = KanbanColumn.fromJson(json);
    final cards = (json['cards'] as List?)?.map((c) {
          final cardMap = Map<String, dynamic>.from(c);
          cardMap['column_id'] = column.id;
          return KanbanCard.fromJson(cardMap);
        }).toList() ??
        [];
    return KanbanColumnWithCards(
      column: column,
      cards: cards,
    );
  }
}
