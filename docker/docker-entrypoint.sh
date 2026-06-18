#!/usr/bin/env bash
#
# Headwind MDM server container entrypoint.
#
# Renders the Tomcat per-app context (conf/Catalina/localhost/ROOT.xml) and the
# log4j config from the installer templates using environment variables, prepares
# the data directory, then starts Tomcat. The web app creates the DB schema via
# Liquibase on first start; once that completes (signalled by the install flag
# file) this script seeds the initial data if the database is empty.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via environment / docker-compose / -e flags)
# ---------------------------------------------------------------------------
: "${DB_HOST:=db}"
: "${DB_PORT:=5432}"
: "${DB_NAME:=hmdm}"
: "${DB_USER:=hmdm}"
: "${DB_PASSWORD:=topsecret}"

# Public URL the control panel is reached at. _PROTOCOL_://_BASE_HOST__BASE_PATH_
: "${HMDM_PROTOCOL:=http}"
: "${HMDM_BASE_HOST:=localhost:8080}"
: "${HMDM_BASE_PATH:=}"          # empty == ROOT context
: "${HMDM_BASE_DOMAIN:=localhost}" # used for the MQTT push server URI

: "${HMDM_HASH_SECRET:=changeme-C3z9vi54}"
: "${HMDM_BASE_DIRECTORY:=/opt/hmdm}"
: "${HMDM_LANGUAGE:=en}"

# Initial-data seed parameters (substituted into install/sql/hmdm_init.<lang>.sql)
: "${HMDM_ADMIN_EMAIL:=admin@h-mdm.com}"
: "${HMDM_CLIENT_VERSION:=}"
: "${HMDM_CLIENT_APK:=}"

# SMTP (optional - required only for password recovery emails)
: "${SMTP_HOST:=}"
: "${SMTP_PORT:=587}"
: "${SMTP_SSL:=0}"
: "${SMTP_STARTTLS:=1}"
: "${SMTP_USERNAME:=}"
: "${SMTP_PASSWORD:=}"
: "${SMTP_FROM:=}"

INSTALL_DIR=/opt/hmdm/install
INSTALL_FLAG="${HMDM_BASE_DIRECTORY}/hmdm_install_flag"
CONTEXT_OUT="${CATALINA_HOME}/conf/Catalina/localhost/ROOT.xml"

log() { echo "[hmdm-entrypoint] $*"; }

# ---------------------------------------------------------------------------
# Prepare the data directory
# ---------------------------------------------------------------------------
prepare_base_dir() {
    mkdir -p "${HMDM_BASE_DIRECTORY}/files" \
             "${HMDM_BASE_DIRECTORY}/plugins" \
             "${HMDM_BASE_DIRECTORY}/logs"

    # Email templates referenced by the context (paths contain _LANGUAGE_ that the
    # app substitutes at runtime). Don't overwrite if already present (mounted vol).
    if [ ! -d "${HMDM_BASE_DIRECTORY}/emails" ]; then
        cp -r "${INSTALL_DIR}/emails" "${HMDM_BASE_DIRECTORY}/emails"
    fi

    sed "s|_BASE_DIRECTORY_|${HMDM_BASE_DIRECTORY}|g" \
        "${INSTALL_DIR}/log4j_template.xml" > "${HMDM_BASE_DIRECTORY}/log4j-hmdm.xml"
}

# ---------------------------------------------------------------------------
# Render the Tomcat context from the installer template
# Note: passwords containing '|', '&' or '\' will break the sed substitution.
# ---------------------------------------------------------------------------
render_context() {
    mkdir -p "$(dirname "${CONTEXT_OUT}")"
    sed \
        -e "s|_SQL_HOST_|${DB_HOST}|g" \
        -e "s|_SQL_PORT_|${DB_PORT}|g" \
        -e "s|_SQL_BASE_|${DB_NAME}|g" \
        -e "s|_SQL_USER_|${DB_USER}|g" \
        -e "s|_SQL_PASS_|${DB_PASSWORD}|g" \
        -e "s|_BASE_DIRECTORY_|${HMDM_BASE_DIRECTORY}|g" \
        -e "s|_PROTOCOL_|${HMDM_PROTOCOL}|g" \
        -e "s|_BASE_HOST_|${HMDM_BASE_HOST}|g" \
        -e "s|_BASE_DOMAIN_|${HMDM_BASE_DOMAIN}|g" \
        -e "s|_BASE_PATH_|${HMDM_BASE_PATH}|g" \
        -e "s|_INSTALL_FLAG_|${INSTALL_FLAG}|g" \
        -e "s|_SMTP_HOST_|${SMTP_HOST}|g" \
        -e "s|_SMTP_PORT_|${SMTP_PORT}|g" \
        -e "s|_SMTP_SSL_|${SMTP_SSL}|g" \
        -e "s|_SMTP_STARTTLS_|${SMTP_STARTTLS}|g" \
        -e "s|_SMTP_USERNAME_|${SMTP_USERNAME}|g" \
        -e "s|_SMTP_PASSWORD_|${SMTP_PASSWORD}|g" \
        -e "s|_SMTP_FROM_|${SMTP_FROM}|g" \
        -e "s|changeme-C3z9vi54|${HMDM_HASH_SECRET}|g" \
        "${INSTALL_DIR}/context_template.xml" > "${CONTEXT_OUT}"
    log "Rendered Tomcat context -> ${CONTEXT_OUT}"
}

# ---------------------------------------------------------------------------
# Seed the initial data once Liquibase has created the schema (first boot only)
# Runs in the background; Tomcat itself runs in the foreground as PID 1.
# ---------------------------------------------------------------------------
seed_database() {
    export PGPASSWORD="${DB_PASSWORD}"
    local psql_base=(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=0)

    # Wait for the web app to finish schema initialization (writes "OK" to the flag)
    rm -f "${INSTALL_FLAG}" 2>/dev/null || true
    local waited=0
    while [ ! -f "${INSTALL_FLAG}" ] || [ "$(cat "${INSTALL_FLAG}" 2>/dev/null || true)" != "OK" ]; do
        waited=$((waited + 2))
        if [ "${waited}" -gt 300 ]; then
            log "Timed out waiting for schema initialization; skipping data seed."
            return 0
        fi
        sleep 2
    done

    # Liquibase pre-populates users/configurations/customers, but not applications.
    # An empty applications table therefore means the initial data has not been seeded yet.
    local count
    count=$("${psql_base[@]}" -tAc "SELECT count(*) FROM applications" 2>/dev/null || echo "")
    if [ "${count}" = "0" ]; then
        log "Fresh database detected - seeding initial data (default app, settings, admin email)..."
        sed \
            -e "s|_HMDM_BASE_|${HMDM_BASE_DIRECTORY}|g" \
            -e "s|_HMDM_VERSION_|${HMDM_CLIENT_VERSION}|g" \
            -e "s|_HMDM_APK_|${HMDM_CLIENT_APK}|g" \
            -e "s|_ADMIN_EMAIL_|${HMDM_ADMIN_EMAIL}|g" \
            "${INSTALL_DIR}/sql/hmdm_init.${HMDM_LANGUAGE}.sql" \
            | "${psql_base[@]}" >/dev/null 2>&1 \
            && log "Initial data seeded." \
            || log "Seeding reported errors (database may already be initialized)."
    else
        log "Database already initialized (users=${count}); skipping seed."
    fi
}

# ---------------------------------------------------------------------------
main() {
    prepare_base_dir
    render_context

    # Seed in the background so Tomcat can come up and create the schema.
    seed_database &

    log "Starting Tomcat..."
    exec "$@"
}

main "$@"
