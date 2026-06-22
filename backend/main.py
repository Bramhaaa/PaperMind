import os
import time
import uuid
import json
import hashlib
from typing import List, Dict, Any, Optional
from fastapi import FastAPI, HTTPException, UploadFile, File, Form, BackgroundTasks
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from db import pool, get_db_connection, encrypt_key, decrypt_key
from ingestion import process_ingestion
from retrieval import retrieve_relevant_chunks
from providers import get_llm_provider

app = FastAPI(title="PaperMind Backend", version="0.1.0")


# --- REQUEST & RESPONSE SCHEMAS ---

class NotebookCreate(BaseModel):
    name: str
    llm_provider: str # 'ollama', 'openai', 'claude', 'gemini'
    model_name: str
    api_key: Optional[str] = None
    base_url: Optional[str] = None
    embedding_model: str # 'text-embedding-3-small', 'nomic-embed-text', 'all-MiniLM-L6-v2'
    similarity_threshold: Optional[float] = 0.70

class ChatQueryRequest(BaseModel):
    notebook_id: str
    message: str
    active_source_ids: List[str]
    enable_web_fallback: Optional[bool] = True
    stream: Optional[bool] = True

class ArtifactGenerateRequest(BaseModel):
    notebook_id: str
    artifact_type: str # 'flashcards', 'timeline', 'summary'
    active_source_ids: List[str]


# --- BACKGROUND INGESTION WORKER ---

def bg_ingestion_worker(notebook_id: str, file_name: str, file_type: str, file_bytes: bytes, source_id_pre: str):
    """Asynchronous background worker to parse, chunk, embed, and dual-write to DB."""
    try:
        with get_db_connection() as conn:
            # Generate the elements inside a transaction
            # process_ingestion creates the source and all chunk records
            with conn.transaction():
                # We perform the processing and DB writes.
                # In process_ingestion, it creates the completed records.
                # Since we want to use the pre-generated source_id, we override process_ingestion to insert
                # with the pre-generated UUID instead of returning a new one.
                # Let's adjust db query inside process_ingestion inline:
                # 1. Fetch notebook details
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT embedding_model, api_key_encrypted, base_url FROM notebooks WHERE id = %s;",
                        (notebook_id,)
                    )
                    row = cur.fetchone()
                    if not row:
                        return
                    emb_model, api_key_enc, base_url = row
                    decrypted_key = decrypt_key(api_key_enc)

                # Use helper parsers/chunkers
                from ingestion import parse_pdf, transcribe_audio, RecursiveTokenSplitter
                
                raw_units = []
                if file_type in ("txt", "md"):
                    text = file_bytes.decode("utf-8", errors="ignore")
                    raw_units.append({"text": text, "page_number": None, "audio_timestamp": None})
                elif file_type == "pdf":
                    pdf_pages = parse_pdf(file_bytes)
                    for page in pdf_pages:
                        raw_units.append({"text": page["text"], "page_number": page["page_number"], "audio_timestamp": None})
                elif file_type in ("mp3", "m4a"):
                    audio_chunks = transcribe_audio(file_bytes, file_name)
                else:
                    return

                final_chunks = []
                if file_type in ("txt", "md", "pdf"):
                    splitter = RecursiveTokenSplitter()
                    for unit in raw_units:
                        split_units = splitter.split(unit["text"], page_number=unit["page_number"])
                        final_chunks.extend(split_units)
                else:
                    final_chunks = audio_chunks

                # Embeddings config
                if emb_model == "text-embedding-3-small":
                    emb_config = {"provider": "openai", "model_name": emb_model, "api_key": decrypted_key}
                    vector_column = "embedding_1536"
                elif emb_model == "nomic-embed-text":
                    emb_config = {"provider": "ollama", "model_name": emb_model, "base_url": base_url}
                    vector_column = "embedding_768"
                elif emb_model == "all-MiniLM-L6-v2":
                    emb_config = {"provider": "local-embeddings", "model_name": emb_model}
                    vector_column = "embedding_384"
                else:
                    return

                embedding_provider = get_llm_provider(emb_config)
                
                embeddings_list = []
                for chunk in final_chunks:
                    emb = embedding_provider.generate_embeddings(chunk["content"])
                    embeddings_list.append(emb)

                with conn.cursor() as cur:
                    # Update the pending source to completed
                    cur.execute(
                        """
                        UPDATE sources 
                        SET ingestion_status = 'completed', size_bytes = %s
                        WHERE id = %s;
                        """,
                        (len(file_bytes), source_id_pre)
                    )

                    # Bulk insert chunks using pre-generated source_id
                    for idx, chunk in enumerate(final_chunks):
                        emb = embeddings_list[idx]
                        query = f"""
                            INSERT INTO document_chunks (
                                source_id, chunk_index, page_number, char_start, char_end, 
                                audio_timestamp_seconds, content, {vector_column}
                            )
                            VALUES (%s, %s, %s, %s, %s, %s, %s, %s);
                        """
                        cur.execute(
                            query,
                            (
                                source_id_pre,
                                idx,
                                chunk["page_number"],
                                0,
                                len(chunk["content"]),
                                chunk["audio_timestamp"],
                                chunk["content"],
                                emb
                            )
                        )
    except Exception as e:
        # Update source to failed state
        try:
            with get_db_connection() as conn:
                with conn.cursor() as cur:
                    cur.execute(
                        "UPDATE sources SET ingestion_status = 'failed' WHERE id = %s;",
                        (source_id_pre,)
                    )
        except Exception:
            pass


# --- ENDPOINTS ---

@app.on_event("startup")
def startup_event():
    time.sleep(1)

@app.on_event("shutdown")
def shutdown_event():
    pool.close()

@app.get("/")
def read_root():
    return {"status": "ok", "app": "PaperMind Backend"}

@app.get("/health")
def health_check():
    return {"status": "healthy", "timestamp": time.time()}


@app.post("/api/v1/notebooks")
def create_notebook(data: NotebookCreate):
    try:
        encrypted_key = encrypt_key(data.api_key)
        with get_db_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO notebooks (name, llm_provider, model_name, api_key_encrypted, base_url, embedding_model, similarity_threshold)
                    VALUES (%s, %s, %s, %s, %s, %s, %s)
                    RETURNING id, name, llm_provider, model_name, embedding_model, similarity_threshold;
                    """,
                    (
                        data.name,
                        data.llm_provider,
                        data.model_name,
                        encrypted_key,
                        data.base_url,
                        data.embedding_model,
                        data.similarity_threshold
                    )
                )
                row = cur.fetchone()
                return {
                    "notebook_id": str(row[0]),
                    "name": row[1],
                    "llm_provider": row[2],
                    "model_name": row[3],
                    "embedding_model": row[4],
                    "similarity_threshold": row[5]
                }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/sources/upload")
async def upload_source(
    background_tasks: BackgroundTasks,
    notebook_id: str = Form(...),
    file: UploadFile = File(...)
):
    # Verify Notebook Exists
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT id FROM notebooks WHERE id = %s;", (notebook_id,))
            if not cur.fetchone():
                raise HTTPException(status_code=404, detail="Notebook not found")

    # Read bytes and validate size limit (50MB)
    file_bytes = await file.read()
    max_size = 50 * 1024 * 1024
    if len(file_bytes) > max_size:
        raise HTTPException(status_code=400, detail="File size exceeds 50MB limit.")

    file_name = file.filename
    file_type = os.path.splitext(file_name)[1].lstrip(".").lower()

    if file_type not in ("pdf", "md", "txt", "mp3", "m4a"):
        raise HTTPException(status_code=400, detail=f"Unsupported file extension: {file_type}")

    # Estimate chunks (approx 2000 chars or 500 tokens per chunk)
    char_count = len(file_bytes.decode("utf-8", errors="ignore")) if file_type in ("txt", "md") else len(file_bytes)
    estimated_chunks = max(1, char_count // 2000)

    # Pre-generate source ID and write a pending record to the database
    source_id = str(uuid.uuid4())
    with get_db_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO sources (id, notebook_id, name, file_type, size_bytes, ingestion_status)
                VALUES (%s, %s, %s, %s, %s, 'pending');
                """,
                (source_id, notebook_id, file_name, file_type, len(file_bytes))
            )

    # Queue parsing, chunking, and vector embedding generation in background task runner
    background_tasks.add_task(
        bg_ingestion_worker,
        notebook_id,
        file_name,
        file_type,
        file_bytes,
        source_id
    )

    return {
        "source_id": source_id,
        "status": "ingestion_queued",
        "estimated_chunks": estimated_chunks
    }


@app.post("/api/v1/chat/query")
def chat_query(request: ChatQueryRequest):
    try:
        # Establish connection for SSE stream context
        conn = pool.connection()
        
        # 1. Fetch conversation history (last 3 turns)
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT role, content FROM conversation_turns 
                WHERE notebook_id = %s 
                ORDER BY created_at ASC 
                LIMIT 6; -- 6 items represent 3 turns (user + assistant)
                """,
                (request.notebook_id,)
            )
            history = [{"role": r[0], "content": r[1]} for r in cur.fetchall()]

            # Fetch LLM configurations
            cur.execute(
                "SELECT llm_provider, model_name, api_key_encrypted, base_url FROM notebooks WHERE id = %s;",
                (request.notebook_id,)
            )
            row = cur.fetchone()
            if not row:
                raise ValueError("Notebook not found")
            provider_name, model_name, api_key_enc, base_url = row
            decrypted_key = decrypt_key(api_key_enc)

        # 2. Retrieve context from pgvector
        search_res = retrieve_relevant_chunks(
            conn,
            request.notebook_id,
            request.active_source_ids,
            request.message,
            enable_web_fallback=request.enable_web_fallback
        )

        source_type_used = search_res["source_type_used"]
        citations = []
        context_str = ""

        if source_type_used == "web":
            context_str = f"Information retrieved from web:\n{search_res['web_content']}"
        else:
            chunks = search_res["chunks"]
            # Format chunks with chunk ID reference for potential LLM mapping
            context_lines = []
            for c in chunks:
                context_lines.append(f"[Chunk ID: {c['chunk_id']}]\n{c['content']}")
            context_str = "\n\n".join(context_lines)

            # Build Citation payloads
            # Query source names to match source_id to names
            if chunks:
                with conn.cursor() as cur:
                    src_ids = list(set([c["source_id"] for c in chunks]))
                    cur.execute(
                        "SELECT id, name FROM sources WHERE id = ANY(%s);",
                        (src_ids,)
                    )
                    src_names = {str(r[0]): r[1] for r in cur.fetchall()}
                
                for c in chunks:
                    citations.append({
                        "source_id": c["source_id"],
                        "name": src_names.get(c["source_id"], "Unknown Document"),
                        "page_number": c["page_number"],
                        "audio_timestamp_seconds": c["audio_timestamp_seconds"]
                    })

        # 3. Assemble chat payload
        system_prompt = (
            "You are PaperMind, a helpful research assistant. "
            "Use the provided context to answer the query accurately. "
            "If citations or chunk boundaries are available, cite your sources naturally."
        )
        
        messages = [{"role": "system", "content": system_prompt}]
        messages.extend(history)
        
        # Inject context alongside current query
        user_message_with_ctx = (
            f"Context:\n{context_str}\n\n"
            f"Query: {request.message}"
        )
        messages.append({"role": "user", "content": user_message_with_ctx})

        llm_config = {
            "provider": provider_name,
            "model_name": model_name,
            "api_key": decrypted_key,
            "base_url": base_url
        }
        llm = get_llm_provider(llm_config)

        # 4. SSE Stream generator
        def sse_generator():
            full_response_text = []
            try:
                # Stream tokens
                for token in llm.generate_stream(messages):
                    full_response_text.append(token)
                    yield f"data: {json.dumps({'type': 'token', 'content': token})}\n\n"

                # Send citations
                yield f"data: {json.dumps({'type': 'citations', 'citations': citations})}\n\n"
                
                # Send completion metadata
                yield f"data: {json.dumps({'type': 'done', 'source_type_used': source_type_used})}\n\n"

                # Write turns to database
                assistant_response = "".join(full_response_text)
                with conn.transaction():
                    with conn.cursor() as cur:
                        cur.execute(
                            "INSERT INTO conversation_turns (notebook_id, role, content) VALUES (%s, 'user', %s);",
                            (request.notebook_id, request.message)
                        )
                        cur.execute(
                            "INSERT INTO conversation_turns (notebook_id, role, content) VALUES (%s, 'assistant', %s);",
                            (request.notebook_id, assistant_response)
                        )
            except Exception as e:
                yield f"data: {json.dumps({'type': 'error', 'content': str(e)})}\n\n"
            finally:
                conn.close()

        if request.stream:
            return StreamingResponse(sse_generator(), media_type="text/event-stream")
        else:
            # Fallback to blocking response
            full_text = llm.generate(messages)
            with conn.transaction():
                with conn.cursor() as cur:
                    cur.execute(
                        "INSERT INTO conversation_turns (notebook_id, role, content) VALUES (%s, 'user', %s);",
                        (request.notebook_id, request.message)
                    )
                    cur.execute(
                        "INSERT INTO conversation_turns (notebook_id, role, content) VALUES (%s, 'assistant', %s);",
                        (request.notebook_id, full_text)
                    )
            conn.close()
            return {
                "response": full_text,
                "citations": citations,
                "source_type_used": source_type_used
            }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/api/v1/artifacts/generate")
def generate_artifact(request: ArtifactGenerateRequest):
    try:
        if not request.active_source_ids:
            raise HTTPException(status_code=400, detail="No active sources provided for artifact generation.")

        # 1. ARTIFACT CACHING HASH ALGORITHM
        # Fetch sources sorted alphabetically by ID to build stable SHA-256 hash
        with get_db_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT id, created_at FROM sources 
                    WHERE id = ANY(%s) 
                    ORDER BY id ASC;
                    """,
                    (request.active_source_ids,)
                )
                source_rows = cur.fetchall()
                if not source_rows:
                    raise HTTPException(status_code=400, detail="Active source documents do not exist.")

                # SHA-256 of (active source IDs + document created_at versions)
                hash_base = "".join([f"{r[0]}_{r[1].isoformat()}" for r in source_rows])
                source_hash = hashlib.sha256(hash_base.encode()).hexdigest()

                # Check cache
                cur.execute(
                    """
                    SELECT id, payload, created_at 
                    FROM artifacts 
                    WHERE notebook_id = %s AND artifact_type = %s AND source_hash = %s;
                    """,
                    (request.notebook_id, request.artifact_type, source_hash)
                )
                cache_row = cur.fetchone()
                if cache_row:
                    return {
                        "artifact_id": str(cache_row[0]),
                        "artifact_type": request.artifact_type,
                        "created_at": cache_row[2].isoformat(),
                        "cache_hit": True,
                        "payload": cache_row[1]
                    }

                # 2. CACHE MISS: Build artifact from document chunks
                # Load all chunks for selected sources
                cur.execute(
                    """
                    SELECT id, content FROM document_chunks 
                    WHERE source_id = ANY(%s) 
                    ORDER BY source_id ASC, chunk_index ASC;
                    """,
                    (request.active_source_ids,)
                )
                chunks = cur.fetchall()
                if not chunks:
                    raise HTTPException(status_code=400, detail="No document chunks found to generate artifact from.")

                # Fetch LLM configuration
                cur.execute(
                    "SELECT llm_provider, model_name, api_key_encrypted, base_url FROM notebooks WHERE id = %s;",
                    (request.notebook_id,)
                )
                nb_row = cur.fetchone()
                if not nb_row:
                    raise ValueError("Notebook not found")
                provider_name, model_name, api_key_enc, base_url = nb_row
                decrypted_key = decrypt_key(api_key_enc)

        # Formulate Combined Corpus context with Chunk ID anchors
        corpus_list = []
        for c in chunks:
            corpus_list.append(f"[Chunk ID: {str(c[0])}]\n{c[1]}")
        corpus_context = "\n\n".join(corpus_list)

        # Define prompts and response schemas based on type
        if request.artifact_type == "flashcards":
            prompt = (
                "Based on the provided context, generate a set of educational flashcards. "
                "Each flashcard must have a front question, a back answer, a difficulty scale (easy, medium, or hard), "
                "and an array of source_chunk_ids representing the Chunk IDs containing the information."
            )
            schema = {
                "type": "object",
                "properties": {
                    "cards": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "front": {"type": "string"},
                                "back": {"type": "string"},
                                "source_chunk_ids": {"type": "array", "items": {"type": "string"}},
                                "difficulty": {"type": "string", "enum": ["easy", "medium", "hard"]}
                            },
                            "required": ["front", "back", "source_chunk_ids", "difficulty"]
                        }
                    }
                },
                "required": ["cards"]
            }
        elif request.artifact_type == "timeline":
            prompt = (
                "Based on the provided context, construct a chronological timeline of events. "
                "Each timeline event must include a date_or_period string, an event_description, "
                "and an array of source_chunk_ids representing the Chunk IDs containing the event details."
            )
            schema = {
                "type": "object",
                "properties": {
                    "timeline": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "date_or_period": {"type": "string"},
                                "event_description": {"type": "string"},
                                "source_chunk_ids": {"type": "array", "items": {"type": "string"}}
                            },
                            "required": ["date_or_period", "event_description", "source_chunk_ids"]
                        }
                    }
                },
                "required": ["timeline"]
            }
        elif request.artifact_type == "summary":
            prompt = (
                "Based on the provided context, construct an executive summary. "
                "Provide a tldr string, an array of key_findings (strings), an array of open_questions (strings) "
                "representing things left unanswered by the context, and source_coverage containing the list of Chunk IDs cited."
            )
            schema = {
                "type": "object",
                "properties": {
                    "summary": {
                        "type": "object",
                        "properties": {
                            "tldr": {"type": "string"},
                            "key_findings": {"type": "array", "items": {"type": "string"}},
                            "open_questions": {"type": "array", "items": {"type": "string"}},
                            "source_coverage": {"type": "array", "items": {"type": "string"}}
                        },
                        "required": ["tldr", "key_findings", "open_questions", "source_coverage"]
                    }
                },
                "required": ["summary"]
            }
        else:
            raise HTTPException(status_code=400, detail=f"Unsupported artifact type: {request.artifact_type}")

        # Invoke LLM structured generation
        llm_config = {
            "provider": provider_name,
            "model_name": model_name,
            "api_key": decrypted_key,
            "base_url": base_url
        }
        llm = get_llm_provider(llm_config)

        messages = [
            {"role": "system", "content": "You are a precise educational summary generator."},
            {"role": "user", "content": f"Context:\n{corpus_context}\n\nInstructions: {prompt}"}
        ]
        
        payload_result = llm.generate_structured(messages, schema)

        # Save to database
        artifact_id = str(uuid.uuid4())
        created_at_time = None
        with get_db_connection() as conn:
            with conn.transaction():
                with conn.cursor() as cur:
                    cur.execute(
                        """
                        INSERT INTO artifacts (id, notebook_id, artifact_type, source_hash, payload)
                        VALUES (%s, %s, %s, %s, %s)
                        RETURNING created_at;
                        """,
                        (artifact_id, request.notebook_id, request.artifact_type, source_hash, json.dumps(payload_result))
                    )
                    created_at_time = cur.fetchone()[0]

        return {
            "artifact_id": artifact_id,
            "artifact_type": request.artifact_type,
            "created_at": created_at_time.isoformat(),
            "cache_hit": False,
            "payload": payload_result
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/v1/notebooks/{id}/artifacts")
def list_artifacts(id: str):
    try:
        with get_db_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT id, artifact_type, created_at, payload 
                    FROM artifacts 
                    WHERE notebook_id = %s
                    ORDER BY created_at DESC;
                    """,
                    (id,)
                )
                rows = cur.fetchall()
                artifacts_list = []
                for r in rows:
                    artifacts_list.append({
                        "artifact_id": str(r[0]),
                        "artifact_type": r[1],
                        "created_at": r[2].isoformat(),
                        "payload": r[3]
                    })
                return {"artifacts": artifacts_list}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
