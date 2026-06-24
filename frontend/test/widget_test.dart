import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:frontend/domain/repositories.dart';
import 'package:frontend/main.dart';

class MockNotebookRepository extends Mock implements INotebookRepository {}
class MockSourceRepository extends Mock implements ISourceRepository {}
class MockChatRepository extends Mock implements IChatRepository {}
class MockArtifactRepository extends Mock implements IArtifactRepository {}

void main() {
  testWidgets('Smoke test PaperMind App widget tree initialization', (WidgetTester tester) async {
    // Set simulated window size for desktop application context
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;

    // Reset view bounds after completion
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final mockNotebook = MockNotebookRepository();
    final mockSource = MockSourceRepository();
    final mockChat = MockChatRepository();
    final mockArtifact = MockArtifactRepository();

    await tester.pumpWidget(
      MyApp(
        notebookRepository: mockNotebook,
        sourceRepository: mockSource,
        chatRepository: mockChat,
        artifactRepository: mockArtifact,
        backendUrl: 'http://localhost:8000',
      ),
    );

    // Verify it boots into the theme hierarchy
    expect(find.byType(MyApp), findsOneWidget);
  });
}
