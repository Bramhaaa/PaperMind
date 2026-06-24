import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../domain/entities.dart';
import '../../domain/repositories.dart';

// --- EVENTS ---
abstract class ArtifactEvent extends Equatable {
  const ArtifactEvent();
  @override
  List<Object?> get props => [];
}

class LoadArtifactsEvent extends ArtifactEvent {
  final String notebookId;
  const LoadArtifactsEvent({required this.notebookId});

  @override
  List<Object?> get props => [notebookId];
}

class GenerateArtifactEvent extends ArtifactEvent {
  final String notebookId;
  final String artifactType; // 'flashcards', 'timeline', 'summary'
  final List<String> activeSourceIds;

  const GenerateArtifactEvent({
    required this.notebookId,
    required this.artifactType,
    required this.activeSourceIds,
  });

  @override
  List<Object?> get props => [notebookId, artifactType, activeSourceIds];
}

// --- STATES ---
abstract class ArtifactState extends Equatable {
  const ArtifactState();
  @override
  List<Object?> get props => [];
}

class ArtifactInitial extends ArtifactState {}

class ArtifactLoadInProgress extends ArtifactState {}

class ArtifactLoadSuccess extends ArtifactState {
  final List<Artifact> artifacts;
  const ArtifactLoadSuccess({required this.artifacts});

  @override
  List<Object?> get props => [artifacts];
}

class ArtifactGenerationInProgress extends ArtifactState {
  final String artifactType;
  const ArtifactGenerationInProgress({required this.artifactType});

  @override
  List<Object?> get props => [artifactType];
}

class ArtifactGenerationSuccess extends ArtifactState {
  final Artifact artifact;
  final List<Artifact> allArtifacts;
  const ArtifactGenerationSuccess({required this.artifact, required this.allArtifacts});

  @override
  List<Object?> get props => [artifact, allArtifacts];
}

class ArtifactFailure extends ArtifactState {
  final String message;
  const ArtifactFailure(this.message);

  @override
  List<Object?> get props => [message];
}

// --- BLOC ---
class ArtifactBloc extends Bloc<ArtifactEvent, ArtifactState> {
  final IArtifactRepository artifactRepository;
  List<Artifact> _cachedArtifacts = [];

  ArtifactBloc({required this.artifactRepository}) : super(ArtifactInitial()) {
    on<LoadArtifactsEvent>((event, emit) async {
      emit(ArtifactLoadInProgress());
      try {
        final list = await artifactRepository.getNotebookArtifacts(event.notebookId);
        _cachedArtifacts = List.from(list);
        emit(ArtifactLoadSuccess(artifacts: List.unmodifiable(_cachedArtifacts)));
      } catch (e) {
        emit(ArtifactFailure(e.toString()));
      }
    });

    on<GenerateArtifactEvent>((event, emit) async {
      emit(ArtifactGenerationInProgress(artifactType: event.artifactType));
      try {
        final artifact = await artifactRepository.generateArtifact(
          notebookId: event.notebookId,
          artifactType: event.artifactType,
          activeSourceIds: event.activeSourceIds,
        );
        // Avoid adding duplicate artifacts if it was a cache hit in the DB
        _cachedArtifacts.removeWhere((item) => item.id == artifact.id);
        _cachedArtifacts.add(artifact);
        emit(ArtifactGenerationSuccess(
          artifact: artifact,
          allArtifacts: List.unmodifiable(_cachedArtifacts),
        ));
      } catch (e) {
        emit(ArtifactFailure(e.toString()));
      }
    });
  }
}
