import os
import json
from typing import List, Dict, Any, Set
import httpx
from sentence_transformers import CrossEncoder

from db import decrypt_key, get_db_connection
from providers import get_llm_provider

# Lazy-loaded Cross-Encoder model to preserve memory
_rerank_model = None

def get_rerank_model():
    global _rerank_model
    if _rerank_model is None:
        _rerank_model = CrossEncoder("cross-encoder/ms-marco-MiniLM-L-6-v2")
    return _rerank_model


def run_web_fallback(query: str) -> Dict[str, Any]:
    """Routes search queries to Tavily or Serper if local vector similarity is poor."""
    tavily_key = os.getenv("TAVILY_API_KEY")
    serper_key = os.getenv("SERPER_API_KEY")

    if tavily_key:
        try:
            url = "https://api.tavily.com/search"
            payload = {"api_key": tavily_key, "query": query, "max_results": 3}
            response = httpx.post(url, json=payload, timeout=10.0)
            response.raise_for_status()
            results = response.json().get("results", [])
            content = "\n\n".join([f"Source: {r['title']} ({r['url']})\n{r['content']}" for r in results])
            return {"content": content, "source_type": "web"}
        except Exception:
            pass

    if serper_key:
        try:
            url = "https://google.serper.dev/search"
            headers = {"X-API-KEY": serper_key, "Content-Type": "application/json"}
            payload = {"q": query, "num": 3}
            response = httpx.post(url, json=payload, headers=headers, timeout=10.0)
            response.raise_for_status()
            results = response.json().get("organic", [])
            content = "\n\n".join([f"Source: {r['title']} ({r['link']})\n{r['snippet']}" for r in results])
            return {"content": content, "source_type": "web"}
        except Exception:
            pass

    # Mock response if API keys are missing to allow local testing
    return {
        "content": "Web fallback triggered: Search APIs were not configured on the server. Please check environment configuration.",
        "source_type": "web"
    }


def should_decompose(query: str) -> bool:
    """Determines if query is complex enough to decompose (15+ words or contains conjunctions)."""
    words = query.split()
    if len(words) > 15:
        return True
    
    conjunctions = {"and", "compare", "versus", "both", "vs", "difference"}
    for w in words:
        if w.lower() in conjunctions:
            return True
    return False


def execute_vector_search(cur, notebook_id: str, active_source_ids: List[str], query_vector: List[float], limit: int = 15) -> List[Dict[str, Any]]:
    """Executes a strictly scoped SQL search on PostgreSQL/pgvector using ANY()."""
    # Get column name mapping
    cur.execute("SELECT embedding_model FROM notebooks WHERE id = %s;", (notebook_id,))
    row = cur.fetchone()
    if not row:
        raise ValueError("Notebook not found")
    emb_model = row[0]

    if emb_model == "text-embedding-3-small":
        vector_column = "embedding_1536"
    elif emb_model == "nomic-embed-text":
        vector_column = "embedding_768"
    elif emb_model == "all-MiniLM-L6-v2":
        vector_column = "embedding_384"
    else:
        raise ValueError("Unknown embedding model")

    query = f"""
        SELECT id, source_id, chunk_index, page_number, audio_timestamp_seconds, content,
               (1 - ({vector_column} <=> %s::vector)) AS similarity
        FROM document_chunks
        WHERE source_id = ANY(%s)
        ORDER BY {vector_column} <=> %s::vector
        LIMIT %s;
    """
    
    cur.execute(query, (query_vector, active_source_ids, query_vector, limit))
    rows = cur.fetchall()
    
    results = []
    for r in rows:
        results.append({
            "chunk_id": str(r[0]),
            "source_id": str(r[1]),
            "chunk_index": r[2],
            "page_number": r[3],
            "audio_timestamp_seconds": r[4],
            "content": r[5],
            "similarity": float(r[6])
        })
    return results


def retrieve_relevant_chunks(
    conn, 
    notebook_id: str, 
    active_source_ids: List[str], 
    user_query: str,
    enable_web_fallback: bool = True
) -> Dict[str, Any]:
    """Orchestrates HyDE, Multi-Query, local Re-ranking, and Web fallback pipelines."""
    
    if not active_source_ids:
        return {"chunks": [], "source_type_used": "local_documents", "web_content": None}

    # 1. Fetch Notebook Configuration
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT llm_provider, model_name, api_key_encrypted, base_url, embedding_model, similarity_threshold
            FROM notebooks 
            WHERE id = %s;
            """,
            (notebook_id,)
        )
        row = cur.fetchone()
        if not row:
            raise ValueError(f"Notebook {notebook_id} not found.")
        
        provider, model_name, api_key_enc, base_url, emb_model, similarity_threshold = row
        decrypted_key = decrypt_key(api_key_enc)

    # Instantiate LLM and Embedding Providers
    llm_config = {
        "provider": provider,
        "model_name": model_name,
        "api_key": decrypted_key,
        "base_url": base_url
    }
    llm = get_llm_provider(llm_config)

    # Embed configuration
    if emb_model == "text-embedding-3-small":
        emb_config = {"provider": "openai", "model_name": emb_model, "api_key": decrypted_key}
    elif emb_model == "nomic-embed-text":
        emb_config = {"provider": "ollama", "model_name": emb_model, "base_url": base_url}
    elif emb_model == "all-MiniLM-L6-v2":
        emb_config = {"provider": "local-embeddings", "model_name": emb_model}
    else:
        raise ValueError(f"Unknown embedding model: {emb_model}")
    
    embedding_provider = get_llm_provider(emb_config)

    # 2. DECIDE: Multi-Query Decomposition vs Single-Query (HyDE)
    queries_to_embed = []
    
    if should_decompose(user_query):
        # Multi-Query Decomposition Prompt
        prompt = f"Decompose this complex query into 2 to 3 simple, atomic search queries. Respond strictly in JSON format as a list of strings, with no explanation or extra text. Complex query: {user_query}"
        messages = [{"role": "user", "content": prompt}]
        schema = {
            "type": "array",
            "items": {"type": "string"}
        }
        try:
            queries_to_embed = llm.generate_structured(messages, schema)
        except Exception:
            # Fallback to user query if parsing/LLM fails
            queries_to_embed = [user_query]
    else:
        # HyDE Query Expansion
        hyde_prompt = f"Write a short passage that would directly answer: {user_query}"
        messages = [{"role": "user", "content": hyde_prompt}]
        try:
            hyde_answer = llm.generate(messages)
            queries_to_embed = [hyde_answer]
        except Exception:
            queries_to_embed = [user_query]

    # 3. Retrieve chunks from pgvector for all generated search strings
    retrieved_chunks = []
    seen_chunk_ids: Set[str] = set()

    with conn.cursor() as cur:
        for q in queries_to_embed:
            # Generate embedding
            q_vector = embedding_provider.generate_embeddings(q)
            # Execute scoped search
            results = execute_vector_search(cur, notebook_id, active_source_ids, q_vector, limit=15)
            # Deduplicate by chunk_id
            for r in results:
                if r["chunk_id"] not in seen_chunk_ids:
                    seen_chunk_ids.add(r["chunk_id"])
                    retrieved_chunks.append(r)

    # 4. Handle Similarity Threshold and Web Fallback
    max_similarity = max([c["similarity"] for c in retrieved_chunks]) if retrieved_chunks else 0.0
    
    if max_similarity < similarity_threshold and enable_web_fallback:
        web_res = run_web_fallback(user_query)
        return {
            "chunks": [],
            "source_type_used": "web",
            "web_content": web_res["content"]
        }

    # 5. CROSS-ENCODER RE-RANKING (Local CPU)
    # If we got chunks, evaluate them against the raw user query
    if retrieved_chunks:
        reranker = get_rerank_model()
        # Formulate pairs: [(query, chunk_content), ...]
        pairs = [(user_query, c["content"]) for c in retrieved_chunks]
        scores = reranker.predict(pairs)
        
        # Attach scores and sort
        for idx, score in enumerate(scores):
            retrieved_chunks[idx]["rerank_score"] = float(score)
            
        retrieved_chunks.sort(key=lambda x: x["rerank_score"], reverse=True)

    # Select top 4 re-ranked chunks
    top_chunks = retrieved_chunks[:4]

    return {
        "chunks": top_chunks,
        "source_type_used": "local_documents",
        "web_content": None
    }
