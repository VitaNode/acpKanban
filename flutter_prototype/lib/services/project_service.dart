import 'dart:convert';
import 'dart:io';
import '../models/project.dart';
import '../models/kanban_column.dart';
import '../models/kanban_card.dart';
import '../models/timeline_event.dart';
import '../constants/error_copy.dart';
import '../utils/app_logger.dart';
import 'acp_client.dart';
import 'smart_connect.dart';

class ProjectService {
  static final ProjectService _instance = ProjectService._internal();
  factory ProjectService() => _instance;
  ProjectService._internal();

  String _baseUrl = 'http://localhost:8000';
  final ACPClient _acpClient = ACPClient();

  bool get _useProxy => _acpClient.activeMode != ConnectionPath.none;

  void updateBaseUrl(String newUrl) {
    if (newUrl.contains('/relay/')) {
      return;
    }

    if (newUrl.startsWith('ws')) {
      _baseUrl = newUrl.replaceFirst('ws', 'http');
    } else {
      _baseUrl = newUrl;
    }
    if (_baseUrl.contains(':8766')) {
      _baseUrl = _baseUrl.replaceFirst(':8766', ':8000');
    }
    AppLogger.info('Base URL updated to: $_baseUrl');
  }

  Future<List<Project>> getProjects() async {
    if (_useProxy) {
      try {
        await _acpClient.waitForReady;
        final response = await _acpClient.sendRequest('projects/list', {});
        if (response.containsKey('result')) {
          final dynamic resultData = response['result'];
          if (resultData is List) {
            return resultData.map((p) => Project.fromJson(p)).toList();
          }
        } else if (response.containsKey('error')) {
          final err = response['error'];
          AppLogger.error('ACP projects/list error: ${ErrorCopy.mapError(err['error_code'], err['message'])}');
        }
      } catch (e) {
        AppLogger.error('ACP projects/list failed', e);
      }
      return [];
    }

    try {
      final response = await _get('/api/projects');
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((p) => Project.fromJson(p)).toList();
      }
      AppLogger.error('Failed to load projects: ${response.statusCode}');
    } catch (e) {
      AppLogger.error('getProjects error', e);
    }
    return [];
  }

  Future<Project?> getProject(String projectId) async {
    if (_useProxy && _acpClient.isReady) {
      try {
        final response = await _acpClient.sendRequest('projects/get', {'project_id': projectId});
        if (response.containsKey('result')) {
          return Project.fromJson(response['result']);
        }
      } catch (e) {
        AppLogger.error('ACP projects/get failed', e);
      }
    }

    try {
      final response = await _get('/api/projects/$projectId');
      if (response.statusCode == 200) {
        return Project.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      AppLogger.error('getProject error', e);
    }
    return null;
  }

  Future<Project?> createProject(String name, {String? workspacePath, String? description}) async {
    try {
      final body = <String, dynamic>{'name': name};
      if (workspacePath != null && workspacePath.trim().isNotEmpty) {
        body['workspace_path'] = workspacePath.trim();
      }
      if (description != null && description.trim().isNotEmpty) {
        body['description'] = description.trim();
      }
      final response = await _post('/api/projects', body);
      if (response.statusCode == 201) {
        return Project.fromJson(jsonDecode(response.body));
      }
      AppLogger.error('Failed to create project: ${response.statusCode} - ${response.body}');
    } catch (e) {
      AppLogger.error('createProject error', e);
    }
    return null;
  }

  Future<Project?> updateProject(String projectId,
      {String? name, String? workspacePath, String? description}) async {
    try {
      final body = <String, dynamic>{};
      if (name != null) body['name'] = name;
      if (workspacePath != null) body['workspace_path'] = workspacePath;
      if (description != null) body['description'] = description;

      final response = await _put('/api/projects/$projectId', body);
      if (response.statusCode == 200) {
        return Project.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      AppLogger.error('updateProject error', e);
    }
    return null;
  }

  Future<bool> deleteProject(String projectId) async {
    try {
      final response = await _delete('/api/projects/$projectId');
      return response.statusCode == 200;
    } catch (e) {
      AppLogger.error('deleteProject error', e);
      return false;
    }
  }

  Future<List<KanbanColumn>> getColumns(String projectId) async {
    if (_useProxy) {
      try {
        final response = await _get('/api/projects/$projectId/columns');
        if (response.statusCode == 200) {
          final List<dynamic> data = jsonDecode(response.body);
          return data.map((c) => KanbanColumn.fromJson(c)).toList();
        }
      } catch (e) {
        AppLogger.warning('Proxy getColumns failed, trying RPC fallback', e);
        try {
          await _acpClient.waitForReady;
          final response = await _acpClient.sendRequest('projects/get', {'project_id': projectId});
          if (response.containsKey('result') && response['result'] != null && response['result']['columns'] != null) {
            final List<dynamic> cols = response['result']['columns'];
            return cols.map((c) => KanbanColumn.fromJson(c)).toList();
          }
        } catch (re) {
          AppLogger.error('RPC getColumns fallback failed', re);
        }
      }
      return [];
    }

    try {
      final response = await _get('/api/projects/$projectId/columns');
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        return data.map((c) => KanbanColumn.fromJson(c)).toList();
      }
    } catch (e) {
      AppLogger.error('getColumns error', e);
    }
    return [];
  }

  Future<Map<String, dynamic>?> getSystemConfig() async {
    try {
      final response = await _get('/api/system/config');
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      AppLogger.error('getSystemConfig error', e);
    }
    return null;
  }

  Future<Map<String, dynamic>?> getProjectStatus(String projectId) async {
    try {
      final response = await _get('/api/projects/$projectId/status');
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      AppLogger.error('getProjectStatus error', e);
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> getAllProjectStatuses() async {
    try {
      final response = await _get('/api/projects/status');
      if (response.statusCode == 200) {
        return List<Map<String, dynamic>>.from(jsonDecode(response.body));
      }
    } catch (e) {
      AppLogger.error('getAllProjectStatuses error', e);
    }
    return [];
  }

  Future<ProjectSwitchData?> switchToProject(String projectId) async {
    if (_useProxy) {
      try {
        final response = await _post('/api/projects/$projectId/switch', {});
        if (response.statusCode == 200) {
          return ProjectSwitchData.fromJsonWithColumnId(jsonDecode(response.body));
        }
      } catch (e) {
        AppLogger.warning('Proxy switchToProject failed, trying RPC fallback', e);
        try {
          final response = await _acpClient.sendRequest('projects/switch', {'project_id': projectId});
          if (response.containsKey('result')) {
            final p = await getProject(projectId);
            if (p != null) {
              return ProjectSwitchData(
                project: p,
                columns: [], 
                timeline: [],
                message: "Switched via Relay RPC",
              );
            }
          }
        } catch (re) {
          AppLogger.error('RPC switchToProject fallback failed', re);
        }
      }
      return null;
    }

    try {
      final response = await _post('/api/projects/$projectId/switch', {});
      if (response.statusCode == 200) {
        return ProjectSwitchData.fromJsonWithColumnId(jsonDecode(response.body));
      }
    } catch (e) {
      AppLogger.error('switchToProject error', e);
    }
    return null;
  }

  Future<KanbanColumn?> createColumn(String projectId, String name,
      {String? color, String? promptTemplate, String? acpProviderId}) async {
    try {
      final response = await _post('/api/projects/$projectId/columns', {
        'name': name,
        if (color != null) 'color': color,
        if (promptTemplate != null && promptTemplate.isNotEmpty)
          'prompt_template': promptTemplate,
        if (acpProviderId != null) 'acp_provider_id': acpProviderId,
      });
      if (response.statusCode == 201) {
        return KanbanColumn.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      AppLogger.error('createColumn error', e);
    }
    return null;
  }

  Future<bool> updateColumn(String columnId,
      {String? name, String? color, String? promptTemplate, String? acpProviderId}) async {
    try {
      final body = <String, dynamic>{};
      if (name != null) body['name'] = name;
      if (color != null) body['color'] = color;
      if (promptTemplate != null) body['prompt_template'] = promptTemplate;
      if (acpProviderId != null) body['acp_provider_id'] = acpProviderId;
      final response = await _put('/api/columns/$columnId', body);
      return response.statusCode == 200;
    } catch (e) {
      AppLogger.error('updateColumn error', e);
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
      AppLogger.error('deleteColumn error', e);
      return false;
    }
  }

  Future<List<KanbanCard>> getCardsByColumn(String columnId,
      {bool includeCompleted = false}) async {
    if (_useProxy) {
      try {
        final response = await _get('/api/columns/$columnId/cards?include_completed=$includeCompleted');
        if (response.statusCode == 200) {
          final List<dynamic> data = jsonDecode(response.body)['cards'] ?? [];
          return data.map((c) {
            final cardMap = Map<String, dynamic>.from(c);
            cardMap['column_id'] = columnId;
            return KanbanCard.fromJson(cardMap);
          }).toList();
        }
      } catch (e) {
        AppLogger.warning('Proxy getCardsByColumn failed, trying RPC fallback', e);
        try {
          await _acpClient.waitForReady;
          final response = await _acpClient.sendRequest('cards/list', {'column_id': columnId});
          if (response.containsKey('result') && response['result'] is List) {
            final List<dynamic> resultData = response['result'];
            return resultData.map((c) {
              final cardMap = Map<String, dynamic>.from(c);
              cardMap['column_id'] = columnId;
              return KanbanCard.fromJson(cardMap);
            }).toList();
          }
        } catch (re) {
          AppLogger.error('RPC getCardsByColumn fallback failed', re);
        }
      }
      return [];
    }

    try {
      final response = await _get(
          '/api/columns/$columnId/cards?include_completed=$includeCompleted');
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body)['cards'] ?? [];
        return data.map((c) {
          final cardMap = Map<String, dynamic>.from(c);
          cardMap['column_id'] = columnId;
          return KanbanCard.fromJson(cardMap);
        }).toList();
      }
    } catch (e) {
      AppLogger.error('getCardsByColumn error', e);
    }
    return [];
  }

  Future<KanbanCard?> createCard(String columnId, String title,
      {String? description, String? acpProviderId}) async {
    if (_useProxy) {
      try {
        final response = await _post('/api/cards', {
          'column_id': columnId,
          'title': title,
          if (description != null) 'description': description,
          if (acpProviderId != null) 'acp_provider_id': acpProviderId,
        });
        if (response.statusCode == 201) {
          return KanbanCard.fromJson(jsonDecode(response.body));
        }
      } catch (e) {
        AppLogger.warning('Proxy createCard failed, trying RPC fallback', e);
        try {
          final response = await _acpClient.sendRequest('cards/create', {
            'column_id': columnId,
            'title': title,
            'description': description ?? "",
            'acp_provider_id': acpProviderId
          });
          if (response.containsKey('result')) {
            final cardMap = Map<String, dynamic>.from(response['result']);
            cardMap['column_id'] = columnId;
            return KanbanCard.fromJson(cardMap);
          }
        } catch (re) {
          AppLogger.error('RPC createCard fallback failed', re);
        }
      }
      return null;
    }

    try {
      final response = await _post('/api/cards', {
        'column_id': columnId,
        'title': title,
        if (description != null) 'description': description,
        if (acpProviderId != null) 'acp_provider_id': acpProviderId,
      });
      if (response.statusCode == 201) {
        return KanbanCard.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      AppLogger.error('createCard error', e);
    }
    return null;
  }

  Future<KanbanCard?> completeCard(String cardId) async {
    try {
      final response = await _patch('/api/cards/$cardId/complete', {});
      if (response.statusCode == 200) {
        return KanbanCard.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      AppLogger.error('completeCard error', e);
    }
    return null;
  }

  Future<KanbanCard?> uncompleteCard(String cardId) async {
    try {
      final response = await _patch('/api/cards/$cardId/uncomplete', {});
      if (response.statusCode == 200) {
        return KanbanCard.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      AppLogger.error('uncompleteCard error', e);
    }
    return null;
  }

  Future<bool> deleteCard(String cardId) async {
    try {
      final response = await _delete('/api/cards/$cardId');
      return response.statusCode == 200;
    } catch (e) {
      AppLogger.error('deleteCard error', e);
      return false;
    }
  }

  Future<List<KanbanCard>> getRelatedCards(String cardId, {int limit = 5}) async {
    try {
      final response = await _get('/api/cards/$cardId/related?limit=$limit');
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body)['cards'] ?? [];
        return data.map((c) => KanbanCard.fromJson(c)).toList();
      }
    } catch (e) {
      AppLogger.error('getRelatedCards error', e);
    }
    return [];
  }

  Future<Map<String, dynamic>?> getCardSummary(String cardId) async {
    try {
      final response = await _get('/api/cards/$cardId/summary');
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      AppLogger.error('getCardSummary error', e);
    }
    return null;
  }

  Future<bool> updateCardSummary(String cardId, String summary) async {
    try {
      final response = await _put('/api/cards/$cardId/summary', {'summary': summary});
      return response.statusCode == 200;
    } catch (e) {
      AppLogger.error('updateCardSummary error', e);
      return false;
    }
  }

  Future<Map<String, dynamic>?> generateCardSummary(String cardId) async {
    try {
      final response = await _post('/api/cards/$cardId/summary/generate', {});
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
      throw Exception(ErrorCopy.mapError(null, 'Failed to generate summary: ${response.statusCode}'));
    } catch (e) {
      AppLogger.error('generateCardSummary error', e);
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> getProviders() async {
    try {
      final response = await _get('/api/providers');
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      AppLogger.error('getProviders error', e);
    }
    return null;
  }

  Future<Map<String, dynamic>?> getProviderInitStatus(String projectId) async {
    try {
      final response = await _get('/api/providers/init-status?project_id=$projectId');
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      AppLogger.error('getProviderInitStatus error', e);
    }
    return null;
  }

  Future<Map<String, dynamic>?> initializeProvider(String providerId) async {
    try {
      final response = await _post('/api/providers/$providerId/initialize', {});
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      AppLogger.error('initializeProvider error', e);
    }
    return null;
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
    } catch (e) {
      AppLogger.error('getTimeline error', e);
    }
    return [];
  }

  Future<Map<String, dynamic>?> getSessionHistory(String cardId) async {
    try {
      final response = await _get('/api/cards/$cardId/session');
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      AppLogger.error('getSessionHistory error', e);
    }
    return null;
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
      AppLogger.error('addSessionMessage error', e);
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
      AppLogger.error('updateCardSessionId error', e);
      return false;
    }
  }

  Future<KanbanCard?> getCard(String cardId) async {
    try {
      final response = await _get('/api/cards/$cardId');
      if (response.statusCode == 200) {
        return KanbanCard.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      AppLogger.error('getCard error', e);
    }
    return null;
  }

  Future<KanbanCard?> updateCard(String cardId,
      {String? title, String? description, String? featureId}) async {
    try {
      final body = <String, dynamic>{};
      if (title != null) body['title'] = title;
      if (description != null) body['description'] = description;
      if (featureId != null) body['feature_id'] = featureId;

      AppLogger.debug('[ProjectService] updateCard request: cardId=$cardId, body=$body');
      final response = await _put('/api/cards/$cardId', body);
      AppLogger.debug('[ProjectService] updateCard response: ${response.statusCode}');

      if (response.statusCode == 200) {
        return KanbanCard.fromJson(jsonDecode(response.body));
      }
    } catch (e) {
      AppLogger.error('updateCard error', e);
    }
    return null;
  }

  Future<bool> moveCard(
      String cardId, String targetColumnId, int? position) async {
    if (_useProxy) {
      try {
        final response = await _patch('/api/cards/$cardId/move', {
          'target_column_id': targetColumnId,
          'target_position': position,
        });
        return response.statusCode == 200;
      } catch (e) {
        AppLogger.warning('Proxy moveCard failed, trying RPC fallback', e);
        try {
          final response = await _acpClient.sendRequest('cards/move', {
            'card_id': cardId,
            'column_id': targetColumnId,
            'position': position
          });
          return response.containsKey('result');
        } catch (re) {
          AppLogger.error('RPC moveCard fallback failed', re);
        }
      }
    }

    try {
      final response = await _patch('/api/cards/$cardId/move', {
        'target_column_id': targetColumnId,
        'target_position': position,
      });
      return response.statusCode == 200;
    } catch (e) {
      AppLogger.error('moveCard error', e);
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
      AppLogger.error('reorderColumns error', e);
      return false;
    }
  }

  Future<bool> startIndexing(String projectId, {bool forceFull = false}) async {
    try {
      final response = await _post('/api/projects/$projectId/index/start', {
        'force_full': forceFull,
      });
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['success'] ?? false;
      }
    } catch (e) {
      AppLogger.error('startIndexing error', e);
    }
    return false;
  }

  Future<Map<String, dynamic>?> getIndexingStatus(String projectId) async {
    try {
      final response = await _get('/api/projects/$projectId/index/status');
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      }
    } catch (e) {
      AppLogger.error('getIndexingStatus error', e);
    }
    return null;
  }

  Future<bool> cancelIndexing(String projectId) async {
    try {
      final response = await _post('/api/projects/$projectId/index/cancel', {});
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['success'] ?? false;
      }
    } catch (e) {
      AppLogger.error('cancelIndexing error', e);
    }
    return false;
  }

  Future<dynamic> _get(String path) async {
    if (_useProxy) return _proxyRequest('GET', path);
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
    if (_useProxy) return _proxyRequest('POST', path, body: body);
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
    if (_useProxy) return _proxyRequest('PUT', path, body: body);
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

  Future<dynamic> _patch(String path, Map<String, dynamic> body) async {
    if (_useProxy) return _proxyRequest('PATCH', path, body: body);
    final client = HttpClient();
    try {
      final uri = Uri.parse('$_baseUrl$path');
      final request = await client.patchUrl(uri);
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
    if (_useProxy) return _proxyRequest('DELETE', path);
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

  Future<_HttpResponse> _proxyRequest(String method, String path, {Map<String, dynamic>? body}) async {
    try {
      await _acpClient.waitForReady;
      final response = await _acpClient.sendRequest('http/proxy', {
        'method': method,
        'path': path,
        'body': body,
      });
      
      if (response.containsKey('result')) {
        final result = response['result'];
        return _HttpResponse(
          result['statusCode'] ?? 500,
          result['body'] ?? '',
        );
      } else if (response.containsKey('error')) {
        return _HttpResponse(500, jsonEncode(response['error']));
      }
      return _HttpResponse(500, 'Unknown proxy error');
    } catch (e) {
      AppLogger.error('Proxy request failed', e);
      return _HttpResponse(500, 'Proxy exception: $e');
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
