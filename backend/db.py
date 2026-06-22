import os
from contextlib import contextmanager
from psycopg_pool import ConnectionPool
from cryptography.fernet import Fernet

# Database configuration
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://postgres:postgres@db:5432/papermind")

# Set up connection pool
pool = ConnectionPool(
    conninfo=DATABASE_URL,
    min_size=1,
    max_size=10,
    open=True
)

# Fernet Cryptography config for API keys
FERNET_KEY = os.getenv("FERNET_KEY")
if not FERNET_KEY:
    # Generate a temporary fallback key if none is injected (for safety in testing)
    FERNET_KEY = Fernet.generate_key().decode()

cipher_suite = Fernet(FERNET_KEY.encode())

def encrypt_key(api_key: str) -> str:
    """Encrypts an API key string to base64 encrypted string."""
    if not api_key:
        return None
    return cipher_suite.encrypt(api_key.encode()).decode()

def decrypt_key(encrypted_key: str) -> str:
    """Decrypts an encrypted key base64 string back to plaintext."""
    if not encrypted_key:
        return None
    return cipher_suite.decrypt(encrypted_key.encode()).decode()

@contextmanager
def get_db_connection():
    """Context manager to lease a connection from the connection pool."""
    with pool.connection() as conn:
        yield conn
