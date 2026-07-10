FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY indexer.py .

# fastembed downloads its ONNX model on first run; keep the cache inside the
# image layer's writable space at runtime.
ENV FASTEMBED_CACHE_PATH=/app/.fastembed_cache

CMD ["python", "-u", "indexer.py"]
