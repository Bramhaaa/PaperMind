import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

import '../domain/entities.dart';
import '../domain/repositories.dart';

class NotebookRepositoryImpl implements INotebookRepository {
  final String baseUrl;
  final http.Client client;

  NotebookRepositoryImpl({required this.baseUrl, required this.client});

  @override
  Future<Notebook> createNotebook({
    required String name,
    required String llmProvider,
    required String modelName,
    String? apiKey,
    String? baseUrl,
    required String embeddingModel,
    double similarityThreshold = 0.70,
  }) async {
    final url = Uri.parse("${this.baseUrl}/api/v1/notebooks");
    final response = await client.post(
      url,
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "name": name,
        "llm_provider": llmProvider,
        "model_name": modelName,
        "api_key": apiKey,
        "base_url": baseUrl,
        "embedding_model": embeddingModel,
        "similarity_threshold": similarityThreshold,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception("Failed to create notebook: ${response.body}");
    }

    final data = jsonDecode(response.body);
    return Notebook(
      id: data["notebook_id"] as String,
      name: data["name"] as String,
      llmProvider: data["llm_provider"] as String,
      modelName: data["model_name"] as String,
      apiKey: apiKey,
      baseUrl: baseUrl,
      embeddingModel: data["embedding_model"] as String,
      similarityThreshold: (data["similarity_threshold"] as num).toDouble(),
    );
  }
}

class SourceRepositoryImpl implements ISourceRepository {
  final String baseUrl;
  final http.Client client;

  SourceRepositoryImpl({required this.baseUrl, required this.client});

  @override
  Future<Source> uploadSource({
    required String notebookId,
    required String fileName,
    required List<int> fileBytes,
  }) async {
    final url = Uri.parse("$baseUrl/api/v1/sources/upload");
    final request = http.MultipartRequest("POST", url);
    request.fields["notebook_id"] = notebookId;
    request.files.add(
      http.MultipartFile.fromBytes(
        "file",
        fileBytes,
        filename: fileName,
      ),
    );

    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      throw Exception("Failed to upload document: ${response.body}");
    }

    final data = jsonDecode(response.body);
    return Source(
      id: data["source_id"] as String,
      notebookId: notebookId,
      name: fileName,
      fileType: fileName.split('.').last,
      sizeBytes: fileBytes.length,
      ingestionStatus: data["status"] == "ingestion_queued" ? "processing" : "completed",
      createdAt: DateTime.now(),
    );
  }
}

class ChatRepositoryImpl implements IChatRepository {
  final String baseUrl;
  final http.Client client;

  ChatRepositoryImpl({required this.baseUrl, required this.client});

  @override
  Stream<Map<String, dynamic>> sendQueryStream({
    required String notebookId,
    required String message,
    required List<String> activeSourceIds,
    required bool enableWebFallback,
  }) {
    final controller = StreamController<Map<String, dynamic>>();
    final url = Uri.parse("$baseUrl/api/v1/chat/query");

    final request = http.Request("POST", url);
    request.headers["Content-Type"] = "application/json";
    request.body = jsonEncode({
      "notebook_id": notebookId,
      "message": message,
      "active_source_ids": activeSourceIds,
      "enable_web_fallback": enableWebFallback,
      "stream": true,
    });

    client.send(request).then((response) {
      if (response.statusCode != 200) {
        controller.addError(Exception("Query connection failed with status: ${response.statusCode}"));
        controller.close();
        return;
      }

      response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (line.startsWith("data: ")) {
          try {
            final jsonStr = line.substring(6).trim();
            final data = jsonDecode(jsonStr);
            controller.add(data as Map<String, dynamic>);
          } catch (e) {
            // Ignore format parsing exceptions of empty/heartbeat lines
          }
        }
      }, onError: (error) {
        controller.addError(error);
        controller.close();
      }, onDone: () {
        controller.close();
      });
    }).catchError((error) {
      controller.addError(error);
      controller.close();
    });

    return controller.stream;
  }
}

class ArtifactRepositoryImpl implements IArtifactRepository {
  final String baseUrl;
  final http.Client client;

  ArtifactRepositoryImpl({required this.baseUrl, required this.client});

  @override
  Future<Artifact> generateArtifact({
    required String notebookId,
    required String artifactType,
    required List<String> activeSourceIds,
  }) async {
    final url = Uri.parse("$baseUrl/api/v1/artifacts/generate");
    final response = await client.post(
      url,
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "notebook_id": notebookId,
        "artifact_type": artifactType,
        "active_source_ids": activeSourceIds,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception("Failed to generate artifact: ${response.body}");
    }

    final data = jsonDecode(response.body);
    return Artifact(
      id: data["artifact_id"] as String,
      notebookId: notebookId,
      type: data["artifact_type"] as String,
      sourceHash: data["source_hash"] as String? ?? "",
      payload: data["payload"] as Map<String, dynamic>,
      createdAt: DateTime.parse(data["created_at"] as String),
    );
  }

  @override
  Future<List<Artifact>> getNotebookArtifacts(String notebookId) async {
    final url = Uri.parse("$baseUrl/api/v1/notebooks/$notebookId/artifacts");
    final response = await client.get(url);

    if (response.statusCode != 200) {
      throw Exception("Failed to retrieve notebook artifacts: ${response.body}");
    }

    final data = jsonDecode(response.body);
    final list = data["artifacts"] as List;
    return list.map((item) {
      return Artifact(
        id: item["artifact_id"] as String,
        notebookId: notebookId,
        type: item["artifact_type"] as String,
        sourceHash: item["source_hash"] as String? ?? "",
        payload: item["payload"] as Map<String, dynamic>,
        createdAt: DateTime.parse(item["created_at"] as String),
      );
    }).toList();
  }
}
