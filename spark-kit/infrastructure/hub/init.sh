#!/bin/sh
# init.sh - Postgres volume chown on first boot
# Runs as root initially to set ownership, then drops privileges.

if [ ! -d "/var/lib/postgresql/data/PG_VERSION" ]; then
    echo "Initializing database volume..."
    chown -R "${_CONTAINER_UID:-1000}:${_CONTAINER_GID:-1000}" /var/lib/postgresql/data
fi

exec docker-entrypoint.sh postgres
