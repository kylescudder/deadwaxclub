FROM oven/bun:1.4.4@sha256:1d22548f177f4ff38e0c15baa3c2c46c6c2060ba2d1bc573bb4720b407548f1d AS build
WORKDIR /app
ENV CI=true BUN_CONFIG_MAX_HTTP_REQUESTS=16
# Never run the Husky hook in image builds.
ENV HUSKY=0
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --network-concurrency=16
COPY astro.config.mjs tsconfig.json ./
COPY scripts ./scripts
COPY src ./src
COPY public ./public
# Public values for the shared list viewer; see scripts/write-config.mjs.
ARG SUPABASE_URL
ARG SUPABASE_ANON_KEY
RUN SUPABASE_URL="$SUPABASE_URL" SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY" bun scripts/write-config.mjs \
    && bun run build && bun run check:site

FROM caddy:2.11.9@sha256:4e2425f6009577e7c651010f16679c28f7d12df3e7b1914f941a7a3370746b3c
# Port 8080 needs no privileged bind capability; drop the upstream file capability
# so the binary can execute with the runtime capability set empty.
RUN setcap -r /usr/bin/caddy
COPY --from=build /app/dist /srv
COPY Caddyfile /etc/caddy/Caddyfile
ARG DEADWAX_REVISION=development
ENV DEADWAX_REVISION=${DEADWAX_REVISION}
LABEL org.opencontainers.image.revision=${DEADWAX_REVISION}
USER 1000:1000
EXPOSE 8080
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
