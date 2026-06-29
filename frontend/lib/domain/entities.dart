import 'package:equatable/equatable.dart';

class Notebook extends Equatable {
  final String id;
  final String name;
  final String llmProvider;
  final String modelName;
  final String? apiKey;
  final String? baseUrl;
  final String embeddingModel;
  final double similarityThreshold;

  const Notebook({
    required this.id,
    required this.name,
    required this.llmProvider,
    required this.modelName,
    this.apiKey,
    this.baseUrl,
    required this.embeddingModel,
    required this.similarityThreshold,
  });

  @override
  List<Object?> get props => [
        id,
        name,
        llmProvider,
        modelName,
        apiKey,
        baseUrl,
        embeddingModel,
        similarityThreshold,
      ];
}

class Source extends Equatable {
  final String id;
  final String notebookId;
  final String name;
  final String fileType;
  final int sizeBytes;
  final String ingestionStatus; // 'pending', 'processing', 'completed', 'failed'
  final DateTime createdAt;

  const Source({
    required this.id,
    required this.notebookId,
    required this.name,
    required this.fileType,
    required this.sizeBytes,
    required this.ingestionStatus,
    required this.createdAt,
  });

  @override
  List<Object?> get props => [
        id,
        notebookId,
        name,
        fileType,
        sizeBytes,
        ingestionStatus,
        createdAt,
      ];
}

class Citation extends Equatable {
  final String sourceId;
  final String name;
  final int? pageNumber;
  final double? audioTimestampSeconds;

  const Citation({
    required this.sourceId,
    required this.name,
    this.pageNumber,
    this.audioTimestampSeconds,
  });

  factory Citation.fromJson(Map<String, dynamic> json) {
    return Citation(
      sourceId: json['source_id'] as String,
      name: json['name'] as String,
      pageNumber: json['page_number'] as int?,
      audioTimestampSeconds: (json['audio_timestamp_seconds'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'source_id': sourceId,
      'name': name,
      'page_number': pageNumber,
      'audio_timestamp_seconds': audioTimestampSeconds,
    };
  }

  @override
  List<Object?> get props => [sourceId, name, pageNumber, audioTimestampSeconds];
}

class ChatTurn extends Equatable {
  final String role; // 'user' or 'assistant'
  final String content;
  final List<Citation> citations;

  const ChatTurn({
    required this.role,
    required this.content,
    required this.citations,
  });

  @override
  List<Object?> get props => [role, content, citations];
}

class Artifact extends Equatable {
  final String id;
  final String notebookId;
  final String type; // 'flashcards', 'timeline', 'summary'
  final String sourceHash;
  final Map<String, dynamic> payload;
  final DateTime createdAt;

  const Artifact({
    required this.id,
    required this.notebookId,
    required this.type,
    required this.sourceHash,
    required this.payload,
    required this.createdAt,
  });

  @override
  List<Object?> get props => [id, notebookId, type, sourceHash, payload, createdAt];
}

class DocumentChunk extends Equatable {
  final String id;
  final int chunkIndex;
  final int? pageNumber;
  final int charStart;
  final int charEnd;
  final double? audioTimestampSeconds;
  final String content;

  const DocumentChunk({
    required this.id,
    required this.chunkIndex,
    this.pageNumber,
    required this.charStart,
    required this.charEnd,
    this.audioTimestampSeconds,
    required this.content,
  });

  factory DocumentChunk.fromJson(Map<String, dynamic> json) {
    return DocumentChunk(
      id: json['id'] as String,
      chunkIndex: json['chunk_index'] as int,
      pageNumber: json['page_number'] as int?,
      charStart: json['char_start'] as int,
      charEnd: json['char_end'] as int,
      audioTimestampSeconds: (json['audio_timestamp_seconds'] as num?)?.toDouble(),
      content: json['content'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'chunk_index': chunkIndex,
      'page_number': pageNumber,
      'char_start': charStart,
      'char_end': charEnd,
      'audio_timestamp_seconds': audioTimestampSeconds,
      'content': content,
    };
  }

  @override
  List<Object?> get props => [
        id,
        chunkIndex,
        pageNumber,
        charStart,
        charEnd,
        audioTimestampSeconds,
        content,
      ];
}

