import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../domain/entities.dart';
import '../../domain/repositories.dart';

// --- EVENTS ---
abstract class SourceEvent extends Equatable {
  const SourceEvent();
  @override
  List<Object?> get props => [];
}

class LoadSourcesEvent extends SourceEvent {
  final List<Source> sources;
  final List<String> activeSourceIds;
  const LoadSourcesEvent({required this.sources, required this.activeSourceIds});
  @override
  List<Object?> get props => [sources, activeSourceIds];
}

class UploadDocumentEvent extends SourceEvent {
  final String notebookId;
  final String fileName;
  final List<int> fileBytes;
  const UploadDocumentEvent({
    required this.notebookId,
    required this.fileName,
    required this.fileBytes,
  });
  @override
  List<Object?> get props => [notebookId, fileName, fileBytes];
}

class ToggleSourceEvent extends SourceEvent {
  final String sourceId;
  const ToggleSourceEvent({required this.sourceId});
  @override
  List<Object?> get props => [sourceId];
}


// --- STATES ---
abstract class SourceState extends Equatable {
  const SourceState();
  @override
  List<Object?> get props => [];
}

class SourceInitial extends SourceState {}

class SourceUploadInProgress extends SourceState {}

class SourceUploadSuccess extends SourceState {
  final Source uploadedSource;
  final List<Source> allSources;
  final List<String> activeSourceIds;

  const SourceUploadSuccess({
    required this.uploadedSource,
    required this.allSources,
    required this.activeSourceIds,
  });

  @override
  List<Object?> get props => [uploadedSource, allSources, activeSourceIds];
}

class SourceSelectionUpdated extends SourceState {
  final List<Source> allSources;
  final List<String> activeSourceIds;

  const SourceSelectionUpdated({
    required this.allSources,
    required this.activeSourceIds,
  });

  @override
  List<Object?> get props => [allSources, activeSourceIds];
}

class SourceError extends SourceState {
  final String message;
  const SourceError(this.message);
  @override
  List<Object?> get props => [message];
}


// --- BLOC ---
class SourceBloc extends Bloc<SourceEvent, SourceState> {
  final ISourceRepository sourceRepository;
  
  List<Source> _allSources = [];
  List<String> _activeSourceIds = [];

  SourceBloc({required this.sourceRepository}) : super(SourceInitial()) {
    on<LoadSourcesEvent>((event, emit) {
      _allSources = List.from(event.sources);
      _activeSourceIds = List.from(event.activeSourceIds);
      emit(SourceSelectionUpdated(
        allSources: List.unmodifiable(_allSources),
        activeSourceIds: List.unmodifiable(_activeSourceIds),
      ));
    });

    on<UploadDocumentEvent>((event, emit) async {
      emit(SourceUploadInProgress());
      try {
        final source = await sourceRepository.uploadSource(
          notebookId: event.notebookId,
          fileName: event.fileName,
          fileBytes: event.fileBytes,
        );
        _allSources.add(source);
        _activeSourceIds.add(source.id); // Auto-enable source on upload
        emit(SourceUploadSuccess(
          uploadedSource: source,
          allSources: List.unmodifiable(_allSources),
          activeSourceIds: List.unmodifiable(_activeSourceIds),
        ));
      } catch (e) {
        emit(SourceError(e.toString()));
      }
    });

    on<ToggleSourceEvent>((event, emit) {
      final id = event.sourceId;
      if (_activeSourceIds.contains(id)) {
        _activeSourceIds.remove(id);
      } else {
        _activeSourceIds.add(id);
      }
      emit(SourceSelectionUpdated(
        allSources: List.unmodifiable(_allSources),
        activeSourceIds: List.unmodifiable(_activeSourceIds),
      ));
    });
  }
}
