import 'dart:convert';
import 'dart:typed_data';

enum ContentType {
  text,
  image,
  audio,
  resource,
  resourceLink,
  diff,
  terminal,
}

abstract class ContentBlock {
  final ContentType type;
  final Map<String, dynamic>? annotations;

  const ContentBlock({required this.type, this.annotations});

  factory ContentBlock.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String;
    switch (typeStr) {
      case 'text':
        return TextContent.fromJson(json);
      case 'image':
        return ImageContent.fromJson(json);
      case 'audio':
        return AudioContent.fromJson(json);
      case 'resource':
        return ResourceContent.fromJson(json);
      case 'resource_link':
        return ResourceLink.fromJson(json);
      case 'diff':
        return DiffContent.fromJson(json);
      case 'terminal':
        return TerminalContent.fromJson(json);
      default:
        return TextContent(text: json['text'] ?? '');
    }
  }

  Map<String, dynamic> toJson();
}

class TextContent extends ContentBlock {
  final String text;

  const TextContent({required this.text}) : super(type: ContentType.text);

  factory TextContent.fromJson(Map<String, dynamic> json) {
    return TextContent(text: json['text'] as String);
  }

  @override
  Map<String, dynamic> toJson() => {'type': 'text', 'text': text};
}

class ImageContent extends ContentBlock {
  final String mimeType;
  final String? data;
  final String? uri;

  const ImageContent({
    required this.mimeType,
    this.data,
    this.uri,
  }) : super(type: ContentType.image);

  factory ImageContent.fromJson(Map<String, dynamic> json) {
    return ImageContent(
      mimeType: json['mimeType'] as String,
      data: json['data'] as String?,
      uri: json['uri'] as String?,
    );
  }

  Uint8List get decodedData =>
      data != null ? base64Decode(data!) : Uint8List(0);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'image',
        'mimeType': mimeType,
        if (data != null) 'data': data,
        if (uri != null) 'uri': uri,
      };
}

class AudioContent extends ContentBlock {
  final String mimeType;
  final String? data;

  const AudioContent({required this.mimeType, this.data})
      : super(type: ContentType.audio);

  factory AudioContent.fromJson(Map<String, dynamic> json) {
    return AudioContent(
      mimeType: json['mimeType'] as String,
      data: json['data'] as String?,
    );
  }

  Uint8List? get decodedData => data != null ? base64Decode(data!) : null;

  @override
  Map<String, dynamic> toJson() => {
        'type': 'audio',
        'mimeType': mimeType,
        if (data != null) 'data': data,
      };
}

class ResourceContent extends ContentBlock {
  final String uri;
  final String mimeType;
  final String? text;
  final String? blob;

  const ResourceContent({
    required this.uri,
    required this.mimeType,
    this.text,
    this.blob,
  }) : super(type: ContentType.resource);

  factory ResourceContent.fromJson(Map<String, dynamic> json) {
    final resource = json['resource'] as Map<String, dynamic>;
    return ResourceContent(
      uri: resource['uri'] as String,
      mimeType: resource['mimeType'] as String,
      text: resource['text'] as String?,
      blob: resource['blob'] as String?,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'resource',
        'resource': {
          'uri': uri,
          'mimeType': mimeType,
          if (text != null) 'text': text,
          if (blob != null) 'blob': blob,
        },
      };
}

class ResourceLink extends ContentBlock {
  final String uri;
  final String name;
  final String? mimeType;
  final String? title;
  final String? description;
  final int? size;

  const ResourceLink({
    required this.uri,
    required this.name,
    this.mimeType,
    this.title,
    this.description,
    this.size,
  }) : super(type: ContentType.resourceLink);

  factory ResourceLink.fromJson(Map<String, dynamic> json) {
    return ResourceLink(
      uri: json['uri'] as String,
      name: json['name'] as String,
      mimeType: json['mimeType'] as String?,
      title: json['title'] as String?,
      description: json['description'] as String?,
      size: json['size'] as int?,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'resource_link',
        'uri': uri,
        'name': name,
        if (mimeType != null) 'mimeType': mimeType,
        if (title != null) 'title': title,
        if (description != null) 'description': description,
        if (size != null) 'size': size,
      };
}

class DiffContent extends ContentBlock {
  final String path;
  final String? oldText;
  final String newText;

  const DiffContent({
    required this.path,
    this.oldText,
    required this.newText,
  }) : super(type: ContentType.diff);

  factory DiffContent.fromJson(Map<String, dynamic> json) {
    return DiffContent(
      path: json['path'] as String,
      oldText: json['oldText'] as String?,
      newText: json['newText'] as String,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'diff',
        'path': path,
        if (oldText != null) 'oldText': oldText,
        'newText': newText,
      };
}

class TerminalContent extends ContentBlock {
  final String terminalId;

  const TerminalContent({required this.terminalId})
      : super(type: ContentType.terminal);

  factory TerminalContent.fromJson(Map<String, dynamic> json) {
    return TerminalContent(terminalId: json['terminalId'] as String);
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'terminal',
        'terminalId': terminalId,
      };
}
