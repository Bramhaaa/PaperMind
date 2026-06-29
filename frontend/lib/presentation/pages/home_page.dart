import 'dart:math';
import 'dart:convert';
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
  final ISourceRepository sourceRepository;

  const HomePage({
    super.key,
    required this.notebookRepository,
    required this.sourceRepository,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Notebook? _currentNotebook;
  bool _enableWebFallback = false;
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();
  int _activeLabTab = 0; // 0: Flashcards, 1: Timeline, 2: Summary

  Source? _selectedSourcePreview;
  List<DocumentChunk>? _previewChunks;
  bool _isLoadingPreview = false;
  String? _highlightChunkId;
  bool _isRightPanelOpen = false;

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
    final bool isEditing = _currentNotebook != null;
    final nameController = TextEditingController(
      text: isEditing ? _currentNotebook!.name : "My PaperMind Lab",
    );
    String selectedProvider = "Ollama";
    if (isEditing) {
      final prov = _currentNotebook!.llmProvider.toLowerCase();
      if (prov == "openai") {
        selectedProvider = "OpenAI";
      } else if (prov == "claude") {
        selectedProvider = "Claude";
      } else if (prov == "gemini") {
        selectedProvider = "Gemini";
      } else {
        selectedProvider = "Ollama";
      }
    }
    final modelController = TextEditingController(
      text: isEditing ? _currentNotebook!.modelName : "qwen2.5:0.5b",
    );
    final baseUrlController = TextEditingController(
      text: isEditing ? (_currentNotebook!.baseUrl ?? "") : "http://localhost:11434",
    );
    final apiKeyController = TextEditingController(
      text: isEditing ? (_currentNotebook!.apiKey ?? "") : "",
    );
    String selectedEmbedding = isEditing ? _currentNotebook!.embeddingModel : "all-MiniLM-L6-v2";
    double similarityThreshold = isEditing ? _currentNotebook!.similarityThreshold : 0.70;

    showDialog(
      context: context,
      barrierDismissible: isEditing,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return BlocListener<ProviderBloc, ProviderState>(
              listener: (context, state) {
                if (state is ProviderReady) {
                  final saveFuture = isEditing
                      ? widget.notebookRepository.updateNotebook(
                          id: _currentNotebook!.id,
                          name: nameController.text.trim(),
                          llmProvider: selectedProvider.toLowerCase(),
                          modelName: modelController.text.trim(),
                          apiKey: selectedProvider == "Ollama" ? null : apiKeyController.text.trim(),
                          baseUrl: selectedProvider == "Ollama" ? baseUrlController.text.trim() : null,
                          similarityThreshold: similarityThreshold,
                        )
                      : widget.notebookRepository.createNotebook(
                          name: nameController.text.trim(),
                          llmProvider: selectedProvider.toLowerCase(),
                          modelName: modelController.text.trim(),
                          apiKey: selectedProvider == "Ollama" ? null : apiKeyController.text.trim(),
                          baseUrl: selectedProvider == "Ollama" ? baseUrlController.text.trim() : null,
                          embeddingModel: selectedEmbedding,
                          similarityThreshold: similarityThreshold,
                        );

                  saveFuture.then((notebook) {
                    setState(() {
                      _currentNotebook = notebook;
                    });
                    if (!isEditing) {
                      context.read<SourceBloc>().add(LoadSourcesEvent(sources: const [], activeSourceIds: const []));
                      context.read<ChatBloc>().add(const LoadHistoryEvent([]));
                      context.read<ArtifactBloc>().add(LoadArtifactsEvent(notebookId: notebook.id));
                    }
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
                  !isEditing ? "Initialize PaperMind Workspace" : "Workspace Configuration",
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
                                              if (baseUrlController.text.trim().isEmpty) {
                                                baseUrlController.text = "http://localhost:11434";
                                              }
                                            } else if (val == "OpenAI") {
                                              modelController.text = "gpt-4o-mini";
                                            } else if (val == "Claude") {
                                              modelController.text = "claude-3-5-sonnet-20240620";
                                            } else if (val == "Gemini") {
                                              modelController.text = "gemini-2.5-flash";
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
                                      onChanged: isEditing
                                          ? null
                                          : (val) {
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
                  if (isEditing)
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
              flex: _isRightPanelOpen ? 3 : 5,
              child: _buildCenterChat(context),
            ),
            
            // RIGHT PANEL: Study Lab (Canvas)
            if (_isRightPanelOpen) ...[
              const VerticalDivider(width: 1, color: Colors.white10),
              Expanded(
                flex: 2,
                child: _buildRightStudyLab(context),
              ),
            ],
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
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _showNotebookConfigDialog,
                borderRadius: BorderRadius.circular(10),
                hoverColor: Colors.white.withOpacity(0.05),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B).withOpacity(0.6),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Row(
                    children: [
                      Expanded(
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
                      const SizedBox(width: 8),
                      const Icon(Icons.edit, color: Colors.white30, size: 14),
                    ],
                  ),
                ),
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
                      allowedExtensions: [
                        'pdf', 'PDF',
                        'txt', 'TXT',
                        'md', 'MD',
                        'mp3', 'MP3',
                        'm4a', 'M4A'
                      ],
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
                        onTap: () {
                          _openSourcePreview(source);
                        },
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
          // Top Header Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
              color: Color(0xFF0F172A),
              border: Border(bottom: BorderSide(color: Colors.white10)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _currentNotebook != null 
                      ? "Chat: ${_currentNotebook!.name}" 
                      : "PaperMind Chat",
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Row(
                  children: [
                    Text(
                      _enableWebFallback ? "Web Search Active" : "Local Sources Only",
                      style: GoogleFonts.outfit(
                        color: _enableWebFallback ? Colors.amber : Colors.white38,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      icon: Icon(
                        _isRightPanelOpen 
                            ? Icons.fullscreen_exit 
                            : Icons.chrome_reader_mode,
                        color: _isRightPanelOpen 
                            ? const Color(0xFF8B5CF6) 
                            : Colors.white54,
                        size: 20,
                      ),
                      tooltip: _isRightPanelOpen ? "Close Study Canvas" : "Open Study Canvas",
                      onPressed: () {
                        setState(() {
                          _isRightPanelOpen = !_isRightPanelOpen;
                        });
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          
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
                    if (index == turns.length) {
                      if (currentTokenStream != null) {
                        // Rendering current streaming token stream bubble
                        return _buildChatBubble(
                          role: "assistant",
                          content: currentTokenStream,
                          citations: const [],
                          isStreaming: true,
                        );
                      }
                      if (isQueryLoading) {
                        return _buildQueryLoaderBubble();
                      }
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
                      _openCitation(cit);
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

  void _openSourcePreview(Source source) async {
    setState(() {
      _selectedSourcePreview = source;
      _isLoadingPreview = true;
      _previewChunks = null;
      _highlightChunkId = null;
      _isRightPanelOpen = true;
    });
    try {
      final chunks = await widget.sourceRepository.getSourceChunks(source.id);
      setState(() {
        _previewChunks = chunks;
        _isLoadingPreview = false;
      });
    } catch (e) {
      setState(() {
        _isLoadingPreview = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed to load document content: $e")),
      );
    }
  }

  void _openCitation(Citation cit) async {
    final sourceState = context.read<SourceBloc>().state;
    List<Source> allSources = [];
    if (sourceState is SourceSelectionUpdated) {
      allSources = sourceState.allSources;
    } else if (sourceState is SourceUploadSuccess) {
      allSources = sourceState.allSources;
    }
    
    Source? source;
    try {
      source = allSources.firstWhere((s) => s.id == cit.sourceId);
    } catch (_) {
      source = null;
    }
    
    if (source == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Citation source document not found in workspace.")),
      );
      return;
    }

    setState(() {
      _selectedSourcePreview = source;
      _isLoadingPreview = true;
      _previewChunks = null;
      _highlightChunkId = null;
      _isRightPanelOpen = true;
    });

    try {
      final chunks = await widget.sourceRepository.getSourceChunks(source.id);
      String? targetChunkId;
      
      if (cit.pageNumber != null) {
        final idx = chunks.indexWhere((c) => c.pageNumber == cit.pageNumber);
        if (idx != -1) {
          targetChunkId = chunks[idx].id;
        }
      } else if (cit.audioTimestampSeconds != null) {
        final idx = chunks.indexWhere((c) {
          if (c.audioTimestampSeconds == null) return false;
          return (c.audioTimestampSeconds! - cit.audioTimestampSeconds!).abs() < 15;
        });
        if (idx != -1) {
          targetChunkId = chunks[idx].id;
        }
      }
      
      setState(() {
        _previewChunks = chunks;
        _highlightChunkId = targetChunkId;
        _isLoadingPreview = false;
      });
    } catch (e) {
      setState(() {
        _isLoadingPreview = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed to load citation content: $e")),
      );
    }
  }

  void _triggerSingleDocGeneration(BuildContext context, String type, String sourceId) {
    if (_currentNotebook == null) return;
    context.read<ArtifactBloc>().add(
          GenerateArtifactEvent(
            notebookId: _currentNotebook!.id,
            artifactType: type,
            activeSourceIds: [sourceId],
          ),
        );
    setState(() {
      _selectedSourcePreview = null;
      _previewChunks = null;
      _highlightChunkId = null;
    });
    if (type == "flashcards") {
      setState(() { _activeLabTab = 0; });
    } else if (type == "timeline") {
      setState(() { _activeLabTab = 1; });
    } else {
      setState(() { _activeLabTab = 2; });
    }
  }

  Widget _buildDocumentPreviewPanel(BuildContext context) {
    final doc = _selectedSourcePreview!;
    return Container(
      color: const Color(0xFF0B0F19),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header toolbar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFF0F172A),
              border: Border(bottom: BorderSide(color: Colors.white10)),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white54, size: 20),
                  onPressed: () {
                    setState(() {
                      _selectedSourcePreview = null;
                      _previewChunks = null;
                      _highlightChunkId = null;
                    });
                  },
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        doc.name,
                        style: GoogleFonts.outfit(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        doc.fileType.toUpperCase(),
                        style: GoogleFonts.outfit(
                          color: Colors.white30,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                // Quick study tools triggers
                IconButton(
                  icon: const Icon(Icons.quiz, color: Color(0xFF8B5CF6), size: 18),
                  tooltip: "Generate Flashcards for this document",
                  onPressed: () {
                    _triggerSingleDocGeneration(context, "flashcards", doc.id);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.timeline, color: Color(0xFF8B5CF6), size: 18),
                  tooltip: "Generate Timeline for this document",
                  onPressed: () {
                    _triggerSingleDocGeneration(context, "timeline", doc.id);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.assignment, color: Color(0xFF8B5CF6), size: 18),
                  tooltip: "Generate Summary for this document",
                  onPressed: () {
                    _triggerSingleDocGeneration(context, "summary", doc.id);
                  },
                ),
              ],
            ),
          ),
          
          // Body
          Expanded(
            child: _isLoadingPreview
                ? const Center(
                    child: CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF8B5CF6)),
                    ),
                  )
                : (_previewChunks == null || _previewChunks!.isEmpty)
                    ? Center(
                        child: Text(
                          "No content available.",
                          style: GoogleFonts.outfit(color: Colors.white38, fontSize: 13),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _previewChunks!.length,
                        itemBuilder: (context, index) {
                          final chunk = _previewChunks![index];
                          final isHighlighted = chunk.id == _highlightChunkId;
                          
                          return Container(
                            key: ValueKey(chunk.id),
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: isHighlighted 
                                  ? const Color(0xFF2E1A47) 
                                  : const Color(0xFF131A26),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isHighlighted 
                                    ? const Color(0xFF8B5CF6) 
                                    : Colors.white10,
                                width: isHighlighted ? 1.5 : 1,
                              ),
                              boxShadow: isHighlighted
                                  ? [
                                      BoxShadow(
                                        color: const Color(0xFF8B5CF6).withOpacity(0.2),
                                        blurRadius: 8,
                                        offset: const Offset(0, 2),
                                      )
                                    ]
                                  : null,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: isHighlighted
                                            ? const Color(0xFF8B5CF6)
                                            : Colors.white10,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        "CHUNK ${chunk.chunkIndex + 1}",
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 8.5,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                    if (chunk.pageNumber != null)
                                      Text(
                                        "Page ${chunk.pageNumber}",
                                        style: const TextStyle(
                                          color: Colors.amberAccent,
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    if (chunk.audioTimestampSeconds != null)
                                      Text(
                                        "${chunk.audioTimestampSeconds!.toStringAsFixed(0)}s",
                                        style: const TextStyle(
                                          color: Colors.amberAccent,
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                MarkdownBody(
                                  data: chunk.content,
                                  styleSheet: MarkdownStyleSheet(
                                    p: const TextStyle(
                                      color: Color(0xE6FFFFFF),
                                      fontSize: 12,
                                      height: 1.4,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // RIGHT STUDY LAB PANEL
  // ==========================================
  Widget _buildRightStudyLab(BuildContext context) {
    if (_selectedSourcePreview != null) {
      return _buildDocumentPreviewPanel(context);
    }
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
                _buildTabButton(0, "Cards", Icons.style),
                _buildTabButton(1, "Timeline", Icons.timeline),
                _buildTabButton(2, "Summary", Icons.assignment),
                _buildTabButton(3, "Quiz", Icons.question_answer),
                _buildTabButton(4, "Map", Icons.hub),
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
      case 2:
        return "summary";
      case 3:
        return "quiz";
      default:
        return "mindmap";
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
      final list = _safeParseList(payload["cards"], payload is List ? payload : null);
      if (list.isEmpty) {
        return const Center(child: Text("No card records in payload.", style: TextStyle(color: Colors.white)));
      }
      return _FlashcardDeckView(cards: list);
    } else if (artifact.type == "timeline") {
      final list = _safeParseList(payload["timeline"], payload is List ? payload : null);
      if (list.isEmpty) {
        return const Center(child: Text("No timeline records in payload.", style: TextStyle(color: Colors.white)));
      }
      return _TimelineListView(timelineItems: list);
    } else if (artifact.type == "summary") {
      Map<String, dynamic> summaryMap;
      final rawSummary = payload["summary"];
      if (rawSummary is Map<String, dynamic>) {
        summaryMap = rawSummary;
      } else if (rawSummary is Map) {
        summaryMap = Map<String, dynamic>.from(rawSummary);
      } else if (rawSummary is String) {
        try {
          final decoded = jsonDecode(rawSummary);
          if (decoded is Map) {
            summaryMap = Map<String, dynamic>.from(decoded);
          } else {
            summaryMap = {
              "tldr": rawSummary,
              "key_findings": payload["key_findings"] ?? [],
              "open_questions": payload["open_questions"] ?? [],
            };
          }
        } catch (_) {
          summaryMap = {
            "tldr": rawSummary,
            "key_findings": payload["key_findings"] ?? [],
            "open_questions": payload["open_questions"] ?? [],
          };
        }
      } else {
        if (payload.containsKey("tldr") || payload.containsKey("key_findings")) {
          summaryMap = payload;
        } else {
          summaryMap = {
            "tldr": "No summary text provided.",
            "key_findings": [],
            "open_questions": [],
          };
        }
      }
      return _SummaryDetailsView(summary: summaryMap);
    } else if (artifact.type == "quiz") {
      final list = _safeParseList(payload["quiz"], payload is List ? payload : null);
      if (list.isEmpty) {
        return const Center(child: Text("No quiz questions in payload.", style: TextStyle(color: Colors.white)));
      }
      return _QuizDeckView(questions: list);
    } else if (artifact.type == "mindmap") {
      return _MindMapView(payload: payload);
    }
    return const Center(child: Text("Unsupported payload format."));
  }

  List<dynamic> _safeParseList(dynamic rawList, [dynamic fallback]) {
    if (rawList is List) {
      return rawList;
    }
    if (rawList is String) {
      try {
        final decoded = jsonDecode(rawList);
        if (decoded is List) {
          return decoded;
        }
      } catch (_) {}
    }
    if (fallback is List) {
      return fallback;
    }
    return [];
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
    final rawCard = widget.cards[_cardIndex];
    final Map<String, dynamic> card = rawCard is Map<String, dynamic>
        ? rawCard
        : (rawCard is Map ? Map<String, dynamic>.from(rawCard) : {});
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
        final rawItem = timelineItems[index];
        final Map<String, dynamic> item = rawItem is Map<String, dynamic>
            ? rawItem
            : (rawItem is Map ? Map<String, dynamic>.from(rawItem) : {});
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
    final tldr = summary["tldr"]?.toString() ?? "No TLDR text.";
    final rawFindings = summary["key_findings"];
    final findings = rawFindings is List ? rawFindings : [];
    final rawQuestions = summary["open_questions"];
    final questions = rawQuestions is List ? rawQuestions : [];
    
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

// ==========================================
// INTERACTIVE MCQ QUIZ VIEW
// ==========================================
class _QuizDeckView extends StatefulWidget {
  final List<dynamic> questions;
  const _QuizDeckView({required this.questions});

  @override
  State<_QuizDeckView> createState() => _QuizDeckViewState();
}

class _QuizDeckViewState extends State<_QuizDeckView> {
  int _questionIndex = 0;
  late List<int?> _userSelections;
  int _score = 0;

  @override
  void initState() {
    super.initState();
    _userSelections = List.filled(widget.questions.length, null);
  }

  @override
  void didUpdateWidget(covariant _QuizDeckView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.questions.length != _userSelections.length) {
      _userSelections = List.filled(widget.questions.length, null);
      _questionIndex = 0;
      _score = 0;
    }
  }

  void _selectOption(int index, int correctOption) {
    if (_userSelections[_questionIndex] != null) return; // already answered
    setState(() {
      _userSelections[_questionIndex] = index;
      if (index == correctOption) {
        _score++;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.questions.isEmpty) {
      return const Center(child: Text("No quiz questions available.", style: TextStyle(color: Colors.white)));
    }
    
    final rawQuest = widget.questions[_questionIndex];
    final Map<String, dynamic> questionData = rawQuest is Map<String, dynamic>
        ? rawQuest
        : (rawQuest is Map ? Map<String, dynamic>.from(rawQuest) : {});
        
    final questionText = questionData["question"] as String? ?? "Empty Question";
    final options = (questionData["options"] as List? ?? []).map((o) => o.toString()).toList();
    final correctOption = questionData["correct_option"] as int? ?? 0;
    final explanation = questionData["explanation"] as String? ?? "";
    
    final selectedOption = _userSelections[_questionIndex];
    final hasAnswered = selectedOption != null;
    
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header info
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "Question ${_questionIndex + 1} of ${widget.questions.length}",
                style: GoogleFonts.outfit(color: Colors.white38, fontSize: 11),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF8B5CF6).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  "Score: $_score/${widget.questions.length}",
                  style: GoogleFonts.outfit(color: const Color(0xFF8B5CF6), fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          
          // Question text card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E293B),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white10),
            ),
            child: Text(
              questionText,
              style: GoogleFonts.outfit(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold, height: 1.4),
            ),
          ),
          const SizedBox(height: 16),
          
          // Options List
          Expanded(
            child: ListView.builder(
              itemCount: options.length,
              itemBuilder: (context, index) {
                final optionText = options[index];
                
                Color btnColor = const Color(0xFF131A26);
                BorderSide borderSide = const BorderSide(color: Colors.white10);
                
                if (hasAnswered) {
                  if (index == correctOption) {
                    btnColor = Colors.green.withOpacity(0.2);
                    borderSide = const BorderSide(color: Colors.green, width: 1.5);
                  } else if (index == selectedOption) {
                    btnColor = Colors.red.withOpacity(0.2);
                    borderSide = const BorderSide(color: Colors.red, width: 1.5);
                  }
                }
                
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10.0),
                  child: Material(
                    color: btnColor,
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      onTap: () => _selectOption(index, correctOption),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.fromBorderSide(borderSide),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 22,
                              height: 22,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: hasAnswered && index == correctOption
                                    ? Colors.green
                                    : hasAnswered && index == selectedOption
                                        ? Colors.red
                                        : Colors.white10,
                              ),
                              child: Center(
                                child: Text(
                                  String.fromCharCode(65 + index), // A, B, C, D
                                  style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                optionText,
                                style: const TextStyle(color: Color(0xE6FFFFFF), fontSize: 12.5),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          
          // Explanation Area
          if (hasAnswered) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.withOpacity(0.2)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "EXPLANATION",
                    style: GoogleFonts.outfit(color: Colors.blue, fontWeight: FontWeight.bold, fontSize: 9.5, letterSpacing: 1.0),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    explanation,
                    style: const TextStyle(color: Colors.white70, fontSize: 11.5, height: 1.4),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          
          // Navigation controls
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.arrow_back, size: 16),
                label: const Text("Prev"),
                onPressed: _questionIndex > 0
                    ? () {
                        setState(() {
                          _questionIndex--;
                        });
                      }
                    : null,
              ),
              TextButton.icon(
                icon: const Icon(Icons.arrow_forward, size: 16),
                label: const Text("Next"),
                onPressed: _questionIndex < widget.questions.length - 1
                    ? () {
                        setState(() {
                          _questionIndex++;
                        });
                      }
                    : null,
              ),
            ],
          )
        ],
      ),
    );
  }
}

// ==========================================
// 2D CONCEPT GRAPH MIND MAP VIEW
// ==========================================
class _MindMapView extends StatefulWidget {
  final Map<String, dynamic> payload;
  const _MindMapView({required this.payload});

  @override
  State<_MindMapView> createState() => _MindMapViewState();
}

class _MindMapViewState extends State<_MindMapView> {
  String? _selectedNodeId;
  Map<String, Offset> _positions = {};
  late TransformationController _transformationController;
  
  @override
  void initState() {
    super.initState();
    _transformationController = TransformationController()
      ..value = (Matrix4.identity()..scale(0.8));
    _calculateLayout();
  }

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _MindMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _calculateLayout();
  }

  void _calculateLayout() {
    final nodes = widget.payload["nodes"] as List? ?? [];
    if (nodes.isEmpty) return;
    
    final double centerX = 400.0;
    final double centerY = 400.0;
    
    final Map<String, Offset> tempPositions = {};
    
    // Central node
    final centralNodeId = nodes[0]["id"]?.toString() ?? "";
    tempPositions[centralNodeId] = Offset(centerX, centerY);
    
    final outerNodes = nodes.skip(1).toList();
    final count = outerNodes.length;
    
    for (int i = 0; i < count; i++) {
      final nodeId = outerNodes[i]["id"]?.toString() ?? "";
      final ringIndex = i ~/ 6;
      final ringItemIndex = i % 6;
      final ringSize = min(6, count - ringIndex * 6);
      
      final radius = 160.0 + ringIndex * 120.0;
      final angle = (2 * pi * ringItemIndex) / ringSize;
      
      final x = centerX + radius * cos(angle);
      final y = centerY + radius * sin(angle);
      tempPositions[nodeId] = Offset(x, y);
    }
    
    setState(() {
      _positions = tempPositions;
      if (_selectedNodeId == null && nodes.isNotEmpty) {
        _selectedNodeId = centralNodeId;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final nodes = widget.payload["nodes"] as List? ?? [];
    final edges = widget.payload["edges"] as List? ?? [];
    
    if (nodes.isEmpty) {
      return const Center(child: Text("No concept nodes found in payload.", style: TextStyle(color: Colors.white)));
    }
    
    Map<String, dynamic>? selectedNode;
    try {
      final match = nodes.firstWhere((n) => n["id"]?.toString() == _selectedNodeId);
      selectedNode = match is Map<String, dynamic> ? match : Map<String, dynamic>.from(match);
    } catch (_) {
      selectedNode = null;
    }

    return Column(
      children: [
        // Pan & Zoom interactive workspace canvas
        Expanded(
          child: Container(
            color: const Color(0xFF070B13),
            child: InteractiveViewer(
              constrained: false,
              boundaryMargin: const EdgeInsets.all(500),
              minScale: 0.2,
              maxScale: 2.0,
              transformationController: _transformationController,
              child: SizedBox(
                width: 800,
                height: 800,
                child: Stack(
                  children: [
                    // Canvas Grid Lines background
                    CustomPaint(
                      painter: _GridPainter(),
                      size: const Size(800, 800),
                    ),
                    
                    // Draw relationship line links
                    CustomPaint(
                      painter: _GraphLinkPainter(_positions.entries.toList(), edges),
                      size: const Size(800, 800),
                    ),
                    
                    // Draw concept nodes
                    ..._positions.entries.map((entry) {
                      final nodeId = entry.key;
                      final pos = entry.value;
                      final nodeData = nodes.firstWhere((n) => n["id"]?.toString() == nodeId, orElse: () => null);
                      final label = nodeData?["label"]?.toString() ?? "Node";
                      final isSelected = nodeId == _selectedNodeId;
                      final isRoot = nodeId == (nodes[0]["id"]?.toString() ?? "");
                      
                      return Positioned(
                        left: pos.dx - 55,
                        top: pos.dy - 30,
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              _selectedNodeId = nodeId;
                            });
                          },
                          child: Container(
                            width: 110,
                            height: 60,
                            decoration: BoxDecoration(
                              color: isSelected 
                                  ? const Color(0xFF8B5CF6) 
                                  : isRoot 
                                      ? const Color(0xFF2E1A47) 
                                      : const Color(0xFF1E293B),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isSelected 
                                    ? Colors.white 
                                    : isRoot 
                                        ? const Color(0xFFC084FC) 
                                        : Colors.white30,
                                width: isSelected ? 2.0 : isRoot ? 1.8 : 1.2,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.3),
                                  blurRadius: 4,
                                  offset: const Offset(0, 2),
                                ),
                                if (isSelected)
                                  BoxShadow(
                                    color: const Color(0xFF8B5CF6).withOpacity(0.5),
                                    blurRadius: 10,
                                  ),
                              ],
                            ),
                            padding: const EdgeInsets.all(6),
                            child: Center(
                              child: Text(
                                label,
                                textAlign: TextAlign.center,
                                style: GoogleFonts.outfit(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ],
                ),
              ),
            ),
          ),
        ),
        
        // Node details inspection bottom bar card
        if (selectedNode != null)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              color: Color(0xFF0F172A),
              border: Border(top: BorderSide(color: Colors.white10)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(Icons.hub, color: Color(0xFF8B5CF6), size: 16),
                    const SizedBox(width: 8),
                    Text(
                      selectedNode["label"]?.toString().toUpperCase() ?? "",
                      style: GoogleFonts.outfit(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  selectedNode["description"]?.toString() ?? "No description available.",
                  style: const TextStyle(color: Colors.white70, fontSize: 12, height: 1.4),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.035)
      ..strokeWidth = 0.8;
    
    for (double y = 0; y < size.height; y += 40) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    for (double x = 0; x < size.width; x += 40) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _GraphLinkPainter extends CustomPainter {
  final List<MapEntry<String, Offset>> nodePositions;
  final List<dynamic> edges;
  _GraphLinkPainter(this.nodePositions, this.edges);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFA78BFA)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
      
    final Map<String, Offset> positionMap = Map.fromEntries(nodePositions);
    
    for (var edge in edges) {
      final src = edge["source"]?.toString();
      final tgt = edge["target"]?.toString();
      if (src != null && tgt != null && positionMap.containsKey(src) && positionMap.containsKey(tgt)) {
        final start = positionMap[src]!;
        final end = positionMap[tgt]!;
        canvas.drawLine(start, end, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
