FROM node:22-bookworm-slim AS dependencies
WORKDIR /app
COPY package.json package-lock.json ./
# The locked better-sqlite3 version compiles a native addon.
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 make g++ \
    && npm ci --omit=dev

FROM node:22-bookworm-slim
WORKDIR /app
COPY --from=dependencies /app/node_modules ./node_modules
COPY . .
ENV PORT=3000 DB_PATH=/data/vanguard.db
VOLUME /data
EXPOSE 3000
CMD ["node", "server.js"]
