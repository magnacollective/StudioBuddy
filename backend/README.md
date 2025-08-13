## StudioBuddy Matchering Backend (FastAPI + Docker)

This service exposes a simple HTTP API to master a target audio file using a reference track via the Python Matchering library. Designed for deployment on Railway using the provided Dockerfile.

### Endpoints
- POST `/master` — multipart form with fields `target` and `reference` (files). Returns a mastered WAV file.
- GET `/health` — health check.

### Quick start (local)
```bash
docker build -t studiobuddy-matchering-backend .
docker run --rm -p 8080:8080 studiobuddy-matchering-backend
# In another shell
curl -f -X POST \
  -F target=@/path/to/your_mix.wav \
  -F reference=@/path/to/reference.wav \
  http://localhost:8080/master -o mastered.wav
```

### Deploy to Railway
1. Push this repo to GitHub.
2. In Railway, create a new project from the repo. It will auto-detect the Dockerfile.
3. Set the service port to `8080` (default in `uvicorn` command).
4. Deploy and use the generated domain.

### Notes
- ffmpeg and libsndfile are installed in the image. If inputs are compressed (mp3/m4a), Matchering will convert them via ffmpeg.
- The endpoint processes synchronously for simplicity. For long tracks and high traffic, consider an async job queue.


