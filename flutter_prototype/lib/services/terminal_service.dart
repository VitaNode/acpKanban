import 'dart:async';
import 'dart:io';

class TerminalSession {
  final String id;
  final Process process;
  final StreamController<String> outputController;
  final List<String> _outputBuffer = [];
  int? exitCode;

  TerminalSession({
    required this.id,
    required this.process,
  }) : outputController = StreamController<String>.broadcast();

  void addOutput(String text) {
    _outputBuffer.add(text);
  }

  String getOutput() {
    return _outputBuffer.join('');
  }

  void clearOutput() {
    _outputBuffer.clear();
  }

  void dispose() {
    outputController.close();
    process.kill();
  }
}

class TerminalService {
  static final TerminalService _instance = TerminalService._internal();
  factory TerminalService() => _instance;
  TerminalService._internal();

  final Map<String, TerminalSession> _sessions = {};

  Future<Map<String, dynamic>> createTerminal(
      Map<String, dynamic> params) async {
    final sessionId = 'term_${DateTime.now().millisecondsSinceEpoch}';
    final command = params['command'] as String;
    final args = (params['args'] as List?)?.cast<String>() ?? [];
    final cwd = params['cwd'] as String?;

    try {
      final process = await Process.start(
        command,
        args,
        workingDirectory: cwd,
        runInShell: true,
      );

      final session = TerminalSession(
        id: sessionId,
        process: process,
      );
      _sessions[sessionId] = session;

      process.stdout.listen((data) {
        final text = String.fromCharCodes(data);
        session.outputController.add(text);
        session.addOutput(text);
      });

      process.stderr.listen((data) {
        final text = String.fromCharCodes(data);
        session.outputController.add(text);
        session.addOutput(text);
      });

      final exitCode = await process.exitCode;
      session.exitCode = exitCode;

      return {
        'terminalId': sessionId,
        'exitCode': exitCode,
      };
    } catch (e) {
      return {
        'error': {'code': -32004, 'message': 'Terminal failed: $e'}
      };
    }
  }

  Future<Map<String, dynamic>> getTerminalOutput(
      Map<String, dynamic> params) async {
    final terminalId = params['terminalId'] as String;
    final session = _sessions[terminalId];

    if (session == null) {
      return {
        'error': {'code': -32005, 'message': 'Terminal not found'}
      };
    }

    return {'output': session.getOutput()};
  }

  Future<Map<String, dynamic>> waitForExit(Map<String, dynamic> params) async {
    final terminalId = params['terminalId'] as String;
    final session = _sessions[terminalId];

    if (session == null) {
      return {
        'error': {'code': -32005, 'message': 'Terminal not found'}
      };
    }

    return {'exitCode': session.exitCode};
  }

  Future<Map<String, dynamic>> killTerminal(Map<String, dynamic> params) async {
    final terminalId = params['terminalId'] as String;
    _sessions.remove(terminalId)?.dispose();
    return {'result': null};
  }

  Future<Map<String, dynamic>> releaseTerminal(
      Map<String, dynamic> params) async {
    return await killTerminal(params);
  }
}
