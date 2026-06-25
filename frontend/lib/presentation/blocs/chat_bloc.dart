import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../domain/entities.dart';
import '../../domain/repositories.dart';

// --- EVENTS ---
abstract class ChatEvent extends Equatable {
  const ChatEvent();
  @override
  List<Object?> get props => [];
}

class LoadHistoryEvent extends ChatEvent {
  final List<ChatTurn> history;
  const LoadHistoryEvent(this.history);
  @override
  List<Object?> get props => [history];
}

class SubmitMessageEvent extends ChatEvent {
  final String notebookId;
  final String message;
  final List<String> activeSourceIds;
  final bool enableWebFallback;

  const SubmitMessageEvent({
    required this.notebookId,
    required this.message,
    required this.activeSourceIds,
    this.enableWebFallback = true,
  });

  @override
  List<Object?> get props => [notebookId, message, activeSourceIds, enableWebFallback];
}


// --- STATES ---
abstract class ChatState extends Equatable {
  const ChatState();
  @override
  List<Object?> get props => [];
}

class ChatInitial extends ChatState {}

class ChatResponseLoading extends ChatState {
  final List<ChatTurn> history;
  const ChatResponseLoading(this.history);
  @override
  List<Object?> get props => [history];
}

class ChatResponseStreaming extends ChatState {
  final String currentResponse;
  final List<ChatTurn> history;

  const ChatResponseStreaming({
    required this.currentResponse,
    required this.history,
  });

  @override
  List<Object?> get props => [currentResponse, history];
}

class ChatResponseSuccess extends ChatState {
  final List<ChatTurn> history;
  final List<Citation> citations;
  final String sourceTypeUsed; // 'local_documents' or 'web'

  const ChatResponseSuccess({
    required this.history,
    required this.citations,
    required this.sourceTypeUsed,
  });

  @override
  List<Object?> get props => [history, citations, sourceTypeUsed];
}

class WebFallbackBannerVisible extends ChatState {
  final List<ChatTurn> history;

  const WebFallbackBannerVisible({required this.history});

  @override
  List<Object?> get props => [history];
}

class ChatError extends ChatState {
  final String message;
  final List<ChatTurn> history;
  const ChatError(this.message, this.history);
  @override
  List<Object?> get props => [message, history];
}


// --- BLOC ---
class ChatBloc extends Bloc<ChatEvent, ChatState> {
  final IChatRepository chatRepository;
  final List<ChatTurn> _history = [];

  ChatBloc({required this.chatRepository}) : super(ChatInitial()) {
    on<LoadHistoryEvent>((event, emit) {
      _history.clear();
      _history.addAll(event.history);
      emit(ChatResponseSuccess(
        history: List.unmodifiable(_history),
        citations: const [],
        sourceTypeUsed: "local_documents",
      ));
    });

    on<SubmitMessageEvent>((event, emit) async {
      // 1. Immediately add the user's query to history
      _history.add(ChatTurn(
        role: "user",
        content: event.message,
        citations: const [],
      ));

      // 2. Emit loading state with the updated history (so user message shows first)
      emit(ChatResponseLoading(List.unmodifiable(_history)));

      String accumulatedResponse = "";
      List<Citation> finalCitations = [];
      String sourceTypeUsed = "local_documents";
      bool streamFailed = false;
      String errorMsg = "";

      try {
        await emit.forEach<Map<String, dynamic>>(
          chatRepository.sendQueryStream(
            notebookId: event.notebookId,
            message: event.message,
            activeSourceIds: event.activeSourceIds,
            enableWebFallback: event.enableWebFallback,
          ),
          onData: (data) {
            final type = data["type"];
            if (type == "token") {
              accumulatedResponse += (data["content"] as String? ?? "");
              return ChatResponseStreaming(
                currentResponse: accumulatedResponse,
                history: List.unmodifiable(_history),
              );
            } else if (type == "citations") {
              final list = data["citations"] as List?;
              if (list != null) {
                finalCitations = list
                    .map((item) => Citation.fromJson(item as Map<String, dynamic>))
                    .toList();
              }
            } else if (type == "done") {
              sourceTypeUsed = data["source_type_used"] as String? ?? "local_documents";
            } else if (type == "error") {
              streamFailed = true;
              errorMsg = data["content"] as String? ?? "Unknown streaming error";
              return ChatError(errorMsg, List.unmodifiable(_history));
            }
            return ChatResponseStreaming(
              currentResponse: accumulatedResponse,
              history: List.unmodifiable(_history),
            );
          },
          onError: (error, stackTrace) {
            streamFailed = true;
            errorMsg = error.toString();
            return ChatError(errorMsg, List.unmodifiable(_history));
          },
        );
      } catch (e) {
        streamFailed = true;
        errorMsg = e.toString();
        emit(ChatError(errorMsg, List.unmodifiable(_history)));
      }

      if (streamFailed) {
        emit(ChatError(errorMsg, List.unmodifiable(_history)));
        return;
      }

      // Add assistant reply to our in-memory history turns
      _history.add(ChatTurn(
        role: "assistant",
        content: accumulatedResponse,
        citations: finalCitations,
      ));

      emit(ChatResponseSuccess(
        history: List.unmodifiable(_history),
        citations: finalCitations,
        sourceTypeUsed: sourceTypeUsed,
      ));

      // Trigger the WebFallbackBannerVisible state so the UI displays the web source banner
      if (sourceTypeUsed == "web") {
        emit(WebFallbackBannerVisible(
          history: List.unmodifiable(_history),
        ));
      }
    });
  }
}
