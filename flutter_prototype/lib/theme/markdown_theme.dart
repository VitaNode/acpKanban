import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import '../constants/app_constants.dart';

class MarkdownTheme {
  static MarkdownStyleSheet getStyle(BuildContext context, {bool isUser = false}) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    const baseSize = 14.0;
    const baseHeight = 1.6;
    final bodyColor = isUser
        ? (isDark ? colorScheme.onPrimaryContainer : colorScheme.onSurface)
        : colorScheme.onSurface;

    return MarkdownStyleSheet(
      p: TextStyle(
        fontSize: baseSize,
        height: baseHeight,
        color: bodyColor,
      ),
      h1: TextStyle(
          fontSize: baseSize + 4,
          fontWeight: FontWeight.bold,
          height: baseHeight,
          color: colorScheme.primary),
      h2: TextStyle(
          fontSize: baseSize + 2,
          fontWeight: FontWeight.bold,
          height: baseHeight,
          color: colorScheme.primary),
      h3: TextStyle(
          fontSize: baseSize,
          fontWeight: FontWeight.bold,
          height: baseHeight,
          color: colorScheme.primary),
      h4: TextStyle(
          fontSize: baseSize,
          fontWeight: FontWeight.bold,
          height: baseHeight,
          color: colorScheme.primary),
      h5: TextStyle(
          fontSize: baseSize,
          fontWeight: FontWeight.bold,
          height: baseHeight,
          color: colorScheme.primary),
      h6: TextStyle(
          fontSize: baseSize,
          fontWeight: FontWeight.bold,
          height: baseHeight,
          color: colorScheme.primary),
      h1Align: WrapAlignment.start,
      h1Padding: const EdgeInsets.only(top: 16, bottom: 8),
      h2Padding: const EdgeInsets.only(top: 12, bottom: 4),
      h3Padding: const EdgeInsets.only(top: 8, bottom: 4),
      
      code: TextStyle(
        backgroundColor: isDark
            ? Colors.white.withOpacity(0.08)
            : Colors.black.withOpacity(0.05),
        fontFamily: 'monospace',
        fontSize: baseSize - 1,
        color: colorScheme.primary,
      ),
      codeblockDecoration: BoxDecoration(
        color: isDark
            ? Colors.white.withOpacity(0.04)
            : Colors.black.withOpacity(0.03),
        borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
        border: Border.all(color: colorScheme.outlineVariant.withOpacity(0.2)),
      ),
      codeblockPadding: const EdgeInsets.all(AppConstants.space12),
      
      blockquote: TextStyle(
        color: colorScheme.onSurfaceVariant.withOpacity(0.8),
        fontSize: baseSize,
        height: baseHeight,
        fontStyle: FontStyle.italic,
      ),
      blockquoteDecoration: BoxDecoration(
        color: colorScheme.primary.withOpacity(0.05),
        border: Border(
            left: BorderSide(color: colorScheme.primary.withOpacity(0.4), width: 3)),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      
      listBullet: TextStyle(
        fontSize: baseSize,
        color: colorScheme.onSurfaceVariant,
      ),
      listBulletPadding: const EdgeInsets.only(right: 8),
      
      tableBorder: TableBorder.all(
        color: colorScheme.outlineVariant,
        width: 1,
      ),
      tableBody: TextStyle(fontSize: baseSize - 1),
      tableHead: TextStyle(fontSize: baseSize - 1, fontWeight: FontWeight.bold),
      
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: colorScheme.outlineVariant.withOpacity(0.5), width: 1)),
      ),
      
      em: TextStyle(
        fontStyle: FontStyle.italic,
        color: bodyColor,
      ),
      strong: TextStyle(
        fontWeight: FontWeight.bold,
        color: bodyColor,
      ),
      del: TextStyle(
        decoration: TextDecoration.lineThrough,
        color: colorScheme.onSurfaceVariant,
      ),
      a: TextStyle(
        color: colorScheme.primary,
        decoration: TextDecoration.underline,
      ),
    );
  }

  static Map<String, MarkdownElementBuilder> getBuilders(BuildContext context) {
    return {
      'h1': HeaderBuilder('# '),
      'h2': HeaderBuilder('## '),
      'h3': HeaderBuilder('### '),
      'h4': HeaderBuilder('#### '),
      'h5': HeaderBuilder('##### '),
      'h6': HeaderBuilder('###### '),
    };
  }
}

class HeaderBuilder extends MarkdownElementBuilder {
  final String prefix;

  HeaderBuilder(this.prefix);

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: prefix,
            style: preferredStyle?.copyWith(
              color: preferredStyle.color?.withOpacity(0.4),
              fontWeight: FontWeight.normal,
            ),
          ),
          TextSpan(
            text: element.textContent,
            style: preferredStyle,
          ),
        ],
      ),
    );
  }
}
