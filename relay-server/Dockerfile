FROM rust:1.85-slim AS builder

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
# Touch main.rs so cargo knows it changed (avoids "nothing to compile").
RUN touch src/main.rs && cargo build --release

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/station-relay-server /usr/local/bin/station-relay-server

EXPOSE 3000

ENV RUST_LOG=info

CMD ["station-relay-server"]
