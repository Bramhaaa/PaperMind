-- Enable extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "vector";

-- Create notebooks table
CREATE TABLE IF NOT EXISTS notebooks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    llm_provider TEXT NOT NULL,
    model_name TEXT NOT NULL,
    api_key_encrypted TEXT,
    base_url TEXT,
    embedding_model TEXT NOT NULL,
    similarity_threshold FLOAT DEFAULT 0.70 NOT NULL
);

-- Create sources table
CREATE TABLE IF NOT EXISTS sources (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    notebook_id UUID NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    file_type TEXT NOT NULL,
    size_bytes INT NOT NULL,
    ingestion_status TEXT NOT NULL, -- e.g., 'pending', 'processing', 'completed', 'failed'
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create document_chunks table with support for different embedding dimensions
CREATE TABLE IF NOT EXISTS document_chunks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id UUID NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
    chunk_index INT NOT NULL,
    page_number INT,
    char_start INT NOT NULL,
    char_end INT NOT NULL,
    audio_timestamp_seconds FLOAT,
    content TEXT NOT NULL,
    embedding_1536 VECTOR(1536), -- for OpenAI (text-embedding-3-small)
    embedding_768 VECTOR(768),   -- for Ollama (nomic-embed-text)
    embedding_384 VECTOR(384)    -- for Sentence-Transformers (all-MiniLM-L6-v2)
);

-- Create conversation_turns table
CREATE TABLE IF NOT EXISTS conversation_turns (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    notebook_id UUID NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
    role TEXT NOT NULL, -- 'user' or 'assistant'
    content TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create artifacts table
CREATE TABLE IF NOT EXISTS artifacts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    notebook_id UUID NOT NULL REFERENCES notebooks(id) ON DELETE CASCADE,
    artifact_type TEXT NOT NULL, -- 'flashcards', 'timeline', 'summary'
    source_hash TEXT NOT NULL,
    payload JSONB NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Configure HNSW indexes with ef_construction capped for dev/working memory limit

CREATE INDEX IF NOT EXISTS idx_document_chunks_embedding_1536 
ON document_chunks 
USING hnsw (embedding_1536 vector_cosine_ops) 
WITH (m = 16, ef_construction = 64);

CREATE INDEX IF NOT EXISTS idx_document_chunks_embedding_768 
ON document_chunks 
USING hnsw (embedding_768 vector_cosine_ops) 
WITH (m = 16, ef_construction = 64);

CREATE INDEX IF NOT EXISTS idx_document_chunks_embedding_384 
ON document_chunks 
USING hnsw (embedding_384 vector_cosine_ops) 
WITH (m = 16, ef_construction = 64);


-------------------------------------------------------------------------------
-- DATABASE SELF-TEST / VERIFICATION
-------------------------------------------------------------------------------
DO $$
DECLARE
    v_notebook_id UUID;
    v_source_id UUID;
    v_test_vector_384 REAL[];
    v_test_vector_768 REAL[];
    v_test_vector_1536 REAL[];
    v_result_count INT;
BEGIN
    RAISE NOTICE 'Starting database self-test...';

    -- 1. Create a dummy notebook
    INSERT INTO notebooks (name, llm_provider, model_name, embedding_model)
    VALUES ('Self-Test Notebook', 'ollama', 'llama3', 'nomic-embed-text')
    RETURNING id INTO v_notebook_id;

    -- 2. Create a dummy source
    INSERT INTO sources (notebook_id, name, file_type, size_bytes, ingestion_status)
    VALUES (v_notebook_id, 'test.txt', 'txt', 12, 'completed')
    RETURNING id INTO v_source_id;

    -- 3. Construct test vectors
    -- We construct 384, 768, and 1536 length arrays filled with small numbers
    v_test_vector_384 := array_fill(0.1::real, ARRAY[384]);
    v_test_vector_768 := array_fill(0.1::real, ARRAY[768]);
    v_test_vector_1536 := array_fill(0.1::real, ARRAY[1536]);

    -- 4. Insert dummy document chunks with the vectors
    INSERT INTO document_chunks (source_id, chunk_index, char_start, char_end, content, embedding_384, embedding_768, embedding_1536)
    VALUES (v_source_id, 0, 0, 12, 'Hello World', v_test_vector_384::vector, v_test_vector_768::vector, v_test_vector_1536::vector);

    -- 5. Perform a similarity query on each column and verify we retrieve the record
    v_result_count := 0;
    SELECT 1 INTO v_result_count 
    FROM document_chunks 
    ORDER BY embedding_384 <=> v_test_vector_384::vector 
    LIMIT 1;
    
    IF v_result_count <> 1 THEN
        RAISE EXCEPTION 'Failed vector 384 cosine similarity self-test';
    END IF;

    v_result_count := 0;
    SELECT 1 INTO v_result_count 
    FROM document_chunks 
    ORDER BY embedding_768 <=> v_test_vector_768::vector 
    LIMIT 1;
    
    IF v_result_count <> 1 THEN
        RAISE EXCEPTION 'Failed vector 768 cosine similarity self-test';
    END IF;

    v_result_count := 0;
    SELECT 1 INTO v_result_count 
    FROM document_chunks 
    ORDER BY embedding_1536 <=> v_test_vector_1536::vector 
    LIMIT 1;
    
    IF v_result_count <> 1 THEN
        RAISE EXCEPTION 'Failed vector 1536 cosine similarity self-test';
    END IF;

    -- 6. Clean up self-test data
    DELETE FROM notebooks WHERE id = v_notebook_id;

    RAISE NOTICE 'Database self-test completed successfully. pgvector is fully operational.';
END $$;
