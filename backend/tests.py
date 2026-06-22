import unittest
import uuid
import numpy as np
from fastapi.testclient import TestClient

from db import encrypt_key, decrypt_key, get_db_connection
from providers import get_llm_provider, get_local_embedding_model
from ingestion import RecursiveTokenSplitter
from retrieval import should_decompose, execute_vector_search
from main import app

class TestPaperMindCore(unittest.TestCase):
    
    def test_fernet_cryptography(self):
        """Verify API keys are successfully encrypted and decrypted back to original text."""
        original_key = "sk-proj-1234567890abcdefghijklmnopqrstuvwxyz"
        encrypted = encrypt_key(original_key)
        self.assertNotEqual(original_key, encrypted)
        
        decrypted = decrypt_key(encrypted)
        self.assertEqual(original_key, decrypted)

    def test_recursive_token_splitter(self):
        """Verify splitter respects max token limits and min chunk thresholds."""
        splitter = RecursiveTokenSplitter(max_tokens=20, overlap_tokens=5, min_tokens=5)
        text = (
            "This is a long sentence that should easily get chunked by the recursive token splitter. "
            "It will exceed the twenty token max limit, leading to multiple clean chunks of text."
        )
        chunks = splitter.split(text)
        
        self.assertTrue(len(chunks) > 1)
        for c in chunks:
            self.assertTrue(len(c["content"]) > 0)
            tokens = len(splitter.tokenizer.encode(c["content"]))
            self.assertTrue(tokens <= 20)

    def test_local_embedding_shape(self):
        """Verify SentenceTransformers (all-MiniLM-L6-v2) runs locally and outputs exactly 384 dimensions."""
        provider = get_llm_provider({"provider": "local-embeddings", "model_name": "all-MiniLM-L6-v2"})
        emb = provider.generate_embeddings("Hello World")
        self.assertEqual(len(emb), 384)
        self.assertTrue(all(isinstance(val, float) for val in emb))

    def test_should_decompose_heuristics(self):
        """Verify complex and comparative queries trigger multi-query decomposition."""
        self.assertTrue(should_decompose("Compare authentication approaches in doc A vs rate limiting in doc B"))
        self.assertTrue(should_decompose("What is the difference between OAuth2 and Basic authentication?"))
        self.assertTrue(should_decompose("This query is incredibly long and has a huge number of words that will easily pass the fifteen words boundary limit for search decomposition."))
        
        # Simple query should not decompose
        self.assertFalse(should_decompose("How do I run the app?"))


class TestPaperMindAPI(unittest.TestCase):
    
    def setUp(self):
        self.client = TestClient(app)

    def test_health_endpoints(self):
        """Verify server and health check endpoints respond with active status."""
        response = self.client.get("/")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "ok")

        response = self.client.get("/health")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "healthy")

    def test_notebook_lifecycle_and_upload(self):
        """Verify notebook creation, source upload, and database mapping."""
        # 1. Create Notebook
        payload = {
            "name": "Unit Testing Notebook",
            "llm_provider": "ollama",
            "model_name": "qwen2.5:0.5b",
            "api_key": None,
            "base_url": "http://host.docker.internal:11434",
            "embedding_model": "all-MiniLM-L6-v2" # uses local CPU embedding model
        }
        res = self.client.post("/api/v1/notebooks", json=payload)
        self.assertEqual(res.status_code, 200)
        nb = res.json()
        nb_id = nb["notebook_id"]
        self.assertIsNotNone(nb_id)

        # 2. Upload source file (txt file to run through splitter and DB write)
        file_content = b"PaperMind is a privacy-first, local-first document intelligence workspace. It runs completely offline."
        files = {"file": ("test_doc.txt", file_content, "text/plain")}
        data = {"notebook_id": nb_id}
        
        upload_res = self.client.post("/api/v1/sources/upload", data=data, files=files)
        self.assertEqual(upload_res.status_code, 200)
        upload_data = upload_res.json()
        self.assertEqual(upload_data["status"], "ingestion_queued")
        source_id = upload_data["source_id"]
        self.assertIsNotNone(source_id)

        # Wait briefly for background worker to process text (local CPU embedding is very fast)
        import time
        for _ in range(10):
            time.sleep(0.5)
            # check ingestion status
            with get_db_connection() as conn:
                with conn.cursor() as cur:
                    cur.execute("SELECT ingestion_status FROM sources WHERE id = %s;", (source_id,))
                    row = cur.fetchone()
                    if row and row[0] == "completed":
                        break
        
        # Verify document ingested successfully
        with get_db_connection() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT ingestion_status FROM sources WHERE id = %s;", (source_id,))
                status = cur.fetchone()[0]
                self.assertEqual(status, "completed")
                
                # Verify chunks were successfully written
                cur.execute("SELECT COUNT(*) FROM document_chunks WHERE source_id = %s;", (source_id,))
                chunk_count = cur.fetchone()[0]
                self.assertTrue(chunk_count >= 1)

        # 3. Clean up DB records
        with get_db_connection() as conn:
            with conn.transaction():
                with conn.cursor() as cur:
                    cur.execute("DELETE FROM notebooks WHERE id = %s;", (nb_id,))


if __name__ == "__main__":
    unittest.main()
