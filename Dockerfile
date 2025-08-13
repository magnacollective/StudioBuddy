# syntax=docker/dockerfile:1
FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libsndfile1 \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install heavy deps first to optimize cold starts
COPY backend/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir numpy>=1.23.4 scipy>=1.9.2 soundfile>=0.12.1 resampy>=0.4.2 statsmodels>=0.13.2 && \
    pip install --no-cache-dir -r /app/requirements.txt

COPY backend /app

ENV PORT=8080
EXPOSE 8080

CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port ${PORT:-8080}"]


