import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
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

class _AudioRenderer extends StatefulWidget {
  final AudioContent content;
  const _AudioRenderer(this.content);

  @override
  State<_AudioRenderer> createState() => _AudioRendererState();
}

class _AudioRendererState extends State<_AudioRenderer> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  bool _isLoading = false;
  bool _hasAudio = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _hasAudio = widget.content.data != null;
    _setupAudioPlayer();
  }

  void _setupAudioPlayer() {
    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() => _isPlaying = state == PlayerState.playing);
      }
    });

    _audioPlayer.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });

    _audioPlayer.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });

    if (_hasAudio) {
      _loadAudioFromData();
    }
  }

  Future<void> _loadAudioFromData() async {
    if (widget.content.data == null) return;
    setState(() => _isLoading = true);
    try {
      final bytes = widget.content.decodedData;
      if (bytes != null && bytes.isNotEmpty) {
        await _audioPlayer.setSourceBytes(bytes);
      }
    } catch (e) {
      debugPrint('Failed to load audio from data: $e');
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _togglePlayPause() async {
    if (_isPlaying) {
      await _audioPlayer.pause();
    } else {
      await _audioPlayer.resume();
    }
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(d.inMinutes.remainder(60));
    final seconds = twoDigits(d.inSeconds.remainder(60));
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.purple.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.purple.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.audiotrack, color: Colors.purple),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.content.mimeType,
                  style: const TextStyle(fontSize: 12, color: Colors.purple),
                ),
              ),
              if (_isLoading)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                IconButton(
                  icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                  color: Colors.purple,
                  onPressed: _hasAudio ? _togglePlayPause : null,
                ),
            ],
          ),
          if (_hasAudio) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  _formatDuration(_position),
                  style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
                ),
                Expanded(
                  child: Slider(
                    value: _position.inMilliseconds.toDouble(),
                    max: _duration.inMilliseconds
                        .toDouble()
                        .clamp(1, double.infinity),
                    onChanged: (value) {
                      _audioPlayer.seek(Duration(milliseconds: value.toInt()));
                    },
                    activeColor: Colors.purple,
                    inactiveColor: Colors.purple.shade200,
                  ),
                ),
                Text(
                  _formatDuration(_duration),
                  style: const TextStyle(fontSize: 10, fontFamily: 'monospace'),
                ),
              ],
            ),
          ],
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

class _TerminalRenderer extends StatefulWidget {
  final TerminalContent content;
  const _TerminalRenderer(this.content);

  @override
  State<_TerminalRenderer> createState() => _TerminalRendererState();
}

class _TerminalRendererState extends State<_TerminalRenderer> {
  final ScrollController _scrollController = ScrollController();
  String _output = 'Terminal session: ${''}';
  bool _isSessionActive = true;

  @override
  void initState() {
    super.initState();
    _output = 'Terminal session: ${widget.content.terminalId}\n';
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 100),
        curve: Curves.easeOut,
      );
    }
  }

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
          Row(
            children: [
              const Icon(Icons.terminal, size: 16, color: Colors.green),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Terminal - ${widget.content.terminalId}',
                  style: const TextStyle(color: Colors.green, fontSize: 13),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: _isSessionActive
                      ? Colors.green.shade700
                      : Colors.grey.shade700,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _isSessionActive ? 'ACTIVE' : 'ENDED',
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            height: 150,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(4),
            ),
            child: ListView(
              controller: _scrollController,
              padding: const EdgeInsets.all(8),
              children: [
                Text(
                  _output,
                  style: const TextStyle(
                    color: Colors.green,
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                '${_output.split('\n').length - 1} lines',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 10),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
