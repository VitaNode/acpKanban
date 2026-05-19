import 'package:flutter/material.dart';
import '../models/content_block.dart';
import '../constants/app_constants.dart';
import '../theme/app_theme.dart';

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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final customColors = theme.extension<CustomColors>()!;
    final diffs = _computeDiffs();
    final addedCount = diffs.where((d) => d.type == DiffLineType.added).length;
    final removedCount =
        diffs.where((d) => d.type == DiffLineType.removed).length;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: AppConstants.space8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
        border: Border.all(color: theme.dividerTheme.color!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
            child: Padding(
              padding: const EdgeInsets.all(AppConstants.space12),
              child: Row(
                children: [
                  Icon(Icons.code_rounded,
                      size: 18, color: colorScheme.primary),
                  const SizedBox(width: AppConstants.space12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.diff.path.split('/').last,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          widget.diff.path,
                          style: theme.textTheme.bodySmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppConstants.space8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: customColors.success?.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('+$addedCount',
                        style: TextStyle(
                            color: customColors.success,
                            fontSize: 10,
                            fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 4),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: colorScheme.error.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('-$removedCount',
                        style: TextStyle(
                            color: colorScheme.error,
                            fontSize: 10,
                            fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: AppConstants.space8),
                  Icon(
                      _isExpanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 20),
                ],
              ),
            ),
          ),
          if (_isExpanded)
            Container(
              decoration: BoxDecoration(
                color: customColors.codeBackground,
                borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(AppConstants.radiusMedium)),
              ),
              constraints: const BoxConstraints(maxHeight: 400),
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(vertical: AppConstants.space8),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final customColors = theme.extension<CustomColors>()!;

    Color backgroundColor;
    Color textColor;
    String prefix;

    switch (line.type) {
      case DiffLineType.added:
        backgroundColor = customColors.diffAdded!.withOpacity(0.1);
        textColor = customColors.diffAdded!;
        prefix = '+';
        break;
      case DiffLineType.removed:
        backgroundColor = customColors.diffRemoved!.withOpacity(0.1);
        textColor = customColors.diffRemoved!;
        prefix = '-';
        break;
      case DiffLineType.unchanged:
        backgroundColor = Colors.transparent;
        textColor = customColors.diffUnchanged!;
        prefix = ' ';
        break;
    }

    return Container(
      color: backgroundColor,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 12,
            child: Text(prefix,
                style: TextStyle(
                    color: textColor,
                    fontFamily: 'monospace',
                    fontSize: 11,
                    fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              line.text,
              style: TextStyle(
                  color: textColor, fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}
