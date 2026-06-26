import json
from abc import ABC, abstractmethod
from typing import Generator, List, Dict, Any
import httpx
from sentence_transformers import SentenceTransformer

class LLMProvider(ABC):
    @abstractmethod
    def generate(self, messages: List[Dict[str, str]]) -> str:
        """Generate a complete text response from a list of messages."""
        pass
        
    @abstractmethod
    def generate_stream(self, messages: List[Dict[str, str]]) -> Generator[str, None, None]:
        """Stream a text response token by token (SSE format compatibility)."""
        pass

    @abstractmethod
    def generate_structured(self, messages: List[Dict[str, str]], schema: Dict[str, Any]) -> Dict[str, Any]:
        """Generate JSON output matching a specific schema."""
        pass

    @abstractmethod
    def generate_embeddings(self, text: str) -> List[float]:
        """Generate a vector embedding list for a given text."""
        pass


# Local sentence-transformers embedding helper
# Loaded lazily and cached in-memory to keep CPU usage low
_local_embedding_model = None

def get_local_embedding_model():
    global _local_embedding_model
    if _local_embedding_model is None:
        # Load local lightweight 384-dimension model
        _local_embedding_model = SentenceTransformer("all-MiniLM-L6-v2")
    return _local_embedding_model


class LocalEmbeddingProvider(LLMProvider):
    """Local provider for sentence-transformers (embeddings only)."""
    def generate(self, messages: List[Dict[str, str]]) -> str:
        raise NotImplementedError("Local embedding provider only supports embeddings.")

    def generate_stream(self, messages: List[Dict[str, str]]) -> Generator[str, None, None]:
        raise NotImplementedError("Local embedding provider only supports embeddings.")

    def generate_structured(self, messages: List[Dict[str, str]], schema: Dict[str, Any]) -> Dict[str, Any]:
        raise NotImplementedError("Local embedding provider only supports embeddings.")

    def generate_embeddings(self, text: str) -> List[float]:
        model = get_local_embedding_model()
        embedding = model.encode(text)
        return embedding.tolist()


class OllamaProvider(LLMProvider):
    """Local Ollama client utilizing native HTTP requests."""
    def __init__(self, model_name: str, base_url: str = None):
        self.model_name = model_name
        if base_url:
            base_url = base_url.replace("localhost", "host.docker.internal").replace("127.0.0.1", "host.docker.internal")
        self.base_url = base_url or "http://host.docker.internal:11434"

    def generate(self, messages: List[Dict[str, str]]) -> str:
        url = f"{self.base_url}/api/chat"
        payload = {
            "model": self.model_name,
            "messages": messages,
            "stream": False,
            "options": {
                "temperature": 0.0
            }
        }
        with httpx.Client(timeout=60.0) as client:
            response = client.post(url, json=payload)
            response.raise_for_status()
            return response.json()["message"]["content"]

    def generate_stream(self, messages: List[Dict[str, str]]) -> Generator[str, None, None]:
        url = f"{self.base_url}/api/chat"
        payload = {
            "model": self.model_name,
            "messages": messages,
            "stream": True,
            "options": {
                "temperature": 0.0
            }
        }
        with httpx.stream("POST", url, json=payload, timeout=60.0) as r:
            r.raise_for_status()
            for line in r.iter_lines():
                if line:
                    data = json.loads(line)
                    # Yield token content if available
                    yield data.get("message", {}).get("content", "")

    def generate_structured(self, messages: List[Dict[str, str]], schema: Dict[str, Any]) -> Dict[str, Any]:
        url = f"{self.base_url}/api/chat"
        # We append instructions to the last user prompt to strictly adhere to the schema
        system_instructions = (
            f"\nYou MUST respond with valid JSON matching this schema:\n{json.dumps(schema)}"
        )
        modified_messages = list(messages)
        if modified_messages:
            modified_messages[-1] = {
                "role": modified_messages[-1]["role"],
                "content": modified_messages[-1]["content"] + system_instructions
            }

        payload = {
            "model": self.model_name,
            "messages": modified_messages,
            "stream": False,
            "format": "json", # Forces JSON mode in Ollama
            "options": {
                "temperature": 0.0
            }
        }
        with httpx.Client(timeout=60.0) as client:
            response = client.post(url, json=payload)
            response.raise_for_status()
            content = response.json()["message"]["content"]
            return json.loads(content)

    def generate_embeddings(self, text: str) -> List[float]:
        url = f"{self.base_url}/api/embeddings"
        payload = {
            "model": self.model_name,
            "prompt": text
        }
        with httpx.Client(timeout=30.0) as client:
            response = client.post(url, json=payload)
            response.raise_for_status()
            return response.json()["embedding"]


class OpenAIProvider(LLMProvider):
    """OpenAI API wrapper."""
    def __init__(self, model_name: str, api_key: str):
        self.model_name = model_name
        self.api_key = api_key
        self.base_url = "https://api.openai.com/v1"

    def _headers(self) -> Dict[str, str]:
        return {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json"
        }

    def generate(self, messages: List[Dict[str, str]]) -> str:
        url = f"{self.base_url}/chat/completions"
        payload = {
            "model": self.model_name,
            "messages": messages,
            "stream": False
        }
        with httpx.Client(timeout=60.0) as client:
            response = client.post(url, json=payload, headers=self._headers())
            response.raise_for_status()
            return response.json()["choices"][0]["message"]["content"]

    def generate_stream(self, messages: List[Dict[str, str]]) -> Generator[str, None, None]:
        url = f"{self.base_url}/chat/completions"
        payload = {
            "model": self.model_name,
            "messages": messages,
            "stream": True
        }
        with httpx.stream("POST", url, json=payload, headers=self._headers(), timeout=60.0) as r:
            r.raise_for_status()
            for line in r.iter_lines():
                if line.startswith("data: "):
                    content = line[6:]
                    if content == "[DONE]":
                        break
                    try:
                        data = json.loads(content)
                        delta = data["choices"][0]["delta"]
                        if "content" in delta:
                            yield delta["content"]
                    except Exception:
                        continue

    def generate_structured(self, messages: List[Dict[str, str]], schema: Dict[str, Any]) -> Dict[str, Any]:
        url = f"{self.base_url}/chat/completions"
        payload = {
            "model": self.model_name,
            "messages": messages,
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": "schema_response",
                    "strict": True,
                    "schema": schema
                }
            }
        }
        with httpx.Client(timeout=60.0) as client:
            response = client.post(url, json=payload, headers=self._headers())
            response.raise_for_status()
            content = response.json()["choices"][0]["message"]["content"]
            return json.loads(content)

    def generate_embeddings(self, text: str) -> List[float]:
        url = f"{self.base_url}/embeddings"
        payload = {
            "model": self.model_name,
            "input": text
        }
        with httpx.Client(timeout=30.0) as client:
            response = client.post(url, json=payload, headers=self._headers())
            response.raise_for_status()
            return response.json()["data"][0]["embedding"]


class ClaudeProvider(LLMProvider):
    """Anthropic Claude API wrapper."""
    def __init__(self, model_name: str, api_key: str):
        self.model_name = model_name
        self.api_key = api_key
        self.base_url = "https://api.anthropic.com/v1"

    def _headers(self) -> Dict[str, str]:
        return {
            "x-api-key": self.api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json"
        }

    def _convert_messages(self, messages: List[Dict[str, str]]) -> tuple:
        """Helper to extract system prompt from user/assistant chat history."""
        system = ""
        converted = []
        for msg in messages:
            if msg["role"] == "system":
                system = msg["content"]
            else:
                converted.append(msg)
        return system, converted

    def generate(self, messages: List[Dict[str, str]]) -> str:
        url = f"{self.base_url}/messages"
        system, converted = self._convert_messages(messages)
        payload = {
            "model": self.model_name,
            "messages": converted,
            "max_tokens": 4096
        }
        if system:
            payload["system"] = system

        with httpx.Client(timeout=60.0) as client:
            response = client.post(url, json=payload, headers=self._headers())
            response.raise_for_status()
            return response.json()["content"][0]["text"]

    def generate_stream(self, messages: List[Dict[str, str]]) -> Generator[str, None, None]:
        url = f"{self.base_url}/messages"
        system, converted = self._convert_messages(messages)
        payload = {
            "model": self.model_name,
            "messages": converted,
            "max_tokens": 4096,
            "stream": True
        }
        if system:
            payload["system"] = system

        with httpx.stream("POST", url, json=payload, headers=self._headers(), timeout=60.0) as r:
            r.raise_for_status()
            for line in r.iter_lines():
                if line.startswith("data: "):
                    content = line[6:]
                    try:
                        data = json.loads(content)
                        if data["type"] == "content_block_delta":
                            yield data["delta"]["text"]
                    except Exception:
                        continue

    def generate_structured(self, messages: List[Dict[str, str]], schema: Dict[str, Any]) -> Dict[str, Any]:
        url = f"{self.base_url}/messages"
        system, converted = self._convert_messages(messages)
        payload = {
            "model": self.model_name,
            "messages": converted,
            "max_tokens": 4096,
            "tools": [
                {
                    "name": "structured_output",
                    "description": "Output matching schema",
                    "input_schema": schema
                }
            ],
            "tool_choice": {"type": "tool", "name": "structured_output"}
        }
        if system:
            payload["system"] = system

        with httpx.Client(timeout=60.0) as client:
            response = client.post(url, json=payload, headers=self._headers())
            response.raise_for_status()
            tool_use = response.json()["content"][0]
            return tool_use["input"]

    def generate_embeddings(self, text: str) -> List[float]:
        raise NotImplementedError("Claude does not support embeddings API natively.")


class GeminiProvider(LLMProvider):
    """Google Gemini API wrapper."""
    def __init__(self, model_name: str, api_key: str):
        self.model_name = model_name
        self.api_key = api_key
        self.base_url = "https://generativelanguage.googleapis.com/v1beta"

    def _convert_messages(self, messages: List[Dict[str, str]]) -> tuple:
        """Convert messages to Gemini contents structure."""
        system_instruction = None
        contents = []
        for msg in messages:
            if msg["role"] == "system":
                system_instruction = {"parts": [{"text": msg["content"]}]}
            else:
                role = "user" if msg["role"] == "user" else "model"
                contents.append({
                    "role": role,
                    "parts": [{"text": msg["content"]}]
                })
        return system_instruction, contents

    def generate(self, messages: List[Dict[str, str]]) -> str:
        url = f"{self.base_url}/models/{self.model_name}:generateContent?key={self.api_key}"
        system_instruction, contents = self._convert_messages(messages)
        payload = {"contents": contents}
        if system_instruction:
            payload["systemInstruction"] = system_instruction

        with httpx.Client(timeout=60.0) as client:
            response = client.post(url, json=payload)
            response.raise_for_status()
            return response.json()["candidates"][0]["content"]["parts"][0]["text"]

    def generate_stream(self, messages: List[Dict[str, str]]) -> Generator[str, None, None]:
        url = f"{self.base_url}/models/{self.model_name}:streamGenerateContent?key={self.api_key}"
        system_instruction, contents = self._convert_messages(messages)
        payload = {"contents": contents}
        if system_instruction:
            payload["systemInstruction"] = system_instruction

        with httpx.stream("POST", url, json=payload, timeout=60.0) as r:
            r.raise_for_status()
            buffer = ""
            for line in r.iter_lines():
                if line:
                    buffer += line
                    try:
                        # Stream endpoint outputs chunks wrapped in array-like structures
                        # Strip standard wrappers and yield text if parseable
                        clean_buff = buffer.strip().lstrip("[,").rstrip("]").strip()
                        if clean_buff.endswith("}"):
                            data = json.loads(clean_buff)
                            yield data["candidates"][0]["content"]["parts"][0]["text"]
                            buffer = ""
                    except Exception:
                        continue

    def generate_structured(self, messages: List[Dict[str, str]], schema: Dict[str, Any]) -> Dict[str, Any]:
        url = f"{self.base_url}/models/{self.model_name}:generateContent?key={self.api_key}"
        system_instruction, contents = self._convert_messages(messages)
        payload = {
            "contents": contents,
            "generationConfig": {
                "responseMimeType": "application/json",
                "responseSchema": schema
            }
        }
        if system_instruction:
            payload["systemInstruction"] = system_instruction

        with httpx.Client(timeout=60.0) as client:
            response = client.post(url, json=payload)
            response.raise_for_status()
            text = response.json()["candidates"][0]["content"]["parts"][0]["text"]
            return json.loads(text)

    def generate_embeddings(self, text: str) -> List[float]:
        # Google embedding models (e.g. text-embedding-004) use a different endpoint
        url = f"{self.base_url}/models/{self.model_name}:embedContent?key={self.api_key}"
        payload = {
            "model": f"models/{self.model_name}",
            "content": {
                "parts": [{"text": text}]
            }
        }
        with httpx.Client(timeout=30.0) as client:
            response = client.post(url, json=payload)
            response.raise_for_status()
            return response.json()["embedding"]["values"]


def get_llm_provider(config: Dict[str, Any]) -> LLMProvider:
    """Factory to retrieve requested LLMProvider class based on config dictionary."""
    prov = config.get("provider")
    model = config.get("model_name")
    api_key = config.get("api_key") # Plaintext decrypted key
    base_url = config.get("base_url")

    if prov == "ollama":
        return OllamaProvider(model_name=model, base_url=base_url)
    elif prov == "openai":
        return OpenAIProvider(model_name=model, api_key=api_key)
    elif prov == "claude":
        return ClaudeProvider(model_name=model, api_key=api_key)
    elif prov == "gemini":
        return GeminiProvider(model_name=model, api_key=api_key)
    elif prov == "local-embeddings":
        return LocalEmbeddingProvider()
    else:
        raise ValueError(f"Unknown provider name: {prov}")
