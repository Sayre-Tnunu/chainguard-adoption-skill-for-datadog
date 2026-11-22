# Simulates a team that overwrites the OCI vendor label in its own build.
FROM cgr.dev/chainguard/python:latest
LABEL org.opencontainers.image.vendor="example-co"
COPY --chown=nonroot:nonroot app.py /app/app.py
ENTRYPOINT ["python", "/app/app.py"]
