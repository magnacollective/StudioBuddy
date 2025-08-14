from fastapi import FastAPI, UploadFile, File, HTTPException, Response, Query, Request
from fastapi.responses import FileResponse, PlainTextResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
import tempfile
import os
import shutil
import uuid
from concurrent.futures import ThreadPoolExecutor
from typing import Dict, Optional
import subprocess

app = FastAPI(title="StudioBuddy Matchering API")

# Get allowed origins from environment variable
ALLOWED_ORIGINS = os.getenv("ALLOWED_ORIGINS", "*").split(",")
print(f"[CORS] Allowed origins: {ALLOWED_ORIGINS}")

# Add standard CORS middleware first
app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Manual CORS middleware as backup
@app.middleware("http")
async def cors_handler(request: Request, call_next):
    # Handle preflight requests immediately
    if request.method == "OPTIONS":
        return Response(
            status_code=200,
            headers={
                "Access-Control-Allow-Origin": "*" if "*" in ALLOWED_ORIGINS else ",".join(ALLOWED_ORIGINS),
                "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
                "Access-Control-Allow-Headers": "*",
                "Access-Control-Max-Age": "86400",
            }
        )
    
    response = await call_next(request)
    
    # Add CORS headers to every response
    response.headers["Access-Control-Allow-Origin"] = "*" if "*" in ALLOWED_ORIGINS else ",".join(ALLOWED_ORIGINS)
    response.headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, DELETE, OPTIONS"
    response.headers["Access-Control-Allow-Headers"] = "*"
    response.headers["Access-Control-Expose-Headers"] = "*"
    
    return response

@app.get("/")
def root():
    return {"status": "ok", "service": "studiobuddy-mastering", "version": "5.2", "cors": "fixed-ffmpeg", "allowed_origins": ALLOWED_ORIGINS, "timestamp": "2024-08-14-18:45"}

@app.get("/test")
def test():
    return {"message": "Mastering API is working!", "timestamp": "2024-08-14"}

@app.post("/test-post")
async def test_post(audio: UploadFile = File(...)):
    return {"message": "POST request successful", "filename": audio.filename, "size": audio.size}

@app.post("/test-cors")
async def test_cors():
    """Simple POST endpoint to test CORS without file upload"""
    return {"message": "CORS POST test successful", "timestamp": "2024-08-14"}


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
    print(f"[MASTER] Received request: audio={audio.filename}, reference={reference.filename if reference else None}")
    
    # Create a temp working directory
    with tempfile.TemporaryDirectory() as tmpdir:
        try:
            print("[MASTER] Importing matchering library...")
            # Lazy import to speed up cold start
            import matchering as mg  # type: ignore
            print("[MASTER] Matchering import successful")
            
            # Validate file
            if not audio.filename:
                raise HTTPException(status_code=400, detail="No filename provided")
            
            # Check file size before processing
            if hasattr(audio, 'size') and audio.size:
                if audio.size > 100 * 1024 * 1024:  # 100MB limit
                    raise HTTPException(status_code=400, detail="File too large. Maximum size is 100MB")
                if audio.size < 1024:  # 1KB minimum
                    raise HTTPException(status_code=400, detail="File too small. Minimum size is 1KB")
            
            # Check file extension
            allowed_extensions = ['.mp3', '.wav', '.flac', '.ogg', '.m4a', '.aac', '.wma']
            file_ext = os.path.splitext(audio.filename.lower())[1]
            if file_ext not in allowed_extensions:
                raise HTTPException(status_code=400, detail=f"Unsupported file format {file_ext}. Supported: {', '.join(allowed_extensions)}")
            
            target_upload = os.path.join(tmpdir, audio.filename or "target")
            output_path = os.path.join(tmpdir, "mastered.wav")

            print(f"[MASTER] Saving uploaded file: {audio.filename}")
            # Save audio file to disk
            with open(target_upload, "wb") as f:
                shutil.copyfileobj(audio.file, f)
            
            saved_size = os.path.getsize(target_upload)
            print(f"[MASTER] Saved file size: {saved_size} bytes")

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

            # Return file (CORS headers added by middleware)
            return FileResponse(
                output_path,
                media_type="audio/wav",
                filename="mastered.wav",
            )
        except Exception as e:
            print(f"[ERROR] Mastering failed: {e}")
            import traceback
            traceback.print_exc()
            raise HTTPException(status_code=500, detail=f"Mastering error: {str(e)}")


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
    print(f"[_to_wav] Converting {input_path}")
    
    # Validate input file exists and has content
    if not os.path.exists(input_path):
        raise HTTPException(status_code=400, detail=f"Input file does not exist: {input_path}")
    
    file_size = os.path.getsize(input_path)
    print(f"[_to_wav] Input file size: {file_size} bytes")
    
    if file_size == 0:
        raise HTTPException(status_code=400, detail="Uploaded file is empty")
    
    if file_size < 1024:  # Less than 1KB is probably not a valid audio file
        raise HTTPException(status_code=400, detail="Uploaded file is too small to be a valid audio file")
    
    base, ext = os.path.splitext(os.path.basename(input_path))
    output_path = os.path.join(workdir, f"{base}.wav")
    
    # If input is already a .wav at the same path, write to a different filename
    if ext.lower() in {".wav", ".wave"} and os.path.abspath(input_path) == os.path.abspath(output_path):
        output_path = os.path.join(workdir, f"{base}.converted.wav")
    
    # First, probe the file to check if it's valid audio
    probe_cmd = [
        "ffmpeg",
        "-hide_banner",
        "-nostdin",
        "-i", input_path,
        "-f", "null",
        "-"
    ]
    
    try:
        print(f"[_to_wav] Probing audio file...")
        result = subprocess.run(probe_cmd, capture_output=True, text=True, timeout=10)
        if result.returncode != 0:
            print(f"[_to_wav] Probe failed: {result.stderr}")
            raise HTTPException(status_code=400, detail=f"Invalid audio file format or corrupted file. Error: {result.stderr[-200:]}")
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=400, detail="Audio file validation timed out - file may be corrupted")
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Failed to validate audio file: {str(e)}")
    
    # Now convert to WAV
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-nostdin",
        "-y",
        "-loglevel",
        "error",  # Only show errors
        "-err_detect",
        "ignore_err",
        "-i",
        input_path,
        "-vn",  # No video
        "-ac",
        "2",    # Stereo
        "-ar",
        "44100", # 44.1kHz
        "-c:a",
        "pcm_s16le",  # 16-bit PCM
        "-f", "wav",  # Force WAV format
        output_path,
    ]
    
    print(f"[_to_wav] Converting with command: {' '.join(cmd)}")
    
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode != 0:
            print(f"[_to_wav] Conversion failed: {result.stderr}")
            raise HTTPException(status_code=400, detail=f"Audio conversion failed: {result.stderr[-200:]}")
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=400, detail="Audio conversion timed out - file may be too large or corrupted")
    except Exception as e:
        raise HTTPException(status_code=400, detail=f"Conversion error: {str(e)}")
    
    if not os.path.exists(output_path):
        raise HTTPException(status_code=400, detail="Audio conversion completed but output file was not created")
    
    output_size = os.path.getsize(output_path)
    print(f"[_to_wav] Conversion successful, output size: {output_size} bytes")
    
    if output_size == 0:
        raise HTTPException(status_code=400, detail="Audio conversion produced empty file")
    
    return output_path


@app.post("/analyze")
async def analyze_audio(audio: UploadFile = File(...)):
    """Analyze uploaded audio file for BPM and key detection.
    Returns: {"bpm": float, "key": string, "duration": float, "sample_rate": int}
    """
    print(f"[analyze] Received file: {audio.filename}")
    
    with tempfile.TemporaryDirectory() as tmpdir:
        try:
            # Save uploaded file
            input_path = os.path.join(tmpdir, audio.filename or "audio")
            with open(input_path, "wb") as f:
                shutil.copyfileobj(audio.file, f)
            
            # Convert to WAV using existing function
            wav_path = _to_wav(input_path, tmpdir)
            print(f"[analyze] Converted to WAV: {wav_path}")
            
            # For now, return mock data
            # TODO: Integrate actual BPM/key analysis library
            analysis_result = {
                "bpm": 128.0,
                "key": "A Minor", 
                "duration": "3:24",
                "sample_rate": "44.1 kHz"
            }
            
            print(f"[analyze] Mock analysis complete: {analysis_result}")
            return analysis_result
            
        except Exception as e:
            print(f"[analyze] Error: {e}")
            raise HTTPException(status_code=500, detail=f"Analysis failed: {str(e)}")


