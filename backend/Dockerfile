# syntax=docker/dockerfile:1
FROM python:3.11-slim

# System deps for audio processing and building wheels
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libsndfile1 \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY backend/requirements.txt /app/requirements.txt
# Separate heavy deps to optimize layer caching
RUN pip install --no-cache-dir numpy>=1.23.4 scipy>=1.9.2 soundfile>=0.12.1 resampy>=0.4.2 statsmodels>=0.13.2 && \
    pip install --no-cache-dir -r /app/requirements.txt

COPY backend /app

ENV PORT=8080
EXPOSE 8080

# Use $PORT from Railway if provided
CMD ["sh", "-c", "uvicorn main:app --host 0.0.0.0 --port ${PORT:-8080}"]


