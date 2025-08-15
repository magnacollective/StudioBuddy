from fastapi import FastAPI, UploadFile, File, HTTPException, Response, Query, Request
from fastapi.responses import FileResponse, PlainTextResponse, JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from starlette.exceptions import HTTPException as StarletteHTTPException
import tempfile
import os
import shutil
import uuid
from concurrent.futures import ThreadPoolExecutor
from typing import Dict, Optional
import subprocess
import numpy as np
import librosa

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

# Custom exception handler to ensure CORS headers are always present
@app.exception_handler(StarletteHTTPException)
async def http_exception_handler(request: Request, exc: StarletteHTTPException):
    """Custom exception handler that ensures CORS headers are always included"""
    headers = {
        "Access-Control-Allow-Origin": "*" if "*" in ALLOWED_ORIGINS else ",".join(ALLOWED_ORIGINS),
        "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
        "Access-Control-Allow-Headers": "*",
        "Access-Control-Expose-Headers": "*",
    }
    return JSONResponse(
        status_code=exc.status_code,
        content={"detail": exc.detail},
        headers=headers
    )

@app.exception_handler(Exception)
async def general_exception_handler(request: Request, exc: Exception):
    """Handle all other exceptions with CORS headers"""
    print(f"[ERROR] Unhandled exception: {exc}")
    import traceback
    traceback.print_exc()
    
    headers = {
        "Access-Control-Allow-Origin": "*" if "*" in ALLOWED_ORIGINS else ",".join(ALLOWED_ORIGINS),
        "Access-Control-Allow-Methods": "GET, POST, PUT, DELETE, OPTIONS",
        "Access-Control-Allow-Headers": "*",
        "Access-Control-Expose-Headers": "*",
    }
    return JSONResponse(
        status_code=500,
        content={"detail": f"Internal server error: {str(exc)}"},
        headers=headers
    )

@app.get("/")
def root():
    return {"status": "ok", "service": "studiobuddy-mastering", "version": "5.4", "cors": "fixed-file-response", "allowed_origins": ALLOWED_ORIGINS, "timestamp": "2024-08-14-19:30"}

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
    request: Request,
    audio: UploadFile = File(...),
    reference: UploadFile = File(None),
    target_lufs: float = Query(-14.0, description="Target LUFS for output level"),
    max_peak: float = Query(-1.0, description="Maximum peak level in dB"),
):
    print(f"[MASTER] Received request: audio={audio.filename}, reference={reference.filename if reference else None}")
    print(f"[MASTER] Request headers: {dict(request.headers)}")
    
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
            
            # Check file size before processing - increased limits for better compatibility
            if hasattr(audio, 'size') and audio.size:
                if audio.size > 200 * 1024 * 1024:  # 200MB limit (increased from 100MB)
                    raise HTTPException(status_code=400, detail="File too large. Maximum size is 200MB")
                if audio.size < 1024:  # 1KB minimum
                    raise HTTPException(status_code=400, detail="File too small. Minimum size is 1KB")
                
                # Log file size for monitoring
                size_mb = audio.size / (1024 * 1024)
                print(f"[MASTER] Processing file size: {size_mb:.1f}MB")
            
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

            # Check if file exists after processing
            if not os.path.exists(output_path):
                print(f"[MASTER] ERROR: Output file not found at {output_path}")
                raise HTTPException(status_code=500, detail="Mastering failed: output not created")
            
            # Apply volume control and clipping prevention
            print(f"[MASTER] Applying volume control (target LUFS: {target_lufs}, max peak: {max_peak})")
            output_path = _apply_volume_control(output_path, tmpdir, target_lufs, max_peak)
            
            print(f"[MASTER] Returning mastered file from {output_path}")
            print(f"[MASTER] File size: {os.path.getsize(output_path)} bytes")
            
            # Read file content and return as Response instead of FileResponse
            # This avoids issues with temporary directory cleanup
            with open(output_path, "rb") as f:
                content = f.read()
            
            return Response(
                content=content,
                media_type="audio/wav",
                headers={
                    "Content-Disposition": "attachment; filename=mastered.wav",
                    "Content-Length": str(len(content))
                }
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


def _apply_volume_control(input_path: str, workdir: str, target_lufs: float = -14.0, max_peak: float = -1.0) -> str:
    """Apply volume control and clipping prevention to mastered audio."""
    print(f"[_apply_volume_control] Processing {input_path}")
    
    try:
        # Load audio using librosa
        audio, sr = librosa.load(input_path, sr=None, mono=False)
        
        # Ensure stereo format
        if audio.ndim == 1:
            audio = np.stack([audio, audio])
        elif audio.shape[0] > 2:
            audio = audio[:2]  # Take only first 2 channels
        
        # Calculate current peak level
        current_peak = np.max(np.abs(audio))
        current_peak_db = 20 * np.log10(current_peak) if current_peak > 0 else -np.inf
        
        print(f"[_apply_volume_control] Current peak: {current_peak_db:.2f} dB")
        
        # Calculate LUFS using simple RMS approximation
        rms = np.sqrt(np.mean(audio**2))
        current_lufs_approx = 20 * np.log10(rms) - 0.691 if rms > 0 else -np.inf
        
        print(f"[_apply_volume_control] Estimated current LUFS: {current_lufs_approx:.2f}")
        
        # Calculate gain adjustment for LUFS target
        lufs_gain_db = target_lufs - current_lufs_approx
        
        # Calculate gain adjustment for peak limiting
        peak_gain_db = max_peak - current_peak_db
        
        # Use the more restrictive gain (smaller value)
        final_gain_db = min(lufs_gain_db, peak_gain_db)
        
        # Limit gain adjustment to reasonable range
        final_gain_db = np.clip(final_gain_db, -20, 6)
        
        print(f"[_apply_volume_control] Applying gain: {final_gain_db:.2f} dB")
        
        # Apply gain
        gain_linear = 10**(final_gain_db / 20)
        audio_adjusted = audio * gain_linear
        
        # Apply soft limiting to prevent clipping
        audio_limited = _soft_limit(audio_adjusted, threshold=0.95)
        
        # Verify final peak level
        final_peak = np.max(np.abs(audio_limited))
        final_peak_db = 20 * np.log10(final_peak) if final_peak > 0 else -np.inf
        
        print(f"[_apply_volume_control] Final peak: {final_peak_db:.2f} dB")
        
        # Save processed audio
        output_path = os.path.join(workdir, "mastered_controlled.wav")
        
        # Convert back to int16 and save using scipy
        import soundfile as sf
        audio_int16 = (audio_limited * 32767).astype(np.int16)
        sf.write(output_path, audio_int16.T, sr, subtype='PCM_16')
        
        return output_path
        
    except Exception as e:
        print(f"[_apply_volume_control] Error: {e}")
        # Return original path if processing fails
        return input_path


def _soft_limit(audio: np.ndarray, threshold: float = 0.95) -> np.ndarray:
    """Apply soft limiting to prevent clipping."""
    # Simple tanh-based soft limiter
    mask = np.abs(audio) > threshold
    limited = np.where(mask, 
                      np.sign(audio) * (threshold + (1 - threshold) * np.tanh((np.abs(audio) - threshold) / (1 - threshold))),
                      audio)
    return limited


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


