# syntax=docker/dockerfile:1
# 一次性工具镜像：只在 `docker compose run --rm trainer` 时运行，不常驻。
FROM python:3.12-alpine
COPY trainer.py /app/trainer.py
ENTRYPOINT ["python", "-u", "/app/trainer.py"]
