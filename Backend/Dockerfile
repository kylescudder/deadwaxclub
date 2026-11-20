FROM oven/bun:1.4.4@sha256:1d22548f177f4ff38e0c15baa3c2c46c6c2060ba2d1bc573bb4720b407548f1d
WORKDIR /app/Backend
ENV NODE_ENV=production
COPY Backend/package.json Backend/bun.lock ./
RUN bun install --frozen-lockfile --production --ignore-scripts
COPY Backend/src ./src
COPY Backend/db ./db
COPY Backend/drizzle ./drizzle
COPY supabase/migrations /app/supabase/migrations
USER 1000:1000
EXPOSE 3147
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD ["bun", "-e", "const r = await fetch('http://127.0.0.1:3147/health/live', { signal: AbortSignal.timeout(3000) }); if (!r.ok) process.exit(1)"]
CMD ["bun", "src/index.ts"]
