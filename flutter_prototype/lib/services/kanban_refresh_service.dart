import 'dart:async';
import 'package:flutter/foundation.dart';

/// 看板刷新服务 - 单例模式
/// 
/// 用于在以下场景自动刷新看板数据：
/// - 卡片移动
/// - 卡片创建
/// - 卡片删除
/// - 列重排序
/// - 列创建/编辑/删除
/// - 切换项目
/// - 从 CardSessionScreen 返回
/// - 热重启
class KanbanRefreshService {
  static final KanbanRefreshService _instance = KanbanRefreshService._internal();
  
  factory KanbanRefreshService() {
    return _instance;
  }
  
  KanbanRefreshService._internal();

  /// 刷新回调函数列表
  final List<VoidCallback> _refreshListeners = [];
  
  /// 防抖定时器
  Timer? _debounceTimer;
  
  /// 防抖延迟（毫秒）
  static const int _debounceDelayMs = 300;
  
  /// 是否需要刷新标记
  bool _needsRefresh = false;

  /// 添加刷新监听器
  void addRefreshListener(VoidCallback listener) {
    if (!_refreshListeners.contains(listener)) {
      _refreshListeners.add(listener);
    }
  }

  /// 移除刷新监听器
  void removeRefreshListener(VoidCallback listener) {
    _refreshListeners.remove(listener);
  }

  /// 标记需要刷新（带防抖）
  void markNeedsRefresh() {
    _needsRefresh = true;
    
    // 取消之前的定时器
    _debounceTimer?.cancel();
    
    // 启动新的防抖定时器
    _debounceTimer = Timer(
      const Duration(milliseconds: _debounceDelayMs),
      () {
        if (_needsRefresh) {
          _performRefresh();
        }
      },
    );
  }

  /// 立即刷新（不防抖）
  void refreshNow() {
    _debounceTimer?.cancel();
    _performRefresh();
  }

  /// 执行刷新
  void _performRefresh() {
    _needsRefresh = false;
    for (final listener in _refreshListeners) {
      try {
        listener();
      } catch (e) {
        debugPrint('Refresh listener error: $e');
      }
    }
  }

  /// 清理资源
  void dispose() {
    _debounceTimer?.cancel();
    _refreshListeners.clear();
  }
}

/// 刷新触发场景枚举
enum RefreshTrigger {
  cardMoved,
  cardCreated,
  cardDeleted,
  columnReordered,
  columnCreated,
  columnUpdated,
  columnDeleted,
  projectSwitched,
  sessionReturned,
  appResumed,
}

/// 刷新事件数据
class RefreshEvent {
  final RefreshTrigger trigger;
  final Map<String, dynamic>? metadata;

  RefreshEvent({
    required this.trigger,
    this.metadata,
  });
}
