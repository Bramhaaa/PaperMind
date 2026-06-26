import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:http/http.dart' as http;

// --- EVENTS ---
abstract class ProviderEvent extends Equatable {
  const ProviderEvent();
  @override
  List<Object?> get props => [];
}

class ConfigureProviderEvent extends ProviderEvent {
  final String provider;
  final String modelName;
  final String? apiKey;
  final String? baseUrl;

  const ConfigureProviderEvent({
    required this.provider,
    required this.modelName,
    this.apiKey,
    this.baseUrl,
  });

  @override
  List<Object?> get props => [provider, modelName, apiKey, baseUrl];
}

// --- STATES ---
abstract class ProviderState extends Equatable {
  const ProviderState();
  @override
  List<Object?> get props => [];
}

class ProviderInitial extends ProviderState {}

class ProviderValidating extends ProviderState {}

class ProviderReady extends ProviderState {
  final String provider;
  final String modelName;
  const ProviderReady({required this.provider, required this.modelName});

  @override
  List<Object?> get props => [provider, modelName];
}

class ProviderError extends ProviderState {
  final String message;
  const ProviderError(this.message);

  @override
  List<Object?> get props => [message];
}

// --- BLOC ---
class ProviderBloc extends Bloc<ProviderEvent, ProviderState> {
  final String backendBaseUrl;

  ProviderBloc({required this.backendBaseUrl}) : super(ProviderInitial()) {
    on<ConfigureProviderEvent>((event, emit) async {
      emit(ProviderValidating());
      try {
        // 1. First verify backend /health is reachable
        final healthUri = Uri.parse('$backendBaseUrl/health');
        final response = await http.get(healthUri).timeout(const Duration(seconds: 5));
        if (response.statusCode != 200) {
          throw Exception("Backend /health responded with code ${response.statusCode}");
        }

        // 2. Local-first check
        if (event.provider.toLowerCase() == 'ollama') {
          final baseOllamaUrl = (event.baseUrl == null || event.baseUrl!.trim().isEmpty)
              ? 'http://localhost:11434'
              : event.baseUrl!.trim();
          try {
            final ollamaUri = Uri.parse('$baseOllamaUrl/api/tags');
            final ollamaResp = await http.get(ollamaUri).timeout(const Duration(seconds: 3));
            if (ollamaResp.statusCode != 200) {
              throw Exception("Ollama server responded with code ${ollamaResp.statusCode}");
            }
          } catch (e) {
            throw Exception("Ollama server at $baseOllamaUrl is unreachable. Please ensure Ollama is running (OLLAMA_HOST=0.0.0.0 ollama serve).");
          }
        } else {
          // Cloud provider check: must have a non-empty key
          if (event.apiKey == null || event.apiKey!.trim().isEmpty) {
            throw Exception("API Key is required for provider: ${event.provider}");
          }
        }

        emit(ProviderReady(provider: event.provider, modelName: event.modelName));
      } catch (e) {
        emit(ProviderError(e.toString()));
      }
    });
  }
}
