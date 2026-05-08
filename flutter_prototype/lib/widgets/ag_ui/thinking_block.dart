import 'package:flutter/material.dart';

class ThinkingBlock extends StatefulWidget {
  final String text;
  final bool isCollapsed;

  const ThinkingBlock({
    Key? key,
    required this.text,
    this.isCollapsed = false,
  }) : super(key: key);

  @override
  State<ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<ThinkingBlock>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _heightAnim;
  bool _isCollapsed = true;

  @override
  void initState() {
    super.initState();
    _isCollapsed = widget.isCollapsed;
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _heightAnim = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );

    if (!_isCollapsed) {
      _controller.value = 1.0;
    }
  }

  @override
  void didUpdateWidget(covariant ThinkingBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isCollapsed != widget.isCollapsed) {
      setState(() {
        _isCollapsed = widget.isCollapsed;
        if (_isCollapsed) {
          _controller.reverse();
        } else {
          _controller.forward();
        }
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggleCollapse() {
    setState(() {
      _isCollapsed = !_isCollapsed;
      if (_isCollapsed) {
        _controller.reverse();
      } else {
        _controller.forward();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _toggleCollapse,
      child: AnimatedBuilder(
        animation: _heightAnim,
        builder: (context, child) {
          return SizedBox(
            height: _heightAnim.value * 100, // 适当的最大高度
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceVariant,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.lightbulb_outline, size: 18),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          '思考过程',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Icon(
                        _isCollapsed
                            ? Icons.expand_more
                            : Icons.expand_less,
                        size: 20,
                      ),
                    ],
                  ),
                ),
                // Content
                if (!_isCollapsed)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      widget.text,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}