import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_picker/file_picker.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../domain/entities.dart';
import '../../domain/repositories.dart';
import '../blocs/source_bloc.dart';
import '../blocs/chat_bloc.dart';
import '../blocs/artifact_bloc.dart';
import '../blocs/provider_bloc.dart';

class HomePage extends StatefulWidget {
  final INotebookRepository notebookRepository;

  const HomePage({super.key, required this.notebookRepository});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Notebook? _currentNotebook;
  bool _enableWebFallback = false;
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();
  int _activeLabTab = 0; // 0: Flashcards, 1: Timeline, 2: Summary

  @override
  void dispose() {
    _messageController.dispose();
    _chatScrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.animateTo(
          _chatScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showNotebookConfigDialog() {
    final nameController = TextEditingController(text: "My PaperMind Lab");
    String selectedProvider = "Ollama";
    final modelController = TextEditingController(text: "qwen2.5:0.5b");
    final baseUrlController = TextEditingController(text: "http://localhost:11434");
    final apiKeyController = TextEditingController();
    String selectedEmbedding = "all-MiniLM-L6-v2";
    double similarityThreshold = 0.70;

    showDialog(
      context: context,
      barrierDismissible: _currentNotebook != null,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return BlocListener<ProviderBloc, ProviderState>(
              listener: (context, state) {
                if (state is ProviderReady) {
                  // Connection verified, proceed to create notebook database record
                  widget.notebookRepository.createNotebook(
                    name: nameController.text.trim(),
                    llmProvider: selectedProvider.toLowerCase(),
                    modelName: modelController.text.trim(),
                    apiKey: selectedProvider == "Ollama" ? null : apiKeyController.text.trim(),
                    baseUrl: selectedProvider == "Ollama" ? baseUrlController.text.trim() : null,
                    embeddingModel: selectedEmbedding,
                    similarityThreshold: similarityThreshold,
                  ).then((notebook) {
                    setState(() {
                      _currentNotebook = notebook;
                    });
                    // Initialize BLoCs with the new notebook ID
                    context.read<SourceBloc>().add(LoadSourcesEvent(sources: const [], activeSourceIds: const []));
                    context.read<ChatBloc>().add(const LoadHistoryEvent([]));
                    context.read<ArtifactBloc>().add(LoadArtifactsEvent(notebookId: notebook.id));
                    Navigator.of(context).pop();
                  }).catchError((e) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text("Failed to save notebook configuration: $e")),
                    );
                  });
                } else if (state is ProviderError) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text("Provider Validation Failed: ${state.message}")),
                  );
                }
              },
              child: AlertDialog(
                backgroundColor: const Color(0xFF1E293B),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: const BorderSide(color: Colors.white10),
                ),
                title: Text(
                  _currentNotebook == null ? "Initialize PaperMind Workspace" : "Workspace Configuration",
                  style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold),
                ),
                content: SizedBox(
                  width: 500,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("Workspace Name", style: GoogleFonts.outfit(color: Colors.white70, fontSize: 13)),
                        const SizedBox(height: 6),
                        TextField(
                          controller: nameController,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: const Color(0xFF0F172A),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                            hintText: "Enter workspace name",
                            hintStyle: const TextStyle(color: Colors.white30),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text("LLM Provider", style: GoogleFonts.outfit(color: Colors.white70, fontSize: 13)),
                                  const SizedBox(height: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF0F172A),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: DropdownButton<String>(
                                      value: selectedProvider,
                                      dropdownColor: const Color(0xFF0F172A),
                                      isExpanded: true,
                                      underline: const SizedBox(),
                                      style: const TextStyle(color: Colors.white),
                                      items: ["Ollama", "OpenAI", "Claude", "Gemini"].map((p) {
                                        return DropdownMenuItem<String>(value: p, child: Text(p));
                                      }).toList(),
                                      onChanged: (val) {
                                        if (val != null) {
                                          setDialogState(() {
                                            selectedProvider = val;
                                            if (val == "Ollama") {
                                              modelController.text = "qwen2.5:0.5b";
                                            } else if (val == "OpenAI") {
                                              modelController.text = "gpt-4o-mini";
                                            } else if (val == "Claude") {
                                              modelController.text = "claude-3-5-sonnet-20240620";
                                            } else if (val == "Gemini") {
                                              modelController.text = "gemini-1.5-flash";
                                            }
                                          });
                                        }
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text("Model Name", style: GoogleFonts.outfit(color: Colors.white70, fontSize: 13)),
                                  const SizedBox(height: 6),
                                  TextField(
                                    controller: modelController,
                                    style: const TextStyle(color: Colors.white),
                                    decoration: InputDecoration(
                                      filled: true,
                                      fillColor: const Color(0xFF0F172A),
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        if (selectedProvider == "Ollama") ...[
                          Text("Ollama Base URL", style: GoogleFonts.outfit(color: Colors.white70, fontSize: 13)),
                          const SizedBox(height: 6),
                          TextField(
                            controller: baseUrlController,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              filled: true,
                              fillColor: const Color(0xFF0F172A),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                            ),
                          ),
                        ] else ...[
                          Text("API Key", style: GoogleFonts.outfit(color: Colors.white70, fontSize: 13)),
                          const SizedBox(height: 6),
                          TextField(
                            controller: apiKeyController,
                            obscureText: true,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              filled: true,
                              fillColor: const Color(0xFF0F172A),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                              hintText: "Enter provider API key",
                              hintStyle: const TextStyle(color: Colors.white30),
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text("Embedding Model", style: GoogleFonts.outfit(color: Colors.white70, fontSize: 13)),
                                  const SizedBox(height: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF0F172A),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: DropdownButton<String>(
                                      value: selectedEmbedding,
                                      dropdownColor: const Color(0xFF0F172A),
                                      isExpanded: true,
                                      underline: const SizedBox(),
                                      style: const TextStyle(color: Colors.white),
                                      items: ["all-MiniLM-L6-v2"].map((emb) {
                                        return DropdownMenuItem<String>(value: emb, child: Text(emb));
                                      }).toList(),
                                      onChanged: (val) {
                                        if (val != null) {
                                          setDialogState(() {
                                            selectedEmbedding = val;
                                          });
                                        }
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text("Vector Threshold", style: GoogleFonts.outfit(color: Colors.white70, fontSize: 13)),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Slider(
                                          value: similarityThreshold,
                                          min: 0.1,
                                          max: 0.9,
                                          divisions: 16,
                                          activeColor: const Color(0xFF8B5CF6),
                                          inactiveColor: Colors.white10,
                                          onChanged: (val) {
                                            setDialogState(() {
                                              similarityThreshold = val;
                                            });
                                          },
                                        ),
                                      ),
                                      Text(
                                        similarityThreshold.toStringAsFixed(2),
                                        style: const TextStyle(color: Colors.white, fontSize: 12),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  if (_currentNotebook != null)
                    TextButton(
                      child: const Text("Cancel", style: TextStyle(color: Colors.white54)),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  BlocBuilder<ProviderBloc, ProviderState>(
                    builder: (context, state) {
                      final isLoading = state is ProviderValidating;
                      return ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF8B5CF6),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        ),
                        onPressed: isLoading
                            ? null
                            : () {
                                context.read<ProviderBloc>().add(ConfigureProviderEvent(
                                      provider: selectedProvider,
                                      modelName: modelController.text.trim(),
                                      apiKey: apiKeyController.text.trim(),
                                      baseUrl: baseUrlController.text.trim(),
                                    ));
                              },
                        child: isLoading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Text("Save & Verify Connection", style: TextStyle(color: Colors.white)),
                      );
                    },
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_currentNotebook == null) {
      // Auto-trigger setup dialog on build completion if notebook is not configured
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showNotebookConfigDialog();
      });
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: SafeArea(
        child: Row(
          children: [
            // LEFT SIDEBAR: Source Explorer
            _buildLeftSidebar(context),
            const VerticalDivider(width: 1, color: Colors.white10),
            
            // CENTER: Streaming Chat room
            Expanded(
              flex: 4,
              child: _buildCenterChat(context),
            ),
            const VerticalDivider(width: 1, color: Colors.white10),
            
            // RIGHT PANEL: Study Lab
            Expanded(
              flex: 3,
              child: _buildRightStudyLab(context),
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================
  // LEFT SIDEBAR
  // ==========================================
  Widget _buildLeftSidebar(BuildContext context) {
    return Container(
      width: 280,
      color: const Color(0xFF0B0F19),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Logo & Workspace settings
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    const Icon(Icons.psychology, color: Color(0xFF8B5CF6), size: 28),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        "PaperMind",
                        style: GoogleFonts.outfit(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.settings, color: Colors.white54, size: 20),
                onPressed: _showNotebookConfigDialog,
              )
            ],
          ),
          const SizedBox(height: 24),
          
          // Current Notebook Settings Display
          if (_currentNotebook != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _currentNotebook!.name,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.dns, size: 12, color: Color(0xFF8B5CF6)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          "${_currentNotebook!.llmProvider.toUpperCase()} • ${_currentNotebook!.modelName}",
                          style: const TextStyle(color: Colors.white54, fontSize: 11),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ] else ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.redAccent.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
              ),
              child: const Text(
                "No active workspace. Please click setting wheel to configure a provider.",
                style: TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ),
          ],
          const SizedBox(height: 20),
          
          // Document section header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "SOURCES",
                style: GoogleFonts.outfit(
                  color: Colors.white38,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              BlocBuilder<SourceBloc, SourceState>(
                builder: (context, state) {
                  if (state is SourceSelectionUpdated) {
                    return Text(
                      "${state.activeSourceIds.length}/${state.allSources.length} active",
                      style: const TextStyle(color: Colors.white38, fontSize: 11),
                    );
                  }
                  if (state is SourceUploadSuccess) {
                    return Text(
                      "${state.activeSourceIds.length}/${state.allSources.length} active",
                      style: const TextStyle(color: Colors.white38, fontSize: 11),
                    );
                  }
                  return const SizedBox();
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          
          // File Picker / Upload button
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1E293B),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: const BorderSide(color: Colors.white10),
              ),
              minimumSize: const Size(double.infinity, 40),
            ),
            icon: const Icon(Icons.add, size: 16),
            label: const Text("Add Source Documents", style: TextStyle(fontSize: 13)),
            onPressed: _currentNotebook == null
                ? null
                : () async {
                    final result = await FilePicker.platform.pickFiles(
                      type: FileType.custom,
                      allowedExtensions: ['pdf', 'txt', 'md', 'mp3', 'wav'],
                      withData: true,
                    );
                    if (result != null && result.files.isNotEmpty) {
                      final file = result.files.first;
                      if (file.bytes != null) {
                        context.read<SourceBloc>().add(
                              UploadDocumentEvent(
                                notebookId: _currentNotebook!.id,
                                fileName: file.name,
                                fileBytes: file.bytes!,
                              ),
                            );
                      }
                    }
                  },
          ),
          const SizedBox(height: 12),
          
          // Uploading progress indicator
          BlocBuilder<SourceBloc, SourceState>(
            builder: (context, state) {
              if (state is SourceUploadInProgress) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const LinearProgressIndicator(
                        backgroundColor: Colors.white10,
                        valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF8B5CF6)),
                      ),
                      const SizedBox(height: 4),
                      Text("Uploading & digesting file...", style: GoogleFonts.outfit(color: Colors.white54, fontSize: 11)),
                    ],
                  ),
                );
              }
              if (state is SourceError) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12.0),
                  child: Text(
                    "Upload failed: ${state.message}",
                    style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                  ),
                );
              }
              return const SizedBox();
            },
          ),
          
          // Source Documents List
          Expanded(
            child: BlocBuilder<SourceBloc, SourceState>(
              builder: (context, state) {
                List<Source> sources = [];
                List<String> activeIds = [];
                
                if (state is SourceSelectionUpdated) {
                  sources = state.allSources;
                  activeIds = state.activeSourceIds;
                } else if (state is SourceUploadSuccess) {
                  sources = state.allSources;
                  activeIds = state.activeSourceIds;
                }
                
                if (sources.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.cloud_queue, size: 36, color: Colors.white24),
                        const SizedBox(height: 8),
                        Text(
                          "No sources added",
                          style: GoogleFonts.outfit(color: Colors.white38, fontSize: 13),
                        ),
                      ],
                    ),
                  );
                }
                
                return ListView.builder(
                  itemCount: sources.length,
                  itemBuilder: (context, index) {
                    final source = sources[index];
                    final isActive = activeIds.contains(source.id);
                    
                    return Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      decoration: BoxDecoration(
                        color: isActive ? const Color(0xFF1E293B) : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: ListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                        leading: Icon(
                          _getFileIcon(source.fileType),
                          color: isActive ? const Color(0xFF8B5CF6) : Colors.white30,
                          size: 18,
                        ),
                        title: Text(
                          source.name,
                          style: TextStyle(
                            color: isActive ? Colors.white : Colors.white54,
                            fontSize: 12,
                            fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          _formatSize(source.sizeBytes),
                          style: const TextStyle(color: Colors.white38, fontSize: 10),
                        ),
                        trailing: Checkbox(
                          value: isActive,
                          activeColor: const Color(0xFF8B5CF6),
                          checkColor: Colors.white,
                          side: const BorderSide(color: Colors.white24),
                          onChanged: (_) {
                            context.read<SourceBloc>().add(ToggleSourceEvent(sourceId: source.id));
                          },
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  IconData _getFileIcon(String ext) {
    switch (ext.toLowerCase()) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'mp3':
      case 'wav':
        return Icons.audiotrack;
      case 'md':
      case 'txt':
        return Icons.description;
      default:
        return Icons.insert_drive_file;
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return "$bytes B";
    if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
    return "${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB";
  }

  // ==========================================
  // CENTER CHAT PANEL
  // ==========================================
  Widget _buildCenterChat(BuildContext context) {
    return Container(
      color: const Color(0xFF0F172A),
      child: Column(
        children: [
          // Banner for web fallback warning
          BlocBuilder<ChatBloc, ChatState>(
            builder: (context, state) {
              if (state is WebFallbackBannerVisible) {
                return Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.15),
                    border: const Border(bottom: BorderSide(color: Colors.amber, width: 0.5)),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      const Icon(Icons.wifi, color: Colors.amber, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          "Local retrieval returned no hits. Answer generated via external Web Search search integration (Tavily/Serper).",
                          style: GoogleFonts.outfit(color: Colors.amber, fontSize: 12, fontWeight: FontWeight.w500),
                        ),
                      ),
                    ],
                  ),
                );
              }
              return const SizedBox();
            },
          ),
          
          // Active streaming status or empty state welcome
          Expanded(
            child: BlocConsumer<ChatBloc, ChatState>(
              listener: (context, state) {
                _scrollToBottom();
                if (state is ChatError) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text("Query error: ${state.message}"),
                      backgroundColor: Colors.redAccent,
                    ),
                  );
                }
              },
              builder: (context, state) {
                List<ChatTurn> turns = [];
                String? currentTokenStream;
                bool isQueryLoading = false;
                
                if (state is ChatResponseSuccess) {
                  turns = state.history;
                } else if (state is ChatResponseStreaming) {
                  turns = state.history;
                  currentTokenStream = state.currentResponse;
                } else if (state is ChatResponseLoading) {
                  turns = state.history;
                  isQueryLoading = true;
                } else if (state is WebFallbackBannerVisible) {
                  turns = state.history;
                } else if (state is ChatError) {
                  turns = state.history;
                }
                
                if (turns.isEmpty && currentTokenStream == null && !isQueryLoading) {
                  return _buildEmptyChatWelcome();
                }
                
                return ListView.builder(
                  controller: _chatScrollController,
                  padding: const EdgeInsets.all(24),
                  itemCount: turns.length + (currentTokenStream != null ? 1 : 0) + (isQueryLoading ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (isQueryLoading && index == 0) {
                      return _buildQueryLoaderBubble();
                    }
                    
                    if (index == turns.length && currentTokenStream != null) {
                      // Rendering current streaming token stream bubble
                      return _buildChatBubble(
                        role: "assistant",
                        content: currentTokenStream,
                        citations: const [],
                        isStreaming: true,
                      );
                    }
                    
                    final turn = turns[index];
                    return _buildChatBubble(
                      role: turn.role,
                      content: turn.content,
                      citations: turn.citations,
                    );
                  },
                );
              },
            ),
          ),
          
          const Divider(height: 1, color: Colors.white10),
          _buildChatInputField(context),
        ],
      ),
    );
  }

  Widget _buildEmptyChatWelcome() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                color: Color(0xFF1E293B),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.question_answer, size: 48, color: Color(0xFF8B5CF6)),
            ),
            const SizedBox(height: 16),
            Text(
              "Local Document Chat",
              style: GoogleFonts.outfit(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: 360,
              child: Text(
                "Select source files in the sidebar and ask questions. PaperMind will chunk, index, search, and generate answers strictly from your papers.",
                textAlign: TextAlign.center,
                style: GoogleFonts.outfit(color: Colors.white38, fontSize: 13, height: 1.4),
              ),
            ),
            const SizedBox(height: 24),
            _buildSamplePromptGrid(),
          ],
        ),
      ),
    );
  }

  Widget _buildSamplePromptGrid() {
    final prompts = [
      "Summarize the main methodology used in these files.",
      "List the key experiments and their results.",
      "What are the research limitations identified?",
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: prompts.map((prompt) {
        return InkWell(
          onTap: () {
            _messageController.text = prompt;
          },
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              border: Border.all(color: Colors.white10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              prompt,
              style: const TextStyle(color: Color(0xFFD8B4FE), fontSize: 12),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildQueryLoaderBubble() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF8B5CF6)),
            ),
            const SizedBox(width: 10),
            Text(
              "Retrieving chunks & generating response...",
              style: GoogleFonts.outfit(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatBubble({
    required String role,
    required String content,
    required List<Citation> citations,
    bool isStreaming = false,
  }) {
    final isUser = role == "user";
    
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        constraints: const BoxConstraints(maxWidth: 640),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isUser ? const Color(0xFF7C3AED) : const Color(0xFF1E293B),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(12),
            topRight: const Radius.circular(12),
            bottomLeft: Radius.circular(isUser ? 12 : 0),
            bottomRight: Radius.circular(isUser ? 0 : 12),
          ),
          border: isUser ? null : Border.all(color: Colors.white10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Speaker identifier badge
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isUser ? Icons.account_circle : Icons.offline_bolt,
                  color: isUser ? Colors.white70 : const Color(0xFFD8B4FE),
                  size: 14,
                ),
                const SizedBox(width: 6),
                Text(
                  isUser ? "You" : "PaperMind Assistant",
                  style: GoogleFonts.outfit(
                    color: isUser ? Colors.white70 : const Color(0xFFD8B4FE),
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            
            // Text Content (Markdown for Assistant, plain for User)
            if (isUser)
              Text(
                content,
                style: const TextStyle(color: Colors.white, fontSize: 13.5, height: 1.4),
              )
            else
              MarkdownBody(
                data: content,
                styleSheet: MarkdownStyleSheet(
                  p: const TextStyle(color: Colors.white, fontSize: 13.5, height: 1.4),
                  strong: const TextStyle(color: Color(0xFFD8B4FE), fontWeight: FontWeight.bold),
                  code: GoogleFonts.firaCode(backgroundColor: Colors.white12, color: Colors.amberAccent, fontSize: 11),
                  codeblockDecoration: BoxDecoration(
                    color: const Color(0xFF0F172A),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
              
            // Citations chip footer (Assistant only)
            if (!isUser && citations.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Divider(color: Colors.white10, height: 1),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: citations.map((cit) {
                  return ActionChip(
                    backgroundColor: const Color(0xFF0F172A),
                    side: const BorderSide(color: Colors.white10),
                    labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                    avatar: const Icon(Icons.bookmark, color: Color(0xFF8B5CF6), size: 10),
                    label: Text(
                      "${cit.name}${cit.pageNumber != null ? ' (Pg ${cit.pageNumber})' : ''}${cit.audioTimestampSeconds != null ? ' (${cit.audioTimestampSeconds!.toStringAsFixed(0)}s)' : ''}",
                      style: const TextStyle(color: Colors.white70, fontSize: 9.5),
                    ),
                    onPressed: () {
                      _showCitationDetails(context, cit);
                    },
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showCitationDetails(BuildContext context, Citation cit) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E293B),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Colors.white10)),
          title: Row(
            children: [
              const Icon(Icons.menu_book, color: Color(0xFF8B5CF6), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "Citation Source",
                  style: GoogleFonts.outfit(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Document Name:", style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 2),
              Text(cit.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
              const SizedBox(height: 12),
              if (cit.pageNumber != null) ...[
                Text("Page Location:", style: TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 2),
                Text("Page ${cit.pageNumber}", style: const TextStyle(color: Colors.amberAccent, fontSize: 13, fontWeight: FontWeight.w600)),
              ],
              if (cit.audioTimestampSeconds != null) ...[
                Text("Audio Timestamp:", style: TextStyle(color: Colors.white54, fontSize: 12)),
                const SizedBox(height: 2),
                Text("${cit.audioTimestampSeconds!.toStringAsFixed(1)} seconds", style: const TextStyle(color: Colors.amberAccent, fontSize: 13, fontWeight: FontWeight.w600)),
              ],
            ],
          ),
          actions: [
            TextButton(
              child: const Text("Close", style: TextStyle(color: Colors.white70)),
              onPressed: () => Navigator.of(context).pop(),
            )
          ],
        );
      },
    );
  }

  Widget _buildChatInputField(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: const Color(0xFF0B0F19),
      child: Column(
        children: [
          Row(
            children: [
              // Toggle for web search fallback
              Switch(
                value: _enableWebFallback,
                activeColor: const Color(0xFF8B5CF6),
                onChanged: (val) {
                  setState(() {
                    _enableWebFallback = val;
                  });
                },
              ),
              Text(
                "Web Search Fallback",
                style: GoogleFonts.outfit(color: _enableWebFallback ? Colors.white70 : Colors.white30, fontSize: 12),
              ),
              const Spacer(),
              BlocBuilder<SourceBloc, SourceState>(
                builder: (context, state) {
                  List<String> activeIds = [];
                  if (state is SourceSelectionUpdated) {
                    activeIds = state.activeSourceIds;
                  } else if (state is SourceUploadSuccess) {
                    activeIds = state.activeSourceIds;
                  }
                  if (activeIds.isEmpty) {
                    return const Flexible(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.warning, color: Colors.orangeAccent, size: 12),
                          SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              "No active files - using base LLM",
                              style: TextStyle(color: Colors.orangeAccent, fontSize: 10),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return const SizedBox();
                },
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _messageController,
                  style: const TextStyle(color: Colors.white, fontSize: 13.5),
                  decoration: InputDecoration(
                    hintText: "Ask a question about the active papers...",
                    hintStyle: const TextStyle(color: Colors.white24),
                    filled: true,
                    fillColor: const Color(0xFF1E293B),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                  onSubmitted: (val) {
                    if (val.trim().isNotEmpty && _currentNotebook != null) {
                      _sendMessage(context);
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              BlocBuilder<ChatBloc, ChatState>(
                builder: (context, state) {
                  final isGenerating = state is ChatResponseLoading || state is ChatResponseStreaming;
                  return IconButton(
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0xFF8B5CF6),
                      disabledBackgroundColor: Colors.white10,
                      padding: const EdgeInsets.all(10),
                    ),
                    icon: Icon(
                      isGenerating ? Icons.hourglass_bottom : Icons.send,
                      color: isGenerating ? Colors.white30 : Colors.white,
                      size: 18,
                    ),
                    onPressed: isGenerating || _currentNotebook == null
                        ? null
                        : () {
                            if (_messageController.text.trim().isNotEmpty) {
                              _sendMessage(context);
                            }
                          },
                  );
                },
              )
            ],
          ),
        ],
      ),
    );
  }

  void _sendMessage(BuildContext context) {
    final queryText = _messageController.text.trim();
    _messageController.clear();
    
    // Obtain active source IDs from SourceBloc state
    final sourceState = context.read<SourceBloc>().state;
    List<String> activeSourceIds = [];
    if (sourceState is SourceSelectionUpdated) {
      activeSourceIds = sourceState.activeSourceIds;
    } else if (sourceState is SourceUploadSuccess) {
      activeSourceIds = sourceState.activeSourceIds;
    }
    
    context.read<ChatBloc>().add(
          SubmitMessageEvent(
            notebookId: _currentNotebook!.id,
            message: queryText,
            activeSourceIds: activeSourceIds,
            enableWebFallback: _enableWebFallback,
          ),
        );
  }

  // ==========================================
  // RIGHT STUDY LAB PANEL
  // ==========================================
  Widget _buildRightStudyLab(BuildContext context) {
    return Container(
      color: const Color(0xFF0B0F19),
      child: Column(
        children: [
          // Segmented Navigation Header
          Container(
            padding: const EdgeInsets.all(8),
            decoration: const BoxDecoration(
              color: Color(0xFF0F172A),
              border: Border(bottom: BorderSide(color: Colors.white10)),
            ),
            child: Row(
              children: [
                _buildTabButton(0, "Flashcards", Icons.analytics),
                _buildTabButton(1, "Timeline", Icons.timeline),
                _buildTabButton(2, "Summary", Icons.assignment),
              ],
            ),
          ),
          
          // Lab Content Router
          Expanded(
            child: BlocBuilder<ArtifactBloc, ArtifactState>(
              builder: (context, state) {
                if (state is ArtifactGenerationInProgress) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF8B5CF6))),
                        const SizedBox(height: 12),
                        Text(
                          "Generating structured artifact payload...",
                          style: GoogleFonts.outfit(color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    ),
                  );
                }
                
                // Get all cached artifacts from the bloc state
                List<Artifact> allArtifacts = [];
                if (state is ArtifactLoadSuccess) {
                  allArtifacts = state.artifacts;
                } else if (state is ArtifactGenerationSuccess) {
                  allArtifacts = state.allArtifacts;
                }
                
                // Filter down to the matching tab type
                final targetType = _getArtifactTypeStr(_activeLabTab);
                final list = allArtifacts.where((a) => a.type == targetType).toList();
                
                // If we don't have this artifact generated yet
                if (list.isEmpty) {
                  return _buildArtifactEmptyView(context, targetType);
                }
                
                // Render the active tab layout
                final activeArtifact = list.first; // Pick latest computed artifact cache
                return _buildArtifactView(context, activeArtifact);
              },
            ),
          ),
        ],
      ),
    );
  }

  String _getArtifactTypeStr(int index) {
    switch (index) {
      case 0:
        return "flashcards";
      case 1:
        return "timeline";
      default:
        return "summary";
    }
  }

  Widget _buildTabButton(int index, String label, IconData icon) {
    final isActive = _activeLabTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() {
            _activeLabTab = index;
          });
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isActive ? const Color(0xFF1E293B) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: isActive ? Border.all(color: Colors.white10) : null,
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: isActive ? const Color(0xFF8B5CF6) : Colors.white30, size: 14),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: GoogleFonts.outfit(
                    color: isActive ? Colors.white : Colors.white30,
                    fontSize: 12,
                    fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildArtifactEmptyView(BuildContext context, String type) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              type == "flashcards"
                  ? Icons.quiz
                  : type == "timeline"
                      ? Icons.history
                      : Icons.summarize,
              size: 44,
              color: Colors.white24,
            ),
            const SizedBox(height: 12),
            Text(
              "No ${type.substring(0, 1).toUpperCase()}${type.substring(1)} Generated",
              style: GoogleFonts.outfit(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              "Trigger AI structured generation using active documents in this notebook to study facts.",
              textAlign: TextAlign.center,
              style: GoogleFonts.outfit(color: Colors.white38, fontSize: 11, height: 1.4),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF8B5CF6),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: _currentNotebook == null
                  ? null
                  : () {
                      _triggerArtifactGeneration(context, type);
                    },
              child: Text("Generate $type", style: const TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }

  void _triggerArtifactGeneration(BuildContext context, String type) {
    final sourceState = context.read<SourceBloc>().state;
    List<String> activeSourceIds = [];
    if (sourceState is SourceSelectionUpdated) {
      activeSourceIds = sourceState.activeSourceIds;
    } else if (sourceState is SourceUploadSuccess) {
      activeSourceIds = sourceState.activeSourceIds;
    }
    
    if (activeSourceIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Cannot generate: Select at least one active document source in the sidebar.")),
      );
      return;
    }
    
    context.read<ArtifactBloc>().add(
          GenerateArtifactEvent(
            notebookId: _currentNotebook!.id,
            artifactType: type,
            activeSourceIds: activeSourceIds,
          ),
        );
  }

  Widget _buildArtifactView(BuildContext context, Artifact artifact) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Regenerate toolbar button
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "COMPUTED STUDY TOOL",
                style: GoogleFonts.outfit(color: Colors.white24, fontSize: 10, letterSpacing: 1.2),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, color: Colors.white54, size: 16),
                tooltip: "Re-generate with current active sources",
                onPressed: () {
                  _triggerArtifactGeneration(context, artifact.type);
                },
              ),
            ],
          ),
        ),
        
        Expanded(
          child: _renderArtifactPayload(artifact),
        ),
      ],
    );
  }

  Widget _renderArtifactPayload(Artifact artifact) {
    final payload = artifact.payload;
    if (artifact.type == "flashcards") {
      final list = payload["cards"] as List?;
      if (list == null || list.isEmpty) {
        return const Center(child: Text("No card records in payload.", style: TextStyle(color: Colors.white)));
      }
      return _FlashcardDeckView(cards: list);
    } else if (artifact.type == "timeline") {
      final list = payload["timeline"] as List?;
      if (list == null || list.isEmpty) {
        return const Center(child: Text("No timeline records in payload.", style: TextStyle(color: Colors.white)));
      }
      return _TimelineListView(timelineItems: list);
    } else if (artifact.type == "summary") {
      final summary = payload["summary"] as Map<String, dynamic>?;
      if (summary == null) {
        return const Center(child: Text("No summary details in payload.", style: TextStyle(color: Colors.white)));
      }
      return _SummaryDetailsView(summary: summary);
    }
    return const Center(child: Text("Unsupported payload format."));
  }
}

// ==========================================
// 3D FLIP FLASHCARD SUB-VIEW
// ==========================================
class _FlashcardDeckView extends StatefulWidget {
  final List<dynamic> cards;
  const _FlashcardDeckView({required this.cards});

  @override
  State<_FlashcardDeckView> createState() => _FlashcardDeckViewState();
}

class _FlashcardDeckViewState extends State<_FlashcardDeckView> with SingleTickerProviderStateMixin {
  int _cardIndex = 0;
  bool _showFront = true;
  late AnimationController _flipController;

  @override
  void initState() {
    super.initState();
    _flipController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
  }

  @override
  void dispose() {
    _flipController.dispose();
    super.dispose();
  }

  void _flipCard() {
    if (_showFront) {
      _flipController.forward();
    } else {
      _flipController.reverse();
    }
    setState(() {
      _showFront = !_showFront;
    });
  }

  void _nextCard() {
    if (_cardIndex < widget.cards.length - 1) {
      setState(() {
        _cardIndex++;
        _showFront = true;
      });
      _flipController.reset();
    }
  }

  void _prevCard() {
    if (_cardIndex > 0) {
      setState(() {
        _cardIndex--;
        _showFront = true;
      });
      _flipController.reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.cards[_cardIndex] as Map<String, dynamic>;
    final frontText = card["front"] as String? ?? "Empty Front";
    final backText = card["back"] as String? ?? "Empty Back";
    final difficulty = card["difficulty"] as String? ?? "medium";
    final sourceChunkIds = card["source_chunk_ids"] as List? ?? [];
    
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          // Counter indicator
          Text(
            "Card ${_cardIndex + 1} of ${widget.cards.length}",
            style: GoogleFonts.outfit(color: Colors.white38, fontSize: 11),
          ),
          const SizedBox(height: 16),
          
          // Flashcard layout with Perspective Y Rotation
          Expanded(
            child: GestureDetector(
              onTap: _flipCard,
              child: AnimatedBuilder(
                animation: _flipController,
                builder: (context, child) {
                  final angle = _flipController.value * pi;
                  final isBackSide = angle > pi / 2;
                  
                  return Transform(
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, 0.001) // perspective depth coefficient
                      ..rotateY(angle),
                    alignment: Alignment.center,
                    child: isBackSide
                        ? Transform(
                            // Un-rotate the card back text so it is not backwards
                            transform: Matrix4.identity()..rotateY(pi),
                            alignment: Alignment.center,
                            child: _buildCardDetails(
                              title: "ANSWER",
                              color: const Color(0xFF1E293B),
                              borderColor: Colors.purple.withOpacity(0.3),
                              content: backText,
                              difficulty: difficulty,
                              chunkIds: sourceChunkIds,
                            ),
                          )
                        : _buildCardDetails(
                            title: "QUESTION",
                            color: const Color(0xFF131A26),
                            borderColor: Colors.white10,
                            content: frontText,
                            difficulty: difficulty,
                            chunkIds: sourceChunkIds,
                          ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 16),
          
          // Deck Controls
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: _cardIndex > 0 ? _prevCard : null,
              ),
              const SizedBox(width: 32),
              Text(
                "TAP CARD TO FLIP",
                style: GoogleFonts.outfit(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 32),
              IconButton(
                icon: const Icon(Icons.arrow_forward, color: Colors.white),
                onPressed: _cardIndex < widget.cards.length - 1 ? _nextCard : null,
              ),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildCardDetails({
    required String title,
    required Color color,
    required Color borderColor,
    required String content,
    required String difficulty,
    required List<dynamic> chunkIds,
  }) {
    Color difficultyColor = Colors.greenAccent;
    if (difficulty == "hard") {
      difficultyColor = Colors.redAccent;
    } else if (difficulty == "medium") {
      difficultyColor = Colors.orangeAccent;
    }
    
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: 1.5),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: GoogleFonts.outfit(color: const Color(0xFF8B5CF6), fontWeight: FontWeight.bold, fontSize: 11),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: difficultyColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: difficultyColor.withOpacity(0.3)),
                ),
                child: Text(
                  difficulty.toUpperCase(),
                  style: TextStyle(color: difficultyColor, fontSize: 8.5, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const Spacer(),
          Center(
            child: SingleChildScrollView(
              child: Text(
                content,
                textAlign: TextAlign.center,
                style: GoogleFonts.outfit(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  height: 1.4,
                ),
              ),
            ),
          ),
          const Spacer(),
          if (chunkIds.isNotEmpty) ...[
            Text(
              "Sources chunk coverages:",
              style: GoogleFonts.outfit(color: Colors.white38, fontSize: 9),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: chunkIds.take(5).map((id) {
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    id.toString().substring(0, min(8, id.toString().length)),
                    style: const TextStyle(color: Colors.white70, fontSize: 8),
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }
}

// ==========================================
// VERTICAL TIMELINE LIST SUB-VIEW
// ==========================================
class _TimelineListView extends StatelessWidget {
  final List<dynamic> timelineItems;
  const _TimelineListView({required this.timelineItems});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: timelineItems.length,
      itemBuilder: (context, index) {
        final item = timelineItems[index] as Map<String, dynamic>;
        final date = item["date_or_period"] as String? ?? "Unknown Date";
        final desc = item["event_description"] as String? ?? "";
        final sourceChunkIds = item["source_chunk_ids"] as List? ?? [];
        
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Left graphic nodes
              Column(
                children: [
                  Container(
                    width: 12,
                    height: 12,
                    decoration: const BoxDecoration(
                      color: Color(0xFF8B5CF6),
                      shape: BoxShape.circle,
                    ),
                  ),
                  Expanded(
                    child: Container(
                      width: 2,
                      color: index == timelineItems.length - 1 ? Colors.transparent : Colors.white10,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 16),
              
              // Right contents
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 24.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        date,
                        style: GoogleFonts.outfit(
                          color: const Color(0xFF8B5CF6),
                          fontWeight: FontWeight.bold,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        desc,
                        style: const TextStyle(color: Colors.white70, fontSize: 12.5, height: 1.4),
                      ),
                      if (sourceChunkIds.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 4,
                          children: sourceChunkIds.take(4).map((id) {
                            return Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.white10,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                id.toString().substring(0, min(8, id.toString().length)),
                                style: const TextStyle(color: Colors.white38, fontSize: 8),
                              ),
                            );
                          }).toList(),
                        )
                      ]
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ==========================================
// EXECUTIVE SUMMARY DETAILED SUB-VIEW
// ==========================================
class _SummaryDetailsView extends StatelessWidget {
  final Map<String, dynamic> summary;
  const _SummaryDetailsView({required this.summary});

  @override
  Widget build(BuildContext context) {
    final tldr = summary["tldr"] as String? ?? "No TLDR text.";
    final findings = summary["key_findings"] as List? ?? [];
    final questions = summary["open_questions"] as List? ?? [];
    
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // TLDR Section
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "EXECUTIVE BRIEF / TL;DR",
                style: GoogleFonts.outfit(color: const Color(0xFF8B5CF6), fontWeight: FontWeight.bold, fontSize: 10, letterSpacing: 1.2),
              ),
              const SizedBox(height: 8),
              Text(
                tldr,
                style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.4, fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        
        // Key Findings
        if (findings.isNotEmpty) ...[
          Row(
            children: [
              const Icon(Icons.vpn_key, color: Color(0xFF8B5CF6), size: 16),
              const SizedBox(width: 8),
              Text(
                "Key Insights & Findings",
                style: GoogleFonts.outfit(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Column(
            children: findings.map((f) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4.0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("• ", style: TextStyle(color: Color(0xFF8B5CF6), fontSize: 14)),
                    Expanded(
                      child: Text(
                        f.toString(),
                        style: const TextStyle(color: Colors.white70, fontSize: 12.5, height: 1.4),
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 24),
        ],
        
        // Open Questions
        if (questions.isNotEmpty) ...[
          Row(
            children: [
              const Icon(Icons.help_outline, color: Colors.amberAccent, size: 16),
              const SizedBox(width: 8),
              Text(
                "Unresolved / Open Questions",
                style: GoogleFonts.outfit(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Column(
            children: questions.map((q) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4.0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("? ", style: TextStyle(color: Colors.amberAccent, fontSize: 14)),
                    Expanded(
                      child: Text(
                        q.toString(),
                        style: const TextStyle(color: Colors.white70, fontSize: 12.5, height: 1.4),
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ],
    );
  }
}
