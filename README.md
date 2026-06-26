# 🧠 PaperMind Workspace - Developer Guide

PaperMind is a local-first, privacy-first document intelligence workspace. It runs completely offline using a local FastAPI server, PostgreSQL with `pgvector`, and Ollama for generative LLM responses.

This guide provides instructions on how to configure and run the application, including a **Docker-less native macOS setup**.

---

## 🛠️ Prerequisites

Ensure you have the following installed on your system:
* **Flutter SDK:** For compiling the macOS desktop app.
* **Ollama:** Running locally on the host machine.
* **Python 3.11+:** For running the backend natively (if running without Docker).
* **FFmpeg:** Required for audio transcriptions (using Whisper). On macOS, install via: `brew install ffmpeg`.

---

## ⚡ Method 1: Running with Docker (Recommended)

This is the easiest way to launch the database and the backend server. It handles `pgvector`, python dependencies, and `ffmpeg` compilation automatically.

### Step 1: Start Ollama (Terminal 1)
Make sure Ollama is running and has the `qwen2.5:0.5b` model pulled:
```bash
# Start Ollama service on all network interfaces
OLLAMA_HOST=0.0.0.0 OLLAMA_ORIGINS="*" ollama serve

# Pull the lightweight model (in a separate tab or run once)
ollama pull qwen2.5:0.5b
```

### Step 2: Start DB and Backend (Terminal 2)
Run the Docker Compose suite from the project root:
```bash
docker compose up --build
```
This spins up:
* **papermind-db:** PostgreSQL 16 server with pgvector loaded on port `5432`.
* **papermind-backend:** FastAPI server listening on port `8000`.

### Step 3: Run the Desktop Client (Terminal 3)
```bash
cd frontend
flutter run -d macos
```

---

## 🔌 Method 2: Running without Docker (Native macOS)

If you prefer to run the entire backend and database stack natively on macOS without Docker containers, follow these steps.

### Step 1: Install & Start PostgreSQL with pgvector
You must run PostgreSQL locally with the `pgvector` extension installed.
* **Option A (Homebrew Native):**
  ```bash
  # Install PostgreSQL
  brew install postgresql@16
  brew link postgresql@16 --force
  brew services start postgresql@16

  # Install pgvector (compiles and installs pgvector extension locally)
  brew install pgvector
  ```
* **Option B (Hybrid - Run only PostgreSQL in Docker):**
  If you don't want to compile pgvector locally, you can run a single lightweight database container:
  ```bash
  docker run --name papermind-db -p 5432:5432 -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=papermind -d pgvector/pgvector:pg16
  ```

### Step 2: Initialize the Local Database Schema
Create the database and execute the schema setup script:
```bash
# Create the local database (if using brew native postgres)
createdb -h localhost -U postgres papermind

# Run the initialization SQL script to build tables and vector indexes
psql -h localhost -U postgres -d papermind -f init.sql
```

### Step 3: Set Up Python Virtual Environment
Navigate to the backend directory, initialize a python virtual environment, and install dependencies:
```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate

# Install requirements
pip install -r requirements.txt
```

### Step 4: Run local FastAPI Server (Terminal 2)
Run the server using `uvicorn` with the necessary local environment variables:
```bash
# Ensure local settings connect to localhost instead of container names
export DATABASE_URL="postgresql://postgres:postgres@localhost:5432/papermind"
export OLLAMA_BASE_URL="http://localhost:11434"
export FERNET_KEY="gK-U6l9Q-30Vl_S17sZ0g7vS-a3fUfGZgK-U6l9Q-30="

uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

### Step 5: Start Ollama (Terminal 1)
```bash
OLLAMA_HOST=0.0.0.0 OLLAMA_ORIGINS="*" ollama serve
```

### Step 6: Start Desktop Client (Terminal 3)
```bash
cd frontend
flutter run -d macos
```

---

## 🏎️ Summary of Hot-Keys for Terminal Execution

To quickly launch in **Docker-less Native Mode**, you can use this reference sequence:

| Terminal | Path | Action / Command |
| :--- | :--- | :--- |
| **Terminal 1** | Host | `OLLAMA_HOST=0.0.0.0 OLLAMA_ORIGINS="*" ollama serve` |
| **Terminal 2** | `backend/` | `source .venv/bin/activate && export DATABASE_URL="postgresql://postgres:postgres@localhost:5432/papermind" && export OLLAMA_BASE_URL="http://localhost:11434" && export FERNET_KEY="gK-U6l9Q-30Vl_S17sZ0g7vS-a3fUfGZgK-U6l9Q-30=" && uvicorn main:app --reload` |
| **Terminal 3** | `frontend/` | `flutter run -d macos` |

---

## 🧪 Running Tests

### Backend Tests
Ensure your python virtual environment is active:
```bash
cd backend
python tests.py
```

### Frontend Tests
Ensure flutter package dependencies are downloaded:
```bash
cd frontend
flutter test
```

---

## 🔒 Production Security Best Practices

When publishing or deploying PaperMind to a production or shared environment, adhere to the following security guidelines:

### 1. Generate a Unique Encryption Key
PaperMind encrypts cloud LLM API keys (OpenAI, Anthropic, Gemini) using symmetric Fernet encryption before storing them in the PostgreSQL database.
* **Never use the default `FERNET_KEY` value in production.**
* Generate a new, secure base64-encoded key using Python:
  ```bash
  python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
  ```
* Inject the output as the `FERNET_KEY` environment variable on your backend server.

### 2. Restrict PostgreSQL Access & Override Passwords
* Modify the default PostgreSQL username (`postgres`) and password (`postgres`) in both your `docker-compose.yml` environment configurations and your database URL connection string.
* Ensure database ports (`5432`) are not exposed publicly, keeping them isolated within your private network or Docker network bridges.

### 3. Protect Environment Variables (.env)
* The `.env` file containing external search API keys (`SERPER_API_KEY`, `TAVILY_API_KEY`) is automatically excluded from git tracking via the root `.gitignore`.
* Never hardcode keys directly into source code files, configuration manifests, or Dockerfiles.

