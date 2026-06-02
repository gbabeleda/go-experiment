# syntax=docker/dockerfile:1

# Stage 1: Build both binaries
FROM golang:1.25.4 AS builder

WORKDIR /app

# Copy dependencies first to leverage Docker caching, only re-downloading if go.mod or go.sum changes
COPY go.mod go.sum ./

# Download dependencies
RUN go mod download

# Copy the rest of the source code
COPY . .

# Build both the API and worker binaries to /bin output path
# CGO_ENABLED=0 set to force fully static binaries, which are more portable and can run in minimal base images like alpine
RUN CGO_ENABLED=0 go build -o /bin/api ./cmd/api && \
    CGO_ENABLED=0 go build -o /bin/worker ./cmd/worker


# Stage 2: slim api image
FROM alpine AS api

# Create a non-root user and group with some difference from Debian
# Create user before chown to avoid issues with permissions when copying files from the builder stage
RUN addgroup -S -g 1000 appuser && \
    adduser -S -G appuser -u 1000 appuser

USER appuser

# Copy API binary from builder, set ownership in the same step to avoid extra layers and potential permission issues
COPY --from=builder --chown=appuser:appuser /bin/api /bin/api

# Only expose the API port, worker does not need to expose any ports
# Documentation only
EXPOSE 8080

ENTRYPOINT ["/bin/api"]

# Stage 3: slim worker image
FROM alpine AS worker

RUN addgroup -S -g 1000 appuser && \
    adduser -S -G appuser -u 1000 appuser

USER appuser

COPY --from=builder --chown=appuser:appuser /bin/worker /bin/worker

ENTRYPOINT ["/bin/worker"]
