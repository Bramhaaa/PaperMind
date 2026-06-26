import 'package:flutter_test/flutter_test.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:frontend/domain/entities.dart';
import 'package:frontend/domain/repositories.dart';
import 'package:frontend/presentation/blocs/source_bloc.dart';
import 'package:frontend/presentation/blocs/chat_bloc.dart';
import 'package:frontend/presentation/blocs/artifact_bloc.dart';
import 'package:frontend/presentation/blocs/provider_bloc.dart';

// Mocks
class MockSourceRepository extends Mock implements ISourceRepository {}
class MockChatRepository extends Mock implements IChatRepository {}
class MockArtifactRepository extends Mock implements IArtifactRepository {}

void main() {
  late MockSourceRepository mockSourceRepository;
  late MockChatRepository mockChatRepository;
  late MockArtifactRepository mockArtifactRepository;

  setUpAll(() {
    // Register fallback values for mocktail matching
    registerFallbackValue([]);
  });

  setUp(() {
    mockSourceRepository = MockSourceRepository();
    mockChatRepository = MockChatRepository();
    mockArtifactRepository = MockArtifactRepository();
  });

  group('SourceBloc Tests', () {
    final sampleSource = Source(
      id: 'src-1',
      notebookId: 'nb-1',
      name: 'quantum_physics.pdf',
      fileType: 'pdf',
      sizeBytes: 1024,
      ingestionStatus: 'completed',
      createdAt: DateTime.now(),
    );

    blocTest<SourceBloc, SourceState>(
      'emits SourceSelectionUpdated when LoadSourcesEvent is added',
      build: () => SourceBloc(sourceRepository: mockSourceRepository),
      act: (bloc) => bloc.add(LoadSourcesEvent(sources: [sampleSource], activeSourceIds: const ['src-1'])),
      expect: () => [
        SourceSelectionUpdated(allSources: [sampleSource], activeSourceIds: const ['src-1']),
      ],
    );

    blocTest<SourceBloc, SourceState>(
      'emits [SourceUploadInProgress, SourceUploadSuccess] when UploadDocumentEvent succeeds',
      build: () {
        when(() => mockSourceRepository.uploadSource(
              notebookId: any(named: 'notebookId'),
              fileName: any(named: 'fileName'),
              fileBytes: any(named: 'fileBytes'),
            )).thenAnswer((_) async => sampleSource);
        return SourceBloc(sourceRepository: mockSourceRepository);
      },
      act: (bloc) => bloc.add(const UploadDocumentEvent(
        notebookId: 'nb-1',
        fileName: 'quantum_physics.pdf',
        fileBytes: [1, 2, 3],
      )),
      expect: () => [
        SourceUploadInProgress(),
        SourceUploadSuccess(
          uploadedSource: sampleSource,
          allSources: [sampleSource],
          activeSourceIds: [sampleSource.id],
        ),
      ],
    );

    blocTest<SourceBloc, SourceState>(
      'emits SourceSelectionUpdated with toggled active status on ToggleSourceEvent',
      build: () => SourceBloc(sourceRepository: mockSourceRepository),
      act: (bloc) {
        bloc.add(LoadSourcesEvent(sources: [sampleSource], activeSourceIds: const ['src-1']));
        bloc.add(const ToggleSourceEvent(sourceId: 'src-1'));
      },
      expect: () => [
        SourceSelectionUpdated(allSources: [sampleSource], activeSourceIds: const ['src-1']),
        SourceSelectionUpdated(allSources: [sampleSource], activeSourceIds: const []),
      ],
    );
  });

  group('ChatBloc Tests', () {
    blocTest<ChatBloc, ChatState>(
      'emits ChatResponseSuccess when LoadHistoryEvent is added',
      build: () => ChatBloc(chatRepository: mockChatRepository),
      act: (bloc) => bloc.add(const LoadHistoryEvent([
        ChatTurn(role: 'user', content: 'hello', citations: []),
        ChatTurn(role: 'assistant', content: 'hi', citations: []),
      ])),
      expect: () => [
        const ChatResponseSuccess(
          history: [
            ChatTurn(role: 'user', content: 'hello', citations: []),
            ChatTurn(role: 'assistant', content: 'hi', citations: []),
          ],
          citations: [],
          sourceTypeUsed: 'local_documents',
        ),
      ],
    );

    blocTest<ChatBloc, ChatState>(
      'emits [ChatResponseLoading, ChatResponseStreaming, ChatResponseSuccess] during stream answers',
      build: () {
        when(() => mockChatRepository.sendQueryStream(
              notebookId: any(named: 'notebookId'),
              message: any(named: 'message'),
              activeSourceIds: any(named: 'activeSourceIds'),
              enableWebFallback: any(named: 'enableWebFallback'),
            )).thenAnswer((_) => Stream.fromIterable([
                  {"type": "token", "content": "Hello"},
                  {"type": "token", "content": " world!"},
                  {
                    "type": "citations",
                    "citations": [
                      {"source_id": "src-1", "name": "doc.pdf", "page_number": 2}
                    ]
                  },
                  {"type": "done", "source_type_used": "local_documents"}
                ]));
        return ChatBloc(chatRepository: mockChatRepository);
      },
      act: (bloc) => bloc.add(const SubmitMessageEvent(
        notebookId: 'nb-1',
        message: 'Explain relativity',
        activeSourceIds: ['src-1'],
      )),
      expect: () => [
        const ChatResponseLoading([
          ChatTurn(role: 'user', content: 'Explain relativity', citations: []),
        ]),
        const ChatResponseStreaming(
          currentResponse: 'Hello',
          history: [
            ChatTurn(role: 'user', content: 'Explain relativity', citations: []),
          ],
        ),
        const ChatResponseStreaming(
          currentResponse: 'Hello world!',
          history: [
            ChatTurn(role: 'user', content: 'Explain relativity', citations: []),
          ],
        ),
        const ChatResponseSuccess(
          history: [
            ChatTurn(role: 'user', content: 'Explain relativity', citations: []),
            ChatTurn(
              role: 'assistant',
              content: 'Hello world!',
              citations: [Citation(sourceId: 'src-1', name: 'doc.pdf', pageNumber: 2)],
            )
          ],
          citations: [Citation(sourceId: 'src-1', name: 'doc.pdf', pageNumber: 2)],
          sourceTypeUsed: 'local_documents',
        ),
      ],
    );

    blocTest<ChatBloc, ChatState>(
      'emits only ChatResponseSuccess with a local guidance response when activeSourceIds is empty and web fallback is disabled',
      build: () => ChatBloc(chatRepository: mockChatRepository),
      act: (bloc) => bloc.add(const SubmitMessageEvent(
        notebookId: 'nb-1',
        message: 'Hello',
        activeSourceIds: [],
        enableWebFallback: false,
      )),
      expect: () => [
        const ChatResponseSuccess(
          history: [
            ChatTurn(role: 'user', content: 'Hello', citations: []),
            ChatTurn(
              role: 'assistant',
              content: "I am a local AI assistant designed for research purposes. "
                  "Please select or upload source files in the sidebar so I can answer questions based on them. "
                  "Alternatively, you can enable the Web Search Fallback in settings to search the open web.",
              citations: [],
            )
          ],
          citations: [],
          sourceTypeUsed: 'local_documents',
        ),
      ],
    );
  });

  group('ArtifactBloc Tests', () {
    final sampleArtifact = Artifact(
      id: 'art-1',
      notebookId: 'nb-1',
      type: 'flashcards',
      sourceHash: 'hash-val',
      payload: const {
        "cards": [
          {"front": "Q1", "back": "A1", "source_chunk_ids": [], "difficulty": "easy"}
        ]
      },
      createdAt: DateTime.now(),
    );

    blocTest<ArtifactBloc, ArtifactState>(
      'emits [ArtifactLoadInProgress, ArtifactLoadSuccess] when loading notebook artifacts succeeds',
      build: () {
        when(() => mockArtifactRepository.getNotebookArtifacts(any()))
            .thenAnswer((_) async => [sampleArtifact]);
        return ArtifactBloc(artifactRepository: mockArtifactRepository);
      },
      act: (bloc) => bloc.add(const LoadArtifactsEvent(notebookId: 'nb-1')),
      expect: () => [
        ArtifactLoadInProgress(),
        ArtifactLoadSuccess(artifacts: [sampleArtifact]),
      ],
    );

    blocTest<ArtifactBloc, ArtifactState>(
      'emits [ArtifactGenerationInProgress, ArtifactGenerationSuccess] when generation succeeds',
      build: () {
        when(() => mockArtifactRepository.generateArtifact(
              notebookId: any(named: 'notebookId'),
              artifactType: any(named: 'artifactType'),
              activeSourceIds: any(named: 'activeSourceIds'),
            )).thenAnswer((_) async => sampleArtifact);
        return ArtifactBloc(artifactRepository: mockArtifactRepository);
      },
      act: (bloc) => bloc.add(const GenerateArtifactEvent(
        notebookId: 'nb-1',
        artifactType: 'flashcards',
        activeSourceIds: ['src-1'],
      )),
      expect: () => [
        const ArtifactGenerationInProgress(artifactType: 'flashcards'),
        ArtifactGenerationSuccess(artifact: sampleArtifact, allArtifacts: [sampleArtifact]),
      ],
    );
  });
}
