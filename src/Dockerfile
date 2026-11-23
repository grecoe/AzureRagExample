# One image serves both roles: RAG_ROLE=api (Container App) or RAG_ROLE=ingest (Job).
# Build context is the azure-rag-example folder so sample-data can be included.
# For production, pin the base image by digest: python:3.12-slim-bookworm@sha256:<digest>
FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# git is needed only when RAG_SOURCE_KIND=git.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app
COPY src/requirements.txt ./
RUN pip install -r requirements.txt

COPY src/rag ./rag
COPY src/main.py ./
COPY sample-data ./sample-data

USER 10001
EXPOSE 8080
ENTRYPOINT ["python", "main.py"]
