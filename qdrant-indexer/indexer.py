"""
Ghiath vault indexer.

A deliberately simple polling sidecar. Every POLL_INTERVAL_SECONDS it walks the
Obsidian vault, finds Markdown files whose content has changed since the last
pass, splits them into small chunks, embeds each chunk locally with fastembed
(no external API call), and upserts the vectors into Qdrant. Files that have
been deleted from the vault have their vectors removed.

This is v1. It is intentionally not clever: no file-system watching, no
incremental diffing beyond a content hash, no external embedding provider. It
is enough to give the agents a semantic search layer over the vault.
"""

import hashlib
import os
import re
import time
import uuid

from fastembed import TextEmbedding
from qdrant_client import QdrantClient
from qdrant_client.http import models as qm

QDRANT_URL = os.environ.get("QDRANT_URL", "http://qdrant:6333")
COLLECTION = os.environ.get("QDRANT_COLLECTION", "vault")
VAULT_PATH = os.environ.get("VAULT_PATH", "/vault")
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL_SECONDS", "30"))

# bge-small-en-v1.5 -> 384-dim vectors. Small, fast, CPU-friendly.
EMBED_MODEL = "BAAI/bge-small-en-v1.5"
VECTOR_SIZE = 384

# Namespace for deterministic point IDs so re-runs update points in place
# instead of creating duplicates.
ID_NAMESPACE = uuid.UUID("6f9619ff-8b86-d011-b42d-00c04fc964ff")

# Fixed namespace UUID (RFC 4122) used only as a stable seed for uuid5.


def log(msg: str) -> None:
    print(f"[indexer] {msg}", flush=True)


def chunk_markdown(text: str, max_chars: int = 1500) -> list[str]:
    """Split on blank lines, then greedily pack paragraphs up to max_chars."""
    paragraphs = [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]
    chunks: list[str] = []
    current = ""
    for para in paragraphs:
        if not current:
            current = para
        elif len(current) + len(para) + 2 <= max_chars:
            current = f"{current}\n\n{para}"
        else:
            chunks.append(current)
            current = para
    if current:
        chunks.append(current)
    return chunks


def point_id(rel_path: str, index: int) -> str:
    return str(uuid.uuid5(ID_NAMESPACE, f"{rel_path}::{index}"))


def ensure_collection(client: QdrantClient) -> None:
    existing = {c.name for c in client.get_collections().collections}
    if COLLECTION not in existing:
        client.create_collection(
            collection_name=COLLECTION,
            vectors_config=qm.VectorParams(
                size=VECTOR_SIZE, distance=qm.Distance.COSINE
            ),
        )
        # Payload index so we can delete-by-path cheaply.
        client.create_payload_index(
            collection_name=COLLECTION,
            field_name="path",
            field_schema=qm.PayloadSchemaType.KEYWORD,
        )
        log(f"created collection '{COLLECTION}'")


def find_markdown(vault: str) -> list[str]:
    out: list[str] = []
    for root, dirs, files in os.walk(vault):
        # Skip Obsidian's own config/plugin state.
        dirs[:] = [d for d in dirs if d != ".obsidian"]
        for name in files:
            if name.endswith(".md"):
                out.append(os.path.join(root, name))
    return out


def index_file(client: QdrantClient, embedder: TextEmbedding, vault: str, abs_path: str) -> None:
    rel_path = os.path.relpath(abs_path, vault)
    with open(abs_path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()

    chunks = chunk_markdown(text)
    if not chunks:
        # Empty note: clear any stale vectors for it and move on.
        delete_file(client, rel_path)
        return

    vectors = list(embedder.embed(chunks))
    points = [
        qm.PointStruct(
            id=point_id(rel_path, i),
            vector=vector.tolist(),
            payload={"path": rel_path, "chunk": i, "text": chunk},
        )
        for i, (chunk, vector) in enumerate(zip(chunks, vectors))
    ]

    # Remove any leftover higher-index chunks from a previous, longer version.
    client.delete(
        collection_name=COLLECTION,
        points_selector=qm.FilterSelector(
            filter=qm.Filter(
                must=[
                    qm.FieldCondition(key="path", match=qm.MatchValue(value=rel_path)),
                    qm.FieldCondition(key="chunk", range=qm.Range(gte=len(chunks))),
                ]
            )
        ),
    )
    client.upsert(collection_name=COLLECTION, points=points)
    log(f"indexed {rel_path} ({len(points)} chunks)")


def delete_file(client: QdrantClient, rel_path: str) -> None:
    client.delete(
        collection_name=COLLECTION,
        points_selector=qm.FilterSelector(
            filter=qm.Filter(
                must=[qm.FieldCondition(key="path", match=qm.MatchValue(value=rel_path))]
            )
        ),
    )
    log(f"removed {rel_path}")


def main() -> None:
    log(f"starting; vault={VAULT_PATH} qdrant={QDRANT_URL} interval={POLL_INTERVAL}s")
    embedder = TextEmbedding(model_name=EMBED_MODEL)
    client = QdrantClient(url=QDRANT_URL)

    # Wait for Qdrant to be reachable before the first pass.
    while True:
        try:
            ensure_collection(client)
            break
        except Exception as exc:  # noqa: BLE001 - startup retry
            log(f"waiting for qdrant: {exc}")
            time.sleep(3)

    # rel_path -> content hash of the last version we indexed.
    seen: dict[str, str] = {}

    while True:
        try:
            current_paths = find_markdown(VAULT_PATH)
            current_rel = set()
            for abs_path in current_paths:
                rel_path = os.path.relpath(abs_path, VAULT_PATH)
                current_rel.add(rel_path)
                with open(abs_path, "rb") as fh:
                    digest = hashlib.sha256(fh.read()).hexdigest()
                if seen.get(rel_path) != digest:
                    index_file(client, embedder, VAULT_PATH, abs_path)
                    seen[rel_path] = digest

            # Handle deletions.
            for rel_path in list(seen.keys()):
                if rel_path not in current_rel:
                    delete_file(client, rel_path)
                    seen.pop(rel_path, None)
        except Exception as exc:  # noqa: BLE001 - keep the loop alive
            log(f"pass failed: {exc}")

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
