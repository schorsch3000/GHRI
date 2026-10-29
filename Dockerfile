# Carrier image: ghri.sh and nothing else, meant for `COPY --from=ghcr.io/schorsch3000/ghri`.
# It is not runnable on its own; ghri needs bash, gh, yq and jq (see README).
FROM scratch
LABEL org.opencontainers.image.title="ghri" \
      org.opencontainers.image.description="GitHub Release Installer (ghri.sh), for COPY --from" \
      org.opencontainers.image.source="https://github.com/schorsch3000/GHRI" \
      org.opencontainers.image.licenses="MIT"
COPY --chmod=0755 ghri.sh /ghri.sh
COPY ghri.example.yaml /ghri.example.yaml
