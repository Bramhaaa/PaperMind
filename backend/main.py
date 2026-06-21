import os
import time
from fastapi import FastAPI, HTTPException
from psycopg_pool import ConnectionPool

app = FastAPI(title="PaperMind Backend", version="0.1.0")

# Database URL configuration
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://postgres:postgres@db:5432/papermind")

# Set up connection pool
pool = ConnectionPool(
    conninfo=DATABASE_URL,
    min_size=1,
    max_size=10,
    open=True
)

@app.on_event("startup")
def startup_event():
    # Allow the pool some time to establish the initial connection
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

@app.get("/db-health")
def db_health_check():
    try:
        with pool.connection() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT 1;")
                result = cur.fetchone()
                if result and result[0] == 1:
                    return {
                        "status": "connected",
                        "database": "postgresql",
                        "vector_extension": check_vector_extension(conn)
                    }
                else:
                    raise HTTPException(status_code=500, detail="Unexpected DB response")
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Database connection failed: {str(e)}"
        )

def check_vector_extension(conn) -> str:
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT extversion FROM pg_extension WHERE extname = 'vector';")
            row = cur.fetchone()
            return row[0] if row else "not_installed"
    except Exception:
        return "error_checking"
