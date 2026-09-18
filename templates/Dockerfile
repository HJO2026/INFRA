# syntax=docker/dockerfile:1.7
# bench-infra 앱 이미지 템플릿. impl 레포 루트에 복사해 그대로 쓴다 (docs/impl-guide.md).
#
# 계약 (study-spec 10장):
#   - 포트 8080, /actuator/health 와 /actuator/prometheus 노출
#   - DB 접속은 SPRING_DATASOURCE_URL / USERNAME / PASSWORD 환경변수
#   - JVM 옵션은 여기 하드코딩하지 않는다. compose 가 JAVA_TOOL_OPTIONS 로 주입한다
#
# 빌드 컨텍스트 = Gradle 프로젝트 루트 (gradlew, build.gradle(.kts), src/ 가 있는 곳).
# bootJar 산출물 이름이 app.jar 가 아니면 아래 COPY 의 경로를 맞출 것.
#
# 빌드 예: docker build -f Dockerfile -t bench/impl-<name>:<tag> --build-arg JDK_IMAGE=eclipse-temurin:25-jdk .

ARG JDK_IMAGE=eclipse-temurin:25-jdk

# ---------- 1단계: Gradle 빌드 ----------
FROM ${JDK_IMAGE} AS build
WORKDIR /workspace

# 의존성 해석 레이어를 소스와 분리해 캐시 적중률을 높인다
COPY gradlew settings.gradle* build.gradle* gradle.properties* ./
COPY gradle ./gradle
RUN --mount=type=cache,target=/root/.gradle \
    chmod +x gradlew && ./gradlew --no-daemon --version

COPY src ./src
RUN --mount=type=cache,target=/root/.gradle \
    ./gradlew --no-daemon -x test bootJar \
 && ls -l build/libs

# ---------- 2단계: 런타임 ----------
FROM ${JDK_IMAGE} AS runtime
# 비루트 실행. 컨테이너 안에서 파일을 쓸 일이 없다 (GC 로그는 stdout)
RUN useradd --system --uid 10001 --create-home app
USER app
WORKDIR /app

COPY --from=build --chown=app:app /workspace/build/libs/app.jar /app/app.jar

ENV TZ=UTC
EXPOSE 8080
# JVM 옵션 없음. JAVA_TOOL_OPTIONS 는 compose 에서 주입.
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
