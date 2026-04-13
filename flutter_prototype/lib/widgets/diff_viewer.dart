import 'package:flutter/material.dart';
import '../models/content_block.dart';

class DiffViewer extends StatefulWidget {
  final DiffContent diff;

  const DiffViewer({super.key, required this.diff});

  @override
  State<DiffViewer> createState() => _DiffViewerState();
}

class _DiffViewerState extends State<DiffViewer> {
  bool _isExpanded = false;

  List<DiffLine> _computeDiffs() {
    if (widget.diff.oldText == null) {
      return widget.diff.newText
          .split('\n')
          .map((line) => DiffLine(type: DiffLineType.added, text: line))
          .toList();
    }

    final oldText = widget.diff.oldText!;
    final newText = widget.diff.newText;
    final result = <DiffLine>[];

    final oldLines = oldText.split('\n');
    final newLines = newText.split('\n');

    int i = 0, j = 0;
    while (i < oldLines.length || j < newLines.length) {
      if (i >= oldLines.length) {
        result.add(DiffLine(type: DiffLineType.added, text: newLines[j++]));
      } else if (j >= newLines.length) {
        result.add(DiffLine(type: DiffLineType.removed, text: oldLines[i++]));
      } else if (oldLines[i] == newLines[j]) {
        result.add(DiffLine(type: DiffLineType.unchanged, text: oldLines[i]));
        i++;
        j++;
      } else {
        bool foundInNew = false;
        bool foundInOld = false;
        for (int k = j + 1; k < newLines.length; k++) {
          if (oldLines[i] == newLines[k]) {
            foundInNew = true;
            break;
          }
        }
        for (int k = i + 1; k < oldLines.length; k++) {
          if (oldLines[k] == newLines[j]) {
            foundInOld = true;
            break;
          }
        }
        if (foundInNew) {
          result.add(DiffLine(type: DiffLineType.removed, text: oldLines[i++]));
        } else if (foundInOld) {
          result.add(DiffLine(type: DiffLineType.added, text: newLines[j++]));
        } else {
          result.add(DiffLine(type: DiffLineType.removed, text: oldLines[i++]));
          result.add(DiffLine(type: DiffLineType.added, text: newLines[j++]));
        }
      }
    }

    return result;
  }

  @override
  Widget build(BuildContext context) {
    final diffs = _computeDiffs();
    final addedCount = diffs.where((d) => d.type == DiffLineType.added).length;
    final removedCount =
        diffs.where((d) => d.type == DiffLineType.removed).length;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const Icon(Icons.code, size: 20),
            title: Text(
              widget.diff.path.split('/').last,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            subtitle: Text(
              widget.diff.path,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.green.shade100,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('+$addedCount',
                      style: TextStyle(
                          color: Colors.green.shade800, fontSize: 11)),
                ),
                const SizedBox(width: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.red.shade100,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text('-$removedCount',
                      style:
                          TextStyle(color: Colors.red.shade800, fontSize: 11)),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(
                      _isExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 20),
                  onPressed: () => setState(() => _isExpanded = !_isExpanded),
                ),
              ],
            ),
          ),
          if (_isExpanded)
            Container(
              constraints: const BoxConstraints(maxHeight: 300),
              child: SingleChildScrollView(
                child: Column(
                  children:
                      diffs.map((diff) => _DiffLineWidget(line: diff)).toList(),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

enum DiffLineType { added, removed, unchanged }

class DiffLine {
  final DiffLineType type;
  final String text;

  const DiffLine({required this.type, required this.text});
}

class _DiffLineWidget extends StatelessWidget {
  final DiffLine line;

  const _DiffLineWidget({required this.line});

  Color get backgroundColor {
    switch (line.type) {
      case DiffLineType.added:
        return Colors.green.shade50;
      case DiffLineType.removed:
        return Colors.red.shade50;
      case DiffLineType.unchanged:
        return Colors.transparent;
    }
  }

  Color get textColor {
    switch (line.type) {
      case DiffLineType.added:
        return Colors.green.shade800;
      case DiffLineType.removed:
        return Colors.red.shade800;
      case DiffLineType.unchanged:
        return Colors.grey.shade700;
    }
  }

  String get prefix {
    switch (line.type) {
      case DiffLineType.added:
        return '+';
      case DiffLineType.removed:
        return '-';
      case DiffLineType.unchanged:
        return ' ';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: backgroundColor,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(prefix,
              style: TextStyle(
                  color: textColor, fontFamily: 'monospace', fontSize: 12)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              line.text,
              style: TextStyle(
                  color: textColor, fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
