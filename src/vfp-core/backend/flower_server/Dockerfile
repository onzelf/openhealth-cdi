FROM python:3.11-slim

WORKDIR /app

ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1

RUN pip install --upgrade pip \
  && pip install flwr requests fastapi "uvicorn[standard]" pydantic

COPY server.py /app/server.py

ENV HUB_URL=http://fc-hub:8080
ENV SERVER_ADDRESS=0.0.0.0:8080
ENV CONTROL_PORT=8081
ENV BACKEND_URL=http://flower-server:8081
ENV RUNS_DIR=/vault/runs
ENV FLOWER_ROUNDS=3
ENV MIN_CLIENTS=2
ENV SERVER_POLL_SECONDS=1

EXPOSE 8080 8081

CMD ["python", "server.py"]
