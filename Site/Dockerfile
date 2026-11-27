FROM oven/bun:1.4.5@sha256:3aa040e5445efa09d75bb428a64ba50db13e2b3ac9b6b0c7f145615f62b2ee18 AS build
WORKDIR /app
# Never run the Husky hook in image builds.
ENV HUSKY=0 CI=true BUN_CONFIG_MAX_HTTP_REQUESTS=16
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --network-concurrency=16
COPY app.json astro.config.mjs tsconfig.json ./
COPY scripts ./scripts
COPY src ./src
COPY public ./public
# Sites whose pages call the app's API write public/js/config.js from API_URL
# with the optional scripts/write-config.mjs hook.
ARG API_URL
RUN if [ -f scripts/write-config.mjs ]; then API_URL="$API_URL" bun scripts/write-config.mjs; fi \
    && bun run build && bun run check:site

FROM caddy:2.11.7@sha256:36c24ad91a7ff7bc4c87fe22bfa8df3c4b18da0773d73fc12ee2c52b98c0bb7e
# Port 8080 needs no privileged bind capability; drop the upstream file capability
# so the binary can execute with the runtime capability set empty.
RUN setcap -r /usr/bin/caddy
COPY --from=build /app/dist /srv
COPY Caddyfile app.caddy /etc/caddy/
ARG SOURCE_REVISION=development
ENV SITE_REVISION=${SOURCE_REVISION}
LABEL org.opencontainers.image.revision=${SOURCE_REVISION}
USER 1000:1000
EXPOSE 8080
# Health ownership: deploy/healthcheck.md at the repository root.
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD wget --quiet --spider --timeout=3 http://127.0.0.1:8080/healthz
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
