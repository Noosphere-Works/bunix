// serve.js <root> <port file>: serves the files under <root> on 127.0.0.1,
// as the registry a frozen `bun install` fetches tarballs from, and writes
// the port it listens on to <port file> once it is listening.
import { renameSync, writeFileSync } from "node:fs";

const [root, portFile] = process.argv.slice(2);

const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  async fetch(request) {
    const path = decodeURIComponent(new URL(request.url).pathname);
    const file = Bun.file(root + path);
    if (await file.exists()) return new Response(file);
    console.error(`bunix: the lock has no tarball for ${path}`);
    return new Response("", { status: 404 });
  },
});

writeFileSync(`${portFile}.tmp`, String(server.port));
renameSync(`${portFile}.tmp`, portFile);
