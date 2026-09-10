# syntax=docker/dockerfile:1
FROM ubuntu:24.04 AS compiler
RUN apt-get update && apt-get install -y --no-install-recommends gcc g++ git curl ca-certificates xz-utils python3
RUN curl -fsSL https://github.com/nim-lang/nightlies/releases/download/2026-04-24-version-2-2-bfeb3146d1638b39f69007a4ae5a23e23ae4e5ef/nim-2.2.10-linux_x64.tar.xz | tar xJ -C /opt
ENV PATH=/opt/nim-2.2.10/bin:$PATH
WORKDIR /src
COPY coworld/dependencies.lock coworld/dependencies.lock
COPY coworld/tools/sync_dependencies.py coworld/tools/sync_dependencies.py
RUN python3 coworld/tools/sync_dependencies.py
ENV POLYWORLD_DEPS=/src/tmp/coworld/deps
COPY config.nims config.nims
COPY src src
COPY examples/paintbot examples/paintbot
RUN nim c -d:coworld -o:/out/paintbot examples/paintbot/paintbot.nim
FROM python:3.12-slim
RUN pip install --no-cache-dir wasmtime==48.0.0 boto3==1.40.18
COPY --from=compiler /out/paintbot /usr/local/bin/paintbot
COPY coworld/paintbot/runtime /runtime
EXPOSE 8080
ENTRYPOINT ["python", "/runtime/host.py"]
