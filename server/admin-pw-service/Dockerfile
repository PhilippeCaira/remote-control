FROM python:3.12-slim

WORKDIR /app

# SQLite driver is built-in; no libsqlite3 needed. curl is handy for
# healthcheck without adding a second shim.
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

# SQLite file lives under /data so the container stays stateless and the
# volume mount in docker-compose.yml owns the persistence.
RUN mkdir -p /data
ENV ADMIN_PW_DB_PATH=/data/admin-pw.db

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=5s \
  CMD curl -fsS http://127.0.0.1:8080/healthz || exit 1

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]
