import 'dart:async';
import 'package:flutter/foundation.dart';

/// Kanban Refresh Service - Singleton Pattern
/// Used to automatically refresh board data in the following scenarios:
/// - Card moved
/// - Card created
/// - Card deleted
/// - Column reordered
/// - Column created/edited/deleted
/// - Switch project
/// - Back from CardSessionScreen
/// - Hot restart
class KanbanRefreshService {
  static final KanbanRefreshService _instance = KanbanRefreshService._internal();
  factory KanbanRefreshService() => _instance;
  KanbanRefreshService._internal();

  /// List of refresh callback functions
  final List<Function(RefreshEvent)> _listeners = [];
  
  /// Debounce timer
  Timer? _debounceTimer;
  
  /// Debounce delay in milliseconds
  static const int _debounceMs = 500;
  
  /// Flag indicating if refresh is needed
  bool _needsRefresh = false;

  /// Add a refresh listener
  void addListener(Function(RefreshEvent) listener) {
    if (!_listeners.contains(listener)) {
      _listeners.add(listener);
    }
  }

  /// Remove a refresh listener
  void removeListener(Function(RefreshEvent) listener) {
    _listeners.remove(listener);
  }

  /// Mark refresh as needed with debounce
  void markNeedsRefresh(RefreshSource source, {Map<String, dynamic>? metadata}) {
    _needsRefresh = true;
    
    // Cancel previous timer
    _debounceTimer?.cancel();
    
    // Start new debounce timer
    _debounceTimer = Timer(const Duration(milliseconds: _debounceMs), () {
      if (_needsRefresh) {
        _executeRefresh(source, metadata);
        _needsRefresh = false;
      }
    });
  }

  /// Trigger immediate refresh (no debounce)
  void triggerImmediate(RefreshSource source, {Map<String, dynamic>? metadata}) {
    _debounceTimer?.cancel();
    _executeRefresh(source, metadata);
    _needsRefresh = false;
  }

  /// Execute refresh callbacks
  void _executeRefresh(RefreshSource source, Map<String, dynamic>? metadata) {
    final event = RefreshEvent(source: source, metadata: metadata);
    for (final listener in _listeners) {
      try {
        listener(event);
      } catch (e) {
        if (kDebugMode) print('Refresh listener error: $e');
      }
    }
  }

  /// Cleanup resources
  void dispose() {
    _debounceTimer?.cancel();
    _listeners.clear();
  }
}

/// Refresh trigger source enumeration
enum RefreshSource {
  cardMoved,
  cardCreated,
  cardDeleted,
  columnChanged,
  projectSwitched,
  manual,
  other
}

/// Refresh event data
class RefreshEvent {
  final RefreshSource source;
  final Map<String, dynamic>? metadata;

  RefreshEvent({required this.source, this.metadata});
}
