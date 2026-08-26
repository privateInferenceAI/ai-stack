#!/usr/bin/env python3
"""
Document ingestion for the AI stack document brain.
Reads PDFs/DOCX from /documents/<acl_folder>/, chunks, embeds, stores in Qdrant with ACL tags.
Usage: python3 ingest.py
Idempotent: re-running re-embeds and overwrites by document name (safe to re-run).
"""
import os, sys, uuid, glob
import requests

# --- Config (from environment) ---
QDRANT_URL = os.environ.get("QDRANT_URL", "http://qdrant:6333")
QDRANT_API_KEY = os.environ["QDRANT_API_KEY"]
EMBED_URL = os.environ.get("EMBED_URL", "http://embeddings:80")
COLLECTION = "company_docs"
DOCS_ROOT = "/documents"
CHUNK_SIZE = 512        # characters per chunk (simple char chunking)
CHUNK_OVERLAP = 64
VECTOR_SIZE = 1024      # bge-m3 output dimension

HEADERS = {"api-key": QDRANT_API_KEY, "Content-Type": "application/json"}

def extract_text(path):
    """Pull raw text from PDF or DOCX."""
    ext = path.lower().rsplit(".", 1)[-1]
    if ext == "pdf":
        from pypdf import PdfReader
        reader = PdfReader(path)
        return "\n".join(page.extract_text() or "" for page in reader.pages)
    elif ext in ("docx",):
        import docx
        doc = docx.Document(path)
        return "\n".join(p.text for p in doc.paragraphs)
    elif ext in ("txt", "md"):
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            return f.read()
    else:
        print(f"  SKIP (unsupported type): {path}")
        return None

def chunk_text(text):
    """Simple overlapping character chunker. Not fancy, works fine for business docs."""
    chunks = []
    start = 0
    while start < len(text):
        end = start + CHUNK_SIZE
        chunk = text[start:end].strip()
        if chunk:
            chunks.append(chunk)
        start = end - CHUNK_OVERLAP
    return chunks

def embed(texts):
    """Embed a list of strings via the TEI embeddings service."""
    resp = requests.post(f"{EMBED_URL}/embed", json={"inputs": texts}, timeout=120)
    resp.raise_for_status()
    return resp.json()

def ensure_collection():
    """Create the collection if it doesn't exist."""
    r = requests.get(f"{QDRANT_URL}/collections/{COLLECTION}", headers=HEADERS, timeout=30)
    if r.status_code == 200:
        return
    payload = {"vectors": {"size": VECTOR_SIZE, "distance": "Cosine"}}
    r = requests.put(f"{QDRANT_URL}/collections/{COLLECTION}", headers=HEADERS, json=payload, timeout=30)
    r.raise_for_status()
    print(f"Created collection '{COLLECTION}' (size={VECTOR_SIZE}, cosine)")

def doc_point_id(filename, chunk_index):
    """Deterministic UUID from filename+chunk so re-runs overwrite instead of duplicate."""
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, f"{filename}:{chunk_index}"))

def ingest_file(path, acl):
    filename = os.path.basename(path)
    print(f"Ingesting [{acl}] {filename} ...")
    text = extract_text(path)
    if not text or not text.strip():
        print(f"  SKIP (no text extracted): {filename}")
        return 0
    chunks = chunk_text(text)
    if not chunks:
        print(f"  SKIP (no chunks): {filename}")
        return 0
    vectors = embed(chunks)
    points = []
    for i, (chunk, vec) in enumerate(zip(chunks, vectors)):
        points.append({
            "id": doc_point_id(filename, i),
            "vector": vec,
            "payload": {
                "source": filename,
                "chunk_index": i,
                "acl": acl,
                "text": chunk,
            },
        })
    # Upsert in batches of 64
    for i in range(0, len(points), 64):
        batch = points[i:i+64]
        r = requests.put(f"{QDRANT_URL}/collections/{COLLECTION}/points?wait=true",
                         headers=HEADERS, json={"points": batch}, timeout=120)
        r.raise_for_status()
    print(f"  OK: {len(points)} chunks from {filename}")
    return len(points)

def main():
    ensure_collection()
    total = 0
    for acl in ("company", "executive"):
        folder = os.path.join(DOCS_ROOT, acl)
        for path in sorted(glob.glob(os.path.join(folder, "*.*"))):
            try:
                total += ingest_file(path, acl)
            except Exception as e:
                print(f"  ERROR on {path}: {e}", file=sys.stderr)
    print(f"\nDone. Total chunks upserted: {total}")
    # Show collection stats
    r = requests.get(f"{QDRANT_URL}/collections/{COLLECTION}", headers=HEADERS, timeout=30)
    info = r.json().get("result", {})
    print(f"Collection points count: {info.get('points_count')}")

if __name__ == "__main__":
    main()