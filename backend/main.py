from fastapi import FastAPI, UploadFile, File, HTTPException, Response, Query
from fastapi.responses import FileResponse, PlainTextResponse, JSONResponse
import tempfile
import os
import shutil
import uuid
from concurrent.futures import ThreadPoolExecutor
from typing import Dict, Optional
import subprocess
import math
import numpy as np

app = FastAPI(title="StudioBuddy Matchering API")

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
    target: UploadFile = File(...),
    reference: UploadFile = File(...),
):
    # Create a temp working directory
    with tempfile.TemporaryDirectory() as tmpdir:
        try:
            # Lazy import to speed up cold start
            import matchering as mg  # type: ignore
            target_upload = os.path.join(tmpdir, target.filename or "target")
            reference_upload = os.path.join(tmpdir, reference.filename or "reference")
            output_path = os.path.join(tmpdir, "mastered.wav")

            # Save uploads to disk
            with open(target_upload, "wb") as f:
                shutil.copyfileobj(target.file, f)
            with open(reference_upload, "wb") as f:
                shutil.copyfileobj(reference.file, f)

            # Pre-convert to WAV with ffmpeg to handle odd headers/corruption
            t_wav = _to_wav(target_upload, tmpdir)
            r_wav = _to_wav(reference_upload, tmpdir)

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
    """Return BPM and musical key for an uploaded audio file.
    Uses aubio for tempo estimation and a lightweight chroma+Krumhansl method for key.
    """
    with tempfile.TemporaryDirectory() as tmpdir:
        in_path = os.path.join(tmpdir, audio.filename or "audio")
        with open(in_path, "wb") as f:
            shutil.copyfileobj(audio.file, f)
        wav_path = _to_wav(in_path, tmpdir)

        try:
            from importlib import import_module
            sf = import_module("soundfile")
            aubio = import_module("aubio")

            # Read a slice for key analysis (up to 60s)
            y, sr = sf.read(wav_path, always_2d=False)
            if y.ndim > 1:
                y = y.mean(axis=1)
            max_seconds = 60
            if len(y) > sr * max_seconds:
                y = y[: sr * max_seconds]

            bpm = _estimate_bpm_with_aubio(wav_path)
            key = _estimate_key_chroma(y, sr)

            return {"bpm": bpm, "key": key}
        except Exception as e:
            raise HTTPException(status_code=500, detail=str(e))


def _estimate_bpm_with_aubio(wav_path: str) -> float:
    """Estimate BPM using aubio tempo by beat interval median."""
    from importlib import import_module
    aubio = import_module("aubio")
    samplerate = 0
    win_s = 1024
    hop_s = 512
    s = aubio.source(wav_path, samplerate, hop_s)
    samplerate = s.samplerate
    o = aubio.tempo("default", win_s, hop_s, samplerate)
    beats = []
    total_frames = 0
    while True:
        samples, read = s()
        is_beat = o(samples)
        if is_beat:
            beats.append(o.get_last_s())
        total_frames += read
        if read < hop_s:
            break
    if len(beats) >= 2:
        intervals = np.diff(np.array(beats))
        intervals = intervals[intervals > 1e-3]
        if len(intervals) > 0:
            bpm = float(60.0 / np.median(intervals))
            return max(40.0, min(220.0, bpm))
    return 120.0


def _estimate_key_chroma(y: np.ndarray, sr: int) -> str:
    """Estimate musical key via simple chroma and Krumhansl profiles."""
    # STFT
    n_fft = 4096
    hop = 2048
    window = np.hanning(n_fft)
    chroma = np.zeros(12, dtype=np.float64)
    for start in range(0, max(0, len(y) - n_fft), hop):
        frame = y[start : start + n_fft]
        if frame.shape[0] < n_fft:
            break
        spec = np.fft.rfft(frame * window)
        mag = np.abs(spec)
        freqs = np.fft.rfftfreq(n_fft, 1.0 / sr)
        # Map bins to pitch classes
        for k, f in enumerate(freqs):
            if f < 27.5:  # below A0 discard
                continue
            midi = 69 + 12 * math.log2(f / 440.0)
            pc = int(round(midi)) % 12
            chroma[pc] += mag[k]
    if chroma.sum() == 0:
        return "Unknown"
    chroma = chroma / chroma.max()
    # Krumhansl-Kessler key profiles
    major_prof = np.array([6.35,2.23,3.48,2.33,4.38,4.09,2.52,5.19,2.39,3.66,2.29,2.88])
    minor_prof = np.array([6.33,2.68,3.52,5.38,2.60,3.53,2.54,4.75,3.98,2.69,3.34,3.17])
    major_scores = [np.corrcoef(chroma, np.roll(major_prof, i))[0,1] for i in range(12)]
    minor_scores = [np.corrcoef(chroma, np.roll(minor_prof, i))[0,1] for i in range(12)]
    maj_idx = int(np.argmax(major_scores))
    min_idx = int(np.argmax(minor_scores))
    if max(major_scores) >= max(minor_scores):
        scale = "major"
        tonic = maj_idx
    else:
        scale = "minor"
        tonic = min_idx
    names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
    return f"{names[tonic]} {scale}"


