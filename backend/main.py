from fastapi import FastAPI, UploadFile, File, HTTPException, Response, Query
from fastapi.responses import FileResponse, PlainTextResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
import tempfile
import os
import shutil
import uuid
from concurrent.futures import ThreadPoolExecutor
from typing import Dict, Optional
import subprocess
import math
import numpy as np
import soundfile as sf  # type: ignore
import resampy  # type: ignore
from math import log2

app = FastAPI(title="StudioBuddy Matchering API")

# Add CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["https://studio-buddy-web.vercel.app"],
    allow_credentials=True,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)

@app.get("/")
def root():
    return {"status": "ok"}


# Simple in-memory job store (prototype)
executor = ThreadPoolExecutor(max_workers=1)
JOBS: Dict[str, Dict[str, Optional[str]]] = {}


@app.get("/health", response_class=PlainTextResponse)
def health() -> str:
    return "ok"


@app.post("/master")
async def master_audio(
    audio: UploadFile = File(...),
    reference: UploadFile = File(None),
):
    # Create a temp working directory
    with tempfile.TemporaryDirectory() as tmpdir:
        try:
            # Lazy import to speed up cold start
            import matchering as mg  # type: ignore
            target_upload = os.path.join(tmpdir, audio.filename or "target")
            output_path = os.path.join(tmpdir, "mastered.wav")

            # Save audio file to disk
            with open(target_upload, "wb") as f:
                shutil.copyfileobj(audio.file, f)

            # Pre-convert to WAV with ffmpeg to handle odd headers/corruption
            t_wav = _to_wav(target_upload, tmpdir)
            
            # Handle reference file
            if reference and reference.filename:
                reference_upload = os.path.join(tmpdir, reference.filename or "reference")
                with open(reference_upload, "wb") as f:
                    shutil.copyfileobj(reference.file, f)
                r_wav = _to_wav(reference_upload, tmpdir)
            else:
                # Use the audio file as both target and reference for auto-mastering
                r_wav = t_wav

            # Process via Matchering
            from importlib import import_module  # late import
            mg = import_module("matchering")
            mg.log(print)
            mg.process(target=t_wav, reference=r_wav, results=[mg.pcm16(output_path)])

            if not os.path.exists(output_path):
                raise HTTPException(status_code=500, detail="Mastering failed: output not created")

            # Return file
            return FileResponse(
                output_path,
                media_type="audio/wav",
                filename="mastered.wav",
            )
        except Exception as e:
            raise HTTPException(status_code=500, detail=str(e))


def _run_matchering_job(tmpdir: str, target_path: str, reference_path: str, output_path: str, job_id: str) -> None:
    try:
        from importlib import import_module
        mg = import_module("matchering")
        JOBS[job_id]["status"] = "running"
        mg.log(print)
        # Pre-convert to WAV with ffmpeg first
        t_wav = _to_wav(target_path, tmpdir)
        r_wav = _to_wav(reference_path, tmpdir)
        mg.process(target=t_wav, reference=r_wav, results=[mg.pcm16(output_path)])
        if os.path.exists(output_path):
            JOBS[job_id]["status"] = "done"
            JOBS[job_id]["output_path"] = output_path
        else:
            JOBS[job_id]["status"] = "error"
            JOBS[job_id]["message"] = "Output not created"
    except Exception as e:
        JOBS[job_id]["status"] = "error"
        JOBS[job_id]["message"] = str(e)


@app.post("/master/start")
async def master_start(
    target: UploadFile = File(...),
    reference: UploadFile = File(...),
):
    tmpdir = tempfile.mkdtemp(prefix="job-")
    job_id = uuid.uuid4().hex
    JOBS[job_id] = {"status": "queued", "message": None, "output_path": None, "tmpdir": tmpdir}

    target_path = os.path.join(tmpdir, target.filename or "target")
    reference_path = os.path.join(tmpdir, reference.filename or "reference")
    output_path = os.path.join(tmpdir, "mastered.wav")

    with open(target_path, "wb") as f:
        shutil.copyfileobj(target.file, f)
    with open(reference_path, "wb") as f:
        shutil.copyfileobj(reference.file, f)

    executor.submit(_run_matchering_job, tmpdir, target_path, reference_path, output_path, job_id)
    return {"job_id": job_id}


@app.get("/master/status")
def master_status(id: str = Query(..., alias="id")):
    job = JOBS.get(id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    return {
        "status": job.get("status"),
        "message": job.get("message"),
        "has_output": os.path.exists(job.get("output_path") or "") if job.get("output_path") else False,
    }


@app.get("/master/result")
def master_result(id: str = Query(..., alias="id")):
    job = JOBS.get(id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    if job.get("status") != "done" or not job.get("output_path"):
        raise HTTPException(status_code=400, detail="Job not completed")
    return FileResponse(job["output_path"], media_type="audio/wav", filename="mastered.wav")


# Utilities
def _to_wav(input_path: str, workdir: str) -> str:
    """Convert any input audio to 44.1kHz 16-bit stereo WAV using ffmpeg, with tolerant flags."""
    base, ext = os.path.splitext(os.path.basename(input_path))
    output_path = os.path.join(workdir, f"{base}.wav")
    # If input is already a .wav at the same path, write to a different filename
    if ext.lower() in {".wav", ".wave"} and os.path.abspath(input_path) == os.path.abspath(output_path):
        output_path = os.path.join(workdir, f"{base}.converted.wav")
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-nostdin",
        "-y",
        "-loglevel",
        "warning",
        "-err_detect",
        "ignore_err",
        "-i",
        input_path,
        "-vn",
        "-ac",
        "2",
        "-ar",
        "44100",
        "-c:a",
        "pcm_s16le",
        output_path,
    ]
    try:
        subprocess.check_call(cmd)
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=400, detail=f"ffmpeg failed to convert input: {e}")
    if not os.path.exists(output_path):
        raise HTTPException(status_code=400, detail="ffmpeg did not produce output wav")
    return output_path


@app.post("/analyze/bpm-key")
async def analyze_bpm_key(audio: UploadFile = File(...)):
    """Analyze uploaded audio and return estimated BPM and musical key.
    Accepts any audio; converts to WAV via ffmpeg first for robustness.
    Response: { "bpm": float, "key": str }
    """
    print(f"[analyze] Received file: {audio.filename}")
    with tempfile.TemporaryDirectory() as tmpdir:
        try:
            # Save upload
            input_path = os.path.join(tmpdir, audio.filename or "audio")
            with open(input_path, "wb") as f:
                shutil.copyfileobj(audio.file, f)

            # Convert to WAV
            wav_path = _to_wav(input_path, tmpdir)
            print(f"[analyze] Converted to wav: {wav_path}")

            # Load samples
            y, sr = sf.read(wav_path, dtype="float32", always_2d=False)
            if y.ndim == 2:
                y = y.mean(axis=1)
            # Resample to a stable rate for analysis
            target_sr = 22050
            if sr != target_sr:
                y = resampy.resample(y, sr, target_sr)
                sr = target_sr
            print(f"[analyze] Samples: {len(y)}, sr: {sr}")

            bpm = _estimate_bpm(y, sr)
            key = _estimate_key(y, sr)
            print(f"[analyze] Estimated BPM: {bpm}, Key: {key}")

            return JSONResponse({"bpm": float(round(bpm, 1)), "key": key})
        except HTTPException:
            raise
        except Exception as e:
            print(f"[analyze] Error: {e}")
            raise HTTPException(status_code=500, detail=str(e))


def _stft_mag(y: np.ndarray, sr: int, n_fft: int = 2048, hop_length: int = 512) -> np.ndarray:
    # Hann window STFT
    window = np.hanning(n_fft).astype(np.float32)
    num_frames = 1 + max(0, (len(y) - n_fft) // hop_length)
    if num_frames <= 0:
        return np.empty((n_fft // 2 + 1, 0), dtype=np.float32)
    S = np.empty((n_fft // 2 + 1, num_frames), dtype=np.float32)
    for i in range(num_frames):
        start = i * hop_length
        frame = y[start:start + n_fft]
        if len(frame) < n_fft:
            pad = np.zeros(n_fft - len(frame), dtype=np.float32)
            frame = np.concatenate([frame, pad])
        frame = frame * window
        spec = np.fft.rfft(frame, n=n_fft)
        S[:, i] = np.abs(spec)
    return S


def _estimate_bpm(y: np.ndarray, sr: int) -> float:
    n_fft = 2048
    hop = 512
    S = _stft_mag(y, sr, n_fft=n_fft, hop_length=hop)
    if S.shape[1] < 4:
        return 120.0
    # Spectral flux onset envelope
    flux = np.maximum(0.0, np.diff(S, axis=1))
    onset_env = flux.sum(axis=0)
    # Normalize
    if onset_env.max() > 0:
        onset_env = onset_env / onset_env.max()
    onset_env = onset_env - onset_env.mean()
    # Autocorrelation
    acf = np.correlate(onset_env, onset_env, mode='full')[onset_env.size - 1:]
    # Map BPM range to lags (in frames)
    min_bpm, max_bpm = 60.0, 200.0
    min_lag = int(round(sr * 60.0 / (max_bpm * hop)))
    max_lag = int(round(sr * 60.0 / (min_bpm * hop)))
    if max_lag <= min_lag or max_lag >= acf.size:
        return 120.0
    search = acf[min_lag:max_lag]
    best_idx = int(np.argmax(search)) + min_lag
    bpm = 60.0 * sr / (best_idx * hop)
    # Consider octave errors (x2, /2)
    candidates = [bpm / 2, bpm, bpm * 2]
    candidates = [c for c in candidates if 60 <= c <= 200]
    if not candidates:
        return float(bpm)
    # Prefer the one whose lag peak is strongest
    def lag_for(b: float) -> int:
        return int(round(sr * 60.0 / (b * hop)))
    strengths = [acf[lag_for(c)] if lag_for(c) < acf.size else -np.inf for c in candidates]
    return float(candidates[int(np.argmax(strengths))])


def _estimate_key(y: np.ndarray, sr: int) -> str:
    n_fft = 4096
    hop = n_fft // 2
    S = _stft_mag(y, sr, n_fft=n_fft, hop_length=hop)
    if S.shape[1] == 0:
        return "C Major"
    # Map frequency bins to pitch classes (12-TET)
    freqs = np.linspace(0, sr / 2, S.shape[0], dtype=np.float32)
    chroma = np.zeros(12, dtype=np.float32)
    for b, f in enumerate(freqs):
        if f < 80 or f > 2000:
            continue
        # MIDI note number
        midi = 69 + 12 * log2(max(f, 1e-6) / 440.0)
        pc = int(round(midi)) % 12
        chroma[pc] += S[b, :].mean()
    # Normalize
    if chroma.sum() > 0:
        chroma = chroma / chroma.sum()
    # Krumhansl-Schmuckler profiles
    major = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88], dtype=np.float32)
    minor = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17], dtype=np.float32)
    keys = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    def corr(a, b):
        a = (a - a.mean())
        b = (b - b.mean())
        den = (np.linalg.norm(a) * np.linalg.norm(b))
        return float((a @ b) / den) if den > 0 else -1
    best_name = "C Major"
    best_score = -1.0
    for i in range(12):
        maj = np.roll(major, i)
        minr = np.roll(minor, i)
        smaj = corr(chroma, maj)
        smin = corr(chroma, minr)
        if smaj > best_score:
            best_score = smaj
            best_name = f"{keys[i]} Major"
        if smin > best_score:
            best_score = smin
            best_name = f"{keys[i]} Minor"
    return best_name


