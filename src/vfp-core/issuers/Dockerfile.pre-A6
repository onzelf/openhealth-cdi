FROM python:3.10-slim

RUN pip install --no-cache-dir fastapi uvicorn[standard] requests cryptography

WORKDIR /app
COPY issuer.py /app/issuer.py
COPY config/cap_profiles.json /app/config/cap_profiles.json

RUN  mkdir -p /vault/registry


EXPOSE 8080
CMD ["python","-m","uvicorn","issuer:app","--host","0.0.0.0","--port","8080","--log-level","info"]
