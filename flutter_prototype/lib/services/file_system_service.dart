import 'dart:io';

class FileSystemService {
  static final FileSystemService _instance = FileSystemService._internal();
  factory FileSystemService() => _instance;
  FileSystemService._internal();

  Future<Map<String, dynamic>> handleReadTextFile(
      Map<String, dynamic> params) async {
    final path = params['path'] as String;
    final line = params['line'] as int?;
    final limit = params['limit'] as int?;

    try {
      final file = File(path);
      if (!await file.exists()) {
        return {
          'error': {'code': -32001, 'message': 'File not found: $path'}
        };
      }

      String content = await file.readAsString();

      if (line != null || limit != null) {
        final lines = content.split('\n');
        final lineCount = lines.length;
        final startLine = line != null ? (line - 1).clamp(0, lineCount) : 0;
        final endLine =
            limit != null ? (startLine + limit).clamp(0, lineCount) : lineCount;
        content = lines.sublist(startLine, endLine).join('\n');
      }

      return {'content': content};
    } catch (e) {
      return {
        'error': {'code': -32002, 'message': 'Read failed: $e'}
      };
    }
  }

  Future<Map<String, dynamic>> handleWriteTextFile(
      Map<String, dynamic> params) async {
    final path = params['path'] as String;
    final content = params['content'] as String;

    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
      return {'result': null};
    } catch (e) {
      return {
        'error': {'code': -32003, 'message': 'Write failed: $e'}
      };
    }
  }
}
