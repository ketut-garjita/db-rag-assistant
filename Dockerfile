FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

# Pre-download embedding + re-ranking models during image build.
ARG EMBEDDING_MODEL=all-MiniLM-L6-v2
ARG RERANKER_MODEL=cross-encoder/ms-marco-MiniLM-L-6-v2

RUN python -c "\
from sentence_transformers import SentenceTransformer, CrossEncoder; \
SentenceTransformer('${EMBEDDING_MODEL}'); \
CrossEncoder('${RERANKER_MODEL}')"

# Copy application source, including:
#   app/
#   rag/
#   evaluation/
#   data/
#   config.py
#   etc.
COPY . .

EXPOSE 8501

CMD ["streamlit", "run", "app/streamlit_app.py", "--server.address=0.0.0.0"]
