import 'entities.dart';

abstract class INotebookRepository {
  Future<Notebook> createNotebook({
    required String name,
    required String llmProvider,
    required String modelName,
    String? apiKey,
    String? baseUrl,
    required String embeddingModel,
    double similarityThreshold = 0.70,
  });

  Future<Notebook> updateNotebook({
    required String id,
    required String name,
    required String llmProvider,
    required String modelName,
    String? apiKey,
    String? baseUrl,
    double similarityThreshold = 0.70,
  });
}

abstract class ISourceRepository {
  Future<Source> uploadSource({
    required String notebookId,
    required String fileName,
    required List<int> fileBytes,
  });

  Future<List<DocumentChunk>> getSourceChunks(String sourceId);
}

abstract class IChatRepository {
  Stream<Map<String, dynamic>> sendQueryStream({
    required String notebookId,
    required String message,
    required List<String> activeSourceIds,
    required bool enableWebFallback,
  });
}

abstract class IArtifactRepository {
  Future<Artifact> generateArtifact({
    required String notebookId,
    required String artifactType,
    required List<String> activeSourceIds,
  });

  Future<List<Artifact>> getNotebookArtifacts(String notebookId);
}
