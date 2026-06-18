# syntax=docker/dockerfile:1

##########################################################################
# Stage 1 - build the launcher.war with Maven (JDK 11) + Node frontend
#   JDK 11 is required: the notification module depends on ActiveMQ 5.18 which is
#   compiled for Java 11. The POM still targets Java 8 bytecode (source/target 1.8).
##########################################################################
FROM maven:3.9-eclipse-temurin-11 AS build

# git is required by the frontend build (npm/grunt) tooling pulled in by
# the frontend-maven-plugin; build-essential/python3 cover any native npm deps.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates python3 make g++ \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Copy the whole source tree and build. Tests are skipped here (they need a
# live PostgreSQL); run them in a separate CI job if desired.
COPY . .

# build.properties is gitignored (only the .example is committed) but the server
# module's resource filtering requires it. These are build-time values; the
# runtime Tomcat context.xml (rendered by the entrypoint) overrides them.
RUN cp server/build.properties.example server/build.properties

RUN --mount=type=cache,target=/root/.m2 \
    mvn -B -e -DskipTests clean install

##########################################################################
# Stage 2 - runtime: Tomcat 9 (JDK 11) serving the app at the ROOT context
##########################################################################
FROM tomcat:9.0-jdk11-temurin-jammy

# postgresql-client is used by the entrypoint to seed initial data.
# aapt is referenced by the server config (aapt.command); current code uses a
# Java APK parser instead, so installing it is best-effort and never fatal.
RUN apt-get update \
    && apt-get install -y --no-install-recommends postgresql-client \
    && (apt-get install -y --no-install-recommends aapt || echo "aapt unavailable, continuing") \
    && rm -rf /var/lib/apt/lists/*

# Base directory for app data (files, plugins, logs, email templates, log config)
ENV HMDM_BASE_DIRECTORY=/opt/hmdm

# Deploy the WAR as the ROOT web application (served at "/")
RUN rm -rf "$CATALINA_HOME/webapps/ROOT"
COPY --from=build /src/server/target/launcher.war "$CATALINA_HOME/webapps/ROOT.war"

# Installer assets the entrypoint needs at runtime: the Tomcat context template,
# the log4j template, the initial-data SQL, and the email templates.
COPY install /opt/hmdm/install

COPY docker/docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["catalina.sh", "run"]
