# SnakeYAML Engine -- the YAML 1.2 rewrite of SnakeYAML.
#
# The version is pinned because this harness attributes results to a specific
# release. 2.9 is the last of the v2 line, whose classes live under
# org.snakeyaml.engine.v2; the 3.x line moved the package.

FROM eclipse-temurin:21-jdk AS build

ARG SNAKEYAML_ENGINE_VERSION=2.9
ARG MAVEN_CENTRAL=https://repo1.maven.org/maven2

WORKDIR /app

# Fetch at build time so the runtime image needs no network at all.
RUN mkdir -p /app/deps /app/classes && \
    curl -fsSL -o /app/deps/snakeyaml-engine-${SNAKEYAML_ENGINE_VERSION}.jar \
      "${MAVEN_CENTRAL}/org/snakeyaml/snakeyaml-engine/${SNAKEYAML_ENGINE_VERSION}/snakeyaml-engine-${SNAKEYAML_ENGINE_VERSION}.jar"

COPY Emit.java /app/Emit.java

RUN javac -encoding UTF-8 -cp "/app/deps/*" -d /app/classes /app/Emit.java

FROM eclipse-temurin:21-jre

COPY --from=build /app/classes /app/classes
COPY --from=build /app/deps /app/deps

WORKDIR /app

# The harness overrides this, but keep the image runnable on its own.
CMD ["java", "-cp", "/app/classes:/app/deps/*", "Emit"]
