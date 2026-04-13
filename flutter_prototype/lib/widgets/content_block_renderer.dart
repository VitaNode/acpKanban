import 'package:flutter/material.dart';
import '../models/content_block.dart';
import 'diff_viewer.dart';

class ContentBlockRenderer extends StatelessWidget {
  final ContentBlock block;
  final VoidCallback? onTap;

  const ContentBlockRenderer({
    super.key,
    required this.block,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    switch (block.type) {
      case ContentType.text:
        return _TextRenderer(block as TextContent);
      case ContentType.image:
        return _ImageRenderer(block as ImageContent);
      case ContentType.audio:
        return _AudioRenderer(block as AudioContent);
      case ContentType.resource:
        return _ResourceRenderer(block as ResourceContent);
      case ContentType.resourceLink:
        return _ResourceLinkRenderer(block as ResourceLink, onTap: onTap);
      case ContentType.diff:
        return DiffViewer(diff: block as DiffContent);
      case ContentType.terminal:
        return _TerminalRenderer(block as TerminalContent);
    }
  }
}

class _TextRenderer extends StatelessWidget {
  final TextContent content;
  const _TextRenderer(this.content);

  @override
  Widget build(BuildContext context) {
    return SelectableText(
      content.text,
      style: const TextStyle(fontSize: 14, height: 1.5),
    );
  }
}

class _ImageRenderer extends StatelessWidget {
  final ImageContent content;
  const _ImageRenderer(this.content);

  @override
  Widget build(BuildContext context) {
    if (content.data != null) {
      return Image.memory(content.decodedData);
    } else if (content.uri != null) {
      return Image.network(content.uri!);
    }
    return const SizedBox.shrink();
  }
}

class _AudioRenderer extends StatelessWidget {
  final AudioContent content;
  const _AudioRenderer(this.content);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.purple.shade50,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.audiotrack, color: Colors.purple),
          const SizedBox(width: 12),
          Text('Audio (${content.mimeType})',
              style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }
}

class _ResourceRenderer extends StatelessWidget {
  final ResourceContent content;
  const _ResourceRenderer(this.content);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.attach_file, size: 16, color: Colors.blue),
              const SizedBox(width: 8),
              Text(
                content.uri.split('/').last,
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ],
          ),
          if (content.text != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                content.text!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                maxLines: 10,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ResourceLinkRenderer extends StatelessWidget {
  final ResourceLink link;
  final VoidCallback? onTap;
  const _ResourceLinkRenderer(this.link, {this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.orange.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.orange.shade200),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.link, size: 16, color: Colors.orange),
            const SizedBox(width: 8),
            Text(link.name,
                style: const TextStyle(fontSize: 13, color: Colors.orange)),
          ],
        ),
      ),
    );
  }
}

class _TerminalRenderer extends StatelessWidget {
  final TerminalContent content;
  const _TerminalRenderer(this.content);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade900,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.terminal, size: 16, color: Colors.green),
              SizedBox(width: 8),
              Text('Terminal',
                  style: TextStyle(color: Colors.green, fontSize: 13)),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            height: 150,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Center(
              child: Text('Terminal ID: ${content.terminalId}',
                  style: const TextStyle(
                      color: Colors.green, fontFamily: 'monospace')),
            ),
          ),
        ],
      ),
    );
  }
}
