FROM rust:1.88-slim AS builder

WORKDIR /app

# Cache dependency compilation separately from source changes.
# Copy only manifest files first and build a dummy binary so that
# cargo fetches + compiles all dependencies. This layer is cached
# as long as Cargo.toml / Cargo.lock don't change.
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo 'fn main() {}' > src/main.rs \
    && cargo build --release \
    && rm -rf src

# Now copy the real source and do the final build. Only changed
# source files are recompiled; all dependencies stay cached.
COPY src/ src/
# migrations/ is read at compile time by sqlx::migrate!("./migrations"),
# so it must be present for the real build.
COPY migrations/ migrations/
ARG ASTATION_BUILD_COMMIT=unknown
ARG ASTATION_HOSTED_AGENT_API=false
# Touch main.rs so cargo knows it changed (avoids "nothing to compile").
RUN touch src/main.rs && \
    case "$ASTATION_HOSTED_AGENT_API" in \
      true) ASTATION_BUILD_COMMIT="$ASTATION_BUILD_COMMIT" cargo build --release --features hosted-agent-api ;; \
      false) ASTATION_BUILD_COMMIT="$ASTATION_BUILD_COMMIT" cargo build --release ;; \
      *) echo 'ASTATION_HOSTED_AGENT_API must be true or false' >&2; exit 1 ;; \
    esac

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/station-relay-server /usr/local/bin/station-relay-server

EXPOSE 3000

ENV RUST_LOG=info

CMD ["station-relay-server"]
