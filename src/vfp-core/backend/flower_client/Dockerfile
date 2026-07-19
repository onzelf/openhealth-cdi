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
    && python -m pip install \
       torch==2.2.0 \
       torchvision==0.17.0 \
       --index-url https://download.pytorch.org/whl/cu121

COPY pathmnist /app/pathmnist
COPY flower_client/client.py /app/client.py

ENV DEVICE=cuda

CMD ["python", "-u", "client.py"]
