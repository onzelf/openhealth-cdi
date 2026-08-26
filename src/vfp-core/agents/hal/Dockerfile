FROM python:3.12-slim

RUN pip install --no-cache-dir cryptography
RUN pip install --no-cache-dir pillow

WORKDIR /app
COPY hal.py /app/hal.py

CMD ["python", "/app/hal.py"]
