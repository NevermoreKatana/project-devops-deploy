# syntax=docker/dockerfile:1

# Сборка идёт на платформе сборщика (--platform=$BUILDPLATFORM), а образ
# собирается под целевую: байткод и статика от архитектуры не зависят, поэтому
# multi-arch сборка не платит за эмуляцию Gradle и npm.

# ---------- Frontend ----------
FROM --platform=$BUILDPLATFORM node:24-alpine AS frontend
WORKDIR /app
COPY frontend/package.json frontend/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY frontend/ ./
RUN npm run build

# ---------- Backend ----------
FROM --platform=$BUILDPLATFORM eclipse-temurin:27-jdk-alpine AS backend
WORKDIR /workspace

# Сначала только файлы сборки: слой с зависимостями переиспользуется, пока
# не изменился build.gradle.kts или каталог версий.
COPY gradlew ./
COPY gradle/ gradle/
COPY build.gradle.kts settings.gradle.kts ./
RUN chmod +x gradlew \
    && ./gradlew --no-daemon dependencies --quiet

COPY src/ src/
# Фронтенд складывается в статику Spring Boot — приложение раздаёт SPA само.
COPY --from=frontend /app/dist/ src/main/resources/static/
RUN --mount=type=cache,target=/root/.gradle \
    ./gradlew --no-daemon bootJar \
    && find build/libs -maxdepth 1 -name '*.jar' ! -name '*-plain.jar' -exec mv {} app.jar \;

# ---------- Runtime ----------
FROM eclipse-temurin:27-jre-alpine AS runtime

RUN apk add --no-cache ca-certificates tzdata \
    && addgroup -S app \
    && adduser -S -G app -h /app app

WORKDIR /app
COPY --from=backend /workspace/app.jar app.jar

USER app
EXPOSE 8080 9090

# Значения по умолчанию для запуска без внешней БД (профиль dev, H2 в памяти).
# Для prod задайте SPRING_PROFILES_ACTIVE=prod и переменные подключения к БД.
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0"

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD wget -q -O /dev/null "http://127.0.0.1:${MANAGEMENT_SERVER_PORT:-9090}/actuator/health/readiness" || exit 1

# exec, чтобы JVM получала SIGTERM напрямую и корректно останавливалась.
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar"]