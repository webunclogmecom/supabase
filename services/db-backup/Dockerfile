# Own Prod database copy every 2 hours (README.md). pg_dump must be at least the server's major
# version (Prod is Postgres 17), so the base image is pinned to 17.
FROM postgres:17-alpine
# su-exec: the restore drill runs a throwaway Postgres as the postgres user (the image does not ship it).
RUN apk add --no-cache bash coreutils su-exec
COPY backup.sh /usr/local/bin/backup.sh
# Strip Windows line endings in case a checkout converted them; bash refuses a CR in the script.
RUN sed -i 's/\r$//' /usr/local/bin/backup.sh && chmod +x /usr/local/bin/backup.sh
# Runs as root on purpose: Railway volumes are root-owned.
ENTRYPOINT ["/usr/local/bin/backup.sh"]
CMD ["loop"]
