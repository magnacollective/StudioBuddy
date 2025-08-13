from fastapi import FastAPI, UploadFile, File, HTTPException, Response
from fastapi.responses import FileResponse, PlainTextResponse
import tempfile
import os
import shutil
import matchering as mg

app = FastAPI(title="StudioBuddy Matchering API")


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
        except mg.log.ModuleError as e:  # type: ignore[attr-defined]
            # Matchering provides detailed errors
            raise HTTPException(status_code=400, detail=str(e))
        except Exception as e:
            raise HTTPException(status_code=500, detail=str(e))


