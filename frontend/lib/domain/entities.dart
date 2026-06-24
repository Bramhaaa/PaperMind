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
