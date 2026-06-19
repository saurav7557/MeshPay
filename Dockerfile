# ---- Build stage ----
# Uses the Maven wrapper + JDK 17 to compile and package the app into a jar.
# Kept separate from the runtime stage so the final image doesn't carry the
# full JDK + Maven cache (~600MB) — only the JRE + the jar (~200MB).
FROM eclipse-temurin:17-jdk-jammy AS build

WORKDIR /app

# Copy wrapper + pom first so Docker can cache the dependency download layer
# independently of source code changes (faster rebuilds on code-only edits).
COPY mvnw .
COPY .mvn .mvn
COPY pom.xml .
RUN chmod +x mvnw && ./mvnw -B dependency:go-offline

# Now copy source and build
COPY src src
RUN ./mvnw -B clean package -DskipTests

# ---- Runtime stage ----
FROM eclipse-temurin:17-jre-jammy

WORKDIR /app

# Run as non-root for basic container hardening
RUN groupadd -r spring && useradd -r -g spring spring
COPY --from=build /app/target/*.jar app.jar
RUN chown spring:spring app.jar
USER spring

EXPOSE 8080

# SPRING_PROFILES_ACTIVE is set by docker-compose.yml / the deployment platform,
# defaults to 'dev' (H2) per application.properties if not overridden.
ENTRYPOINT ["java", "-jar", "app.jar"]
