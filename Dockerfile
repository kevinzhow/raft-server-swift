FROM swift:6.4.1@sha256:82152e9f18ee21fc997fd4580b93a14097e465cb10d7a7eee3f2dc85364dd135 AS build
WORKDIR /build
COPY Package.swift Package.resolved ./
COPY Sources ./Sources
COPY Tests ./Tests
RUN swift build -c release --product RaftServer -j 4 --force-resolved-versions \
    && mkdir -p /out \
    && RAFT_BIN_DIR="$(swift build -c release --show-bin-path --force-resolved-versions)" \
    && cp "${RAFT_BIN_DIR:?}/RaftServer" /out/RaftServer \
    && cp -R "${RAFT_BIN_DIR:?}/raft-server-swift_RaftHTTP.bundle" /out/raft-server-swift_RaftHTTP.bundle

FROM ubuntu:26.04 AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl libatomic1 libstdc++6 libgcc-s1 zlib1g \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 raft \
    && useradd --uid 10001 --gid 10001 --home-dir /tmp --no-create-home --shell /usr/sbin/nologin raft
WORKDIR /app
COPY --from=build /usr/lib/swift/linux/*.so* /app/lib/
COPY --from=build /out/RaftServer /app/RaftServer
COPY --from=build /out/raft-server-swift_RaftHTTP.bundle /app/raft-server-swift_RaftHTTP.bundle
COPY --chmod=0555 scripts/docker-entrypoint.sh /app/docker-entrypoint.sh
ARG RAFT_RELEASE_SHA
ARG RAFT_BUILD_AT
ARG RAFT_RELEASE_BRANCH
ENV LD_LIBRARY_PATH=/app/lib \
    NODE_ENV=production \
    PORT=8080 \
    SOCKET_PORT=8082 \
    DAEMON_CONNECT_PORT=8081 \
    SOCKET_HOST=0.0.0.0 \
    DAEMON_CONNECT_HOST=0.0.0.0 \
    RAFT_RELEASE_SHA=${RAFT_RELEASE_SHA} \
    RAFT_BUILD_AT=${RAFT_BUILD_AT} \
    RAFT_RELEASE_BRANCH=${RAFT_RELEASE_BRANCH}
LABEL org.opencontainers.image.title="Raft Swift server" \
    org.opencontainers.image.revision=${RAFT_RELEASE_SHA} \
    org.opencontainers.image.created=${RAFT_BUILD_AT} \
    org.opencontainers.image.ref.name=${RAFT_RELEASE_BRANCH}
USER 10001:10001
EXPOSE 8080 8081 8082
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl --fail --silent --show-error --max-time 3 http://127.0.0.1:8080/api/version >/dev/null || exit 1
ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["--hostname", "0.0.0.0", "--port", "8080"]
