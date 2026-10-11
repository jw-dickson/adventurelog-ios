# AdventureLog companion — build from the repository root:
#   docker build -f Companion/Dockerfile -t adventurelog-companion .
FROM python:3.13-slim

RUN useradd --create-home --uid 10001 companion && mkdir /data && chown companion /data
WORKDIR /app
COPY Companion/pyproject.toml ./
RUN pip install --no-cache-dir "fastapi>=0.115" "uvicorn>=0.30" "httpx[http2]>=0.27" "pyjwt[crypto]>=2.9"
COPY Companion/companion ./companion

USER companion
VOLUME /data
EXPOSE 8080
ENV COMPANION_DB=/data/companion.sqlite
CMD ["uvicorn", "companion.app:create_app", "--factory", "--host", "0.0.0.0", "--port", "8080"]
