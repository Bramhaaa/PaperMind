import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:http/http.dart' as http;
import 'package:google_fonts/google_fonts.dart';

import 'domain/repositories.dart';
import 'data/repositories_impl.dart';
import 'presentation/blocs/source_bloc.dart';
import 'presentation/blocs/chat_bloc.dart';
import 'presentation/blocs/artifact_bloc.dart';
import 'presentation/blocs/provider_bloc.dart';
import 'presentation/pages/home_page.dart';

void main() {
  const String backendUrl = "http://localhost:8000";
  final httpClient = http.Client();

  final notebookRepo = NotebookRepositoryImpl(baseUrl: backendUrl, client: httpClient);
  final sourceRepo = SourceRepositoryImpl(baseUrl: backendUrl, client: httpClient);
  final chatRepo = ChatRepositoryImpl(baseUrl: backendUrl, client: httpClient);
  final artifactRepo = ArtifactRepositoryImpl(baseUrl: backendUrl, client: httpClient);

  runApp(
    MyApp(
      notebookRepository: notebookRepo,
      sourceRepository: sourceRepo,
      chatRepository: chatRepo,
      artifactRepository: artifactRepo,
      backendUrl: backendUrl,
    ),
  );
}

class MyApp extends StatelessWidget {
  final INotebookRepository notebookRepository;
  final ISourceRepository sourceRepository;
  final IChatRepository chatRepository;
  final IArtifactRepository artifactRepository;
  final String backendUrl;

  const MyApp({
    super.key,
    required this.notebookRepository,
    required this.sourceRepository,
    required this.chatRepository,
    required this.artifactRepository,
    required this.backendUrl,
  });

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<SourceBloc>(
          create: (context) => SourceBloc(sourceRepository: sourceRepository),
        ),
        BlocProvider<ChatBloc>(
          create: (context) => ChatBloc(chatRepository: chatRepository),
        ),
        BlocProvider<ArtifactBloc>(
          create: (context) => ArtifactBloc(artifactRepository: artifactRepository),
        ),
        BlocProvider<ProviderBloc>(
          create: (context) => ProviderBloc(backendBaseUrl: backendUrl),
        ),
      ],
      child: MaterialApp(
        title: 'PaperMind Workspace',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: const Color(0xFF0F172A),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF8B5CF6),
            secondary: Color(0xFFD8B4FE),
            surface: Color(0xFF1E293B),
          ),
          textTheme: GoogleFonts.outfitTextTheme(ThemeData.dark().textTheme),
        ),
        home: HomePage(
          notebookRepository: notebookRepository,
          sourceRepository: sourceRepository,
        ),
      ),
    );
  }
}
