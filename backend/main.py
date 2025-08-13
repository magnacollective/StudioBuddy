from fastapi import FastAPI, UploadFile, File, HTTPException, Response, Query
from fastapi.responses import FileResponse, PlainTextResponse, JSONResponse
import tempfile
import os
import shutil
import uuid
from concurrent.futures import ThreadPoolExecutor
from typing import Dict, Optional

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
            target_path = os.path.join(tmpdir, target.filename or "target")
            reference_path = os.path.join(tmpdir, reference.filename or "reference")
            output_path = os.path.join(tmpdir, "mastered.wav")

            # Save uploads to disk
            with open(target_path, "wb") as f:
                shutil.copyfileobj(target.file, f)
            with open(reference_path, "wb") as f:
                shutil.copyfileobj(reference.file, f)

            # Process via Matchering
            mg.log(print)
            mg.process(
                target=target_path,
                reference=reference_path,
                results=[mg.pcm16(output_path)],
            )

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
        import matchering as mg  # type: ignore
        JOBS[job_id]["status"] = "running"
        mg.log(print)
        mg.process(
            target=target_path,
            reference=reference_path,
            results=[mg.pcm16(output_path)],
        )
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
    return {"status": job.get("status"), "message": job.get("message")}


@app.get("/master/result")
def master_result(id: str = Query(..., alias="id")):
    job = JOBS.get(id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    if job.get("status") != "done" or not job.get("output_path"):
        raise HTTPException(status_code=400, detail="Job not completed")
    return FileResponse(job["output_path"], media_type="audio/wav", filename="mastered.wav")


