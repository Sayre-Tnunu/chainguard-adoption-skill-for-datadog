# Simulates an in-house base image built FROM a Chainguard image (for example with extra files or certs).
FROM cgr.dev/chainguard/python:latest
COPY --chown=nonroot:nonroot app.py /app/app.py
ENTRYPOINT ["python", "/app/app.py"]
