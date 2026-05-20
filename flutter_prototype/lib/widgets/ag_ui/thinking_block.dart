import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import '../message_shell.dart';
import '../../theme/markdown_theme.dart';
import '../../constants/app_constants.dart';

class ThinkingBlock extends StatefulWidget {
  final String text;
  final bool isCollapsed;

  const ThinkingBlock({
    super.key,
    required this.text,
    this.isCollapsed = true,
  });

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock> {
  bool _isExpanded = false;

  @override
  void initState() {
    super.initState();
    _isExpanded = !widget.isCollapsed;
  }

  @override
  void didUpdateWidget(covariant ThinkingBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isCollapsed != widget.isCollapsed) {
      setState(() {
        _isExpanded = !widget.isCollapsed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MessageShell(
      isExpandable: true,
      isExpanded: _isExpanded,
      onToggleExpand: () => setState(() => _isExpanded = !_isExpanded),
      headerLeading: const Icon(
        Icons.psychology_outlined,
        size: 16,
      ),
      title: 'Thinking Process',
      padding: const EdgeInsets.fromLTRB(AppConstants.space12, 0, AppConstants.space12, AppConstants.space12),
      child: MarkdownBody(
        data: widget.text,
        selectable: false, // Managed by high-level SelectionArea
        styleSheet: MarkdownTheme.getStyle(context),
        builders: MarkdownTheme.getBuilders(context),
      ),
    );
  }
}
