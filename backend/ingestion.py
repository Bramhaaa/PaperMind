import io
import os
import re
import tempfile
from typing import List, Dict, Any
import tiktoken
from pypdf import PdfReader
import whisper

from db import decrypt_key
from providers import get_llm_provider

# Lazy-loaded Whisper model to preserve memory
_whisper_model = None

def get_whisper_model():
    global _whisper_model
    if _whisper_model is None:
        # Load tiny model for low-latency and light footprint
        _whisper_model = whisper.load_model("tiny")
    return _whisper_model


def count_tokens(text: str) -> int:
    """Helper to count tokens using cl100k_base tokenizer."""
    enc = tiktoken.get_encoding("cl100k_base")
    return len(enc.encode(text))


class RecursiveTokenSplitter:
    """Recursive sentence-level splitter targeting 500-token chunks with 50-token overlap."""
    def __init__(self, max_tokens: int = 500, overlap_tokens: int = 50, min_tokens: int = 100):
        self.max_tokens = max_tokens
        self.overlap_tokens = overlap_tokens
        self.min_tokens = min_tokens
        self.tokenizer = tiktoken.get_encoding("cl100k_base")

    def _split_into_sentences(self, text: str) -> List[str]:
        # Split by typical sentence boundaries or newlines
        sentences = re.split(r'(?<=[.!?])\s+|\n+', text)
        return [s.strip() for s in sentences if s.strip()]

    def split(self, text: str, page_number: int = None) -> List[Dict[str, Any]]:
        sentences = self._split_into_sentences(text)
        chunks = []
        
        current_sentences = []
        current_tokens = 0
        
        for sentence in sentences:
            sentence_tokens = len(self.tokenizer.encode(sentence))
            
            # If a single sentence exceeds max_tokens, split by words
            if sentence_tokens > self.max_tokens:
                words = sentence.split(" ")
                current_word_chunk = []
                word_tokens = 0
                for word in words:
                    w_tok = len(self.tokenizer.encode(word))
                    if word_tokens + w_tok > self.max_tokens:
                        chunks.append({
                            "content": " ".join(current_word_chunk),
                            "page_number": page_number,
                            "audio_timestamp": None
                        })
                        # overlap by keeping some words
                        current_word_chunk = current_word_chunk[-5:]
                        word_tokens = len(self.tokenizer.encode(" ".join(current_word_chunk)))
                    current_word_chunk.append(word)
                    word_tokens += w_tok
                if current_word_chunk:
                    current_sentences.append(" ".join(current_word_chunk))
                    current_tokens += word_tokens
                continue

            if current_tokens + sentence_tokens > self.max_tokens:
                # Save chunk
                chunks.append({
                    "content": " ".join(current_sentences),
                    "page_number": page_number,
                    "audio_timestamp": None
                })
                
                # Create overlap: gather trailing sentences until they match overlap threshold
                overlap_sentences = []
                overlap_tokens_count = 0
                for s in reversed(current_sentences):
                    s_tok = len(self.tokenizer.encode(s))
                    if overlap_tokens_count + s_tok <= self.overlap_tokens:
                        overlap_sentences.insert(0, s)
                        overlap_tokens_count += s_tok
                    else:
                        break
                current_sentences = overlap_sentences + [sentence]
                current_tokens = overlap_tokens_count + sentence_tokens
            else:
                current_sentences.append(sentence)
                current_tokens += sentence_tokens

        # Handle leftover text
        if current_sentences:
            content = " ".join(current_sentences)
            # If this trailing chunk is too small (< 100 tokens), merge it into the previous chunk if one exists
            if len(chunks) > 0 and len(self.tokenizer.encode(content)) < self.min_tokens:
                chunks[-1]["content"] += " " + content
            else:
                chunks.append({
                    "content": content,
                    "page_number": page_number,
                    "audio_timestamp": None
                })

        return chunks


def parse_pdf(file_bytes: bytes) -> List[Dict[str, Any]]:
    """Extract pages and text content from a PDF file."""
    reader = PdfReader(io.BytesIO(file_bytes))
    pages_content = []
    for idx, page in enumerate(reader.pages):
        text = page.extract_text()
        if text and text.strip():
            pages_content.append({
                "text": text.strip(),
                "page_number": idx + 1
            })
    return pages_content


def transcribe_audio(file_bytes: bytes, file_name: str) -> List[Dict[str, Any]]:
    """Transcribe audio files locally using Whisper and output timestamped chunks."""
    suffix = os.path.splitext(file_name)[1]
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
        tmp.write(file_bytes)
        tmp_path = tmp.name

    try:
        model = get_whisper_model()
        result = model.transcribe(tmp_path)
        
        # Whisper outputs segments: {"start": float, "end": float, "text": str}
        segments = result.get("segments", [])
        
        chunks = []
        current_chunk_text = []
        current_tokens = 0
        chunk_start_time = None
        
        tokenizer = tiktoken.get_encoding("cl100k_base")
        max_tokens = 500
        overlap_segments = []
        
        for seg in segments:
            seg_text = seg["text"].strip()
            seg_tokens = len(tokenizer.encode(seg_text))
            
            if chunk_start_time is None:
                chunk_start_time = seg["start"]
                
            if current_tokens + seg_tokens > max_tokens:
                chunks.append({
                    "content": " ".join(current_chunk_text),
                    "page_number": None,
                    "audio_timestamp": chunk_start_time
                })
                # Overlap: keep last segment
                current_chunk_text = [seg_text]
                current_tokens = seg_tokens
                chunk_start_time = seg["start"]
            else:
                current_chunk_text.append(seg_text)
                current_tokens += seg_tokens
                
        if current_chunk_text:
            content = " ".join(current_chunk_text)
            if len(chunks) > 0 and len(tokenizer.encode(content)) < 100:
                chunks[-1]["content"] += " " + content
            else:
                chunks.append({
                    "content": content,
                    "page_number": None,
                    "audio_timestamp": chunk_start_time
                })
        return chunks
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)


def process_ingestion(conn, notebook_id: str, file_name: str, file_type: str, file_bytes: bytes) -> str:
    """
    Parses, chunks, embeds, and saves file data atomically inside a transaction.
    Raises Exception on failure to roll back changes.
    """
    # 1. Fetch notebook settings to locate the correct embedding model
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT embedding_model, llm_provider, api_key_encrypted, base_url 
            FROM notebooks 
            WHERE id = %s;
            """,
            (notebook_id,)
        )
        row = cur.fetchone()
        if not row:
            raise ValueError(f"Notebook with id {notebook_id} not found.")
        
        emb_model, provider_name, api_key_enc, base_url = row
        decrypted_key = decrypt_key(api_key_enc)

    # 2. Parse file content into list of raw text blobs with page/timestamp lineages
    raw_units = [] # dicts with {"text": str, "page_number": int|None, "audio_timestamp": float|None}
    
    if file_type in ("txt", "md"):
        text = file_bytes.decode("utf-8", errors="ignore")
        raw_units.append({
            "text": text,
            "page_number": None,
            "audio_timestamp": None
        })
    elif file_type == "pdf":
        pdf_pages = parse_pdf(file_bytes)
        for page in pdf_pages:
            raw_units.append({
                "text": page["text"],
                "page_number": page["page_number"],
                "audio_timestamp": None
            })
    elif file_type in ("mp3", "m4a"):
        # Whisper output is already chunk-formatted with timestamps
        audio_chunks = transcribe_audio(file_bytes, file_name)
    else:
        raise ValueError(f"Unsupported file type: {file_type}")

    # 3. Apply Recursive splitter to text pages/blobs (skipped for Audio since it chunks during transcription)
    final_chunks = []
    if file_type in ("txt", "md", "pdf"):
        splitter = RecursiveTokenSplitter()
        for unit in raw_units:
            split_units = splitter.split(unit["text"], page_number=unit["page_number"])
            final_chunks.extend(split_units)
    else:
        final_chunks = audio_chunks

    # 4. Generate Embeddings using the notebook's embedding model configuration
    # Create configuration for provider factory
    if emb_model == "text-embedding-3-small":
        emb_config = {
            "provider": "openai",
            "model_name": emb_model,
            "api_key": decrypted_key
        }
        vector_column = "embedding_1536"
    elif emb_model == "nomic-embed-text":
        emb_config = {
            "provider": "ollama",
            "model_name": emb_model,
            "base_url": base_url
        }
        vector_column = "embedding_768"
    elif emb_model == "all-MiniLM-L6-v2":
        emb_config = {
            "provider": "local-embeddings",
            "model_name": emb_model
        }
        vector_column = "embedding_384"
    else:
        raise ValueError(f"Unknown embedding model: {emb_model}")

    embedding_provider = get_llm_provider(emb_config)
    
    # Pre-generate embeddings for all chunks before database insert
    embeddings_list = []
    for chunk in final_chunks:
        emb = embedding_provider.generate_embeddings(chunk["content"])
        embeddings_list.append(emb)

    # 5. ATOMIC DUAL-WRITE DATABASE TRANSACTION
    # We execute this inside a subtransaction block (savepoint or raw transaction lock)
    # The calling function passes the connection which has an active transaction block.
    with conn.cursor() as cur:
        # A. Save source record
        cur.execute(
            """
            INSERT INTO sources (notebook_id, name, file_type, size_bytes, ingestion_status)
            VALUES (%s, %s, %s, %s, 'completed')
            RETURNING id;
            """,
            (notebook_id, file_name, file_type, len(file_bytes))
        )
        source_id = cur.fetchone()[0]

        # B. Bulk insert chunks
        for idx, chunk in enumerate(final_chunks):
            emb = embeddings_list[idx]
            query = f"""
                INSERT INTO document_chunks (
                    source_id, chunk_index, page_number, char_start, char_end, 
                    audio_timestamp_seconds, content, {vector_column}
                )
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s);
            """
            # Approximate char boundaries
            char_start = 0
            char_end = len(chunk["content"])
            
            cur.execute(
                query,
                (
                    source_id,
                    idx,
                    chunk["page_number"],
                    char_start,
                    char_end,
                    chunk["audio_timestamp"],
                    chunk["content"],
                    emb
                )
            )
            
    return source_id
