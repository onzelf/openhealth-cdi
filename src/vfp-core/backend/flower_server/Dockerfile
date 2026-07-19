FROM python:3.11-slim

WORKDIR /app

ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates \
       libgomp1 \
    && rm -rf /var/lib/apt/lists/*

RUN python -m pip install --upgrade pip \
    && python -m pip install \
       numpy==1.26.4 \
       flwr==1.28.0 \
       "medmnist>=3.0,<4" \
       requests \
       fastapi \
       "uvicorn[standard]" \
       pydantic \
    && python -m pip install \
       torch==2.2.0 \
       torchvision==0.17.0 \
       --index-url https://download.pytorch.org/whl/cpu

COPY pathmnist /app/pathmnist
COPY flower_server/server.py /app/server.py

ENV HUB_URL=http://fc-hub:8080
ENV SERVER_ADDRESS=0.0.0.0:8080
ENV CONTROL_PORT=8081
ENV BACKEND_URL=http://flower-server:8081
ENV RUNS_DIR=/vault/runs
ENV VAULT_ROOT=/vault
ENV FLOWER_ROUNDS=10
ENV MIN_CLIENTS=2
ENV SERVER_POLL_SECONDS=1
ENV DEVICE=cpu

EXPOSE 8080 8081

CMD ["python", "-u", "server.py"]
