FROM node:22-bookworm-slim
WORKDIR /app
COPY package.json ./
# better-sqlite3 ships prebuilt binaries for glibc; no compiler needed.
# NOTE: run `docker compose build` once WHILE ONLINE; the image then runs fully offline.
RUN npm install --omit=dev
COPY . .
ENV PORT=3000 DB_PATH=/data/vanguard.db
VOLUME /data
EXPOSE 3000
CMD ["node", "server.js"]
