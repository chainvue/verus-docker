# syntax=docker/dockerfile:1.7
#
# Prometheus exporter for a Verus node.
#
# Standard library only, so the runtime is a stock slim Python image with no
# pip layer and nothing to keep patched beyond the base itself.

ARG PYTHON_TAG=3.12-slim

FROM python:${PYTHON_TAG}

ARG IMAGE_REVISION=dev
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="verus-exporter" \
      org.opencontainers.image.description="Prometheus exporter for Verus (verusd) nodes" \
      org.opencontainers.image.source="https://github.com/chainvue/verus-docker" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}"

COPY verus_exporter.py /usr/local/bin/verus-exporter

RUN chmod 0755 /usr/local/bin/verus-exporter \
    && useradd --uid 1000 --user-group --no-create-home --shell /usr/sbin/nologin exporter

USER exporter

EXPOSE 9838

# Unbuffered so container logs appear immediately rather than on flush.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python3 -c "import urllib.request,os,sys; \
sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:'+os.environ.get('EXPORTER_PORT','9838')+'/healthz', timeout=4).status==200 else 1)"

ENTRYPOINT ["/usr/local/bin/verus-exporter"]
