FROM python:3.11-slim

WORKDIR /app

ENV PYTHONUNBUFFERED=1
ENV PIP_NO_CACHE_DIR=1

RUN pip install --upgrade pip \
  && pip install fastapi "uvicorn[standard]" pydantic redis requests

COPY hub.py /app/hub.py

ENV RUNS_DIR=/vault/runs
ENV PORT=8080

EXPOSE 8080

CMD ["python","-m","uvicorn","hub:app","--host","0.0.0.0","--port","8080","--log-level","warning"]
