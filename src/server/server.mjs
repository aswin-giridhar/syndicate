// Dashboard server: static page + a server-sent-events stream of the live run.
// No framework — one Node process, so the whole thing starts in under a second.

import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import { runScenario, LLM_AVAILABLE } from "../scenario.mjs";

const PORT = process.env.PORT ?? 4173;
const page = new URL("../../public/index.html", import.meta.url);

createServer(async (req, res) => {
  if (req.url === "/" || req.url?.startsWith("/index.html")) {
    res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    return res.end(readFileSync(page));
  }

  if (req.url === "/api/meta") {
    res.writeHead(200, { "content-type": "application/json" });
    return res.end(JSON.stringify({ llm: LLM_AVAILABLE }));
  }

  if (req.url === "/api/run") {
    res.writeHead(200, {
      "content-type": "text/event-stream",
      "cache-control": "no-cache",
      connection: "keep-alive",
    });
    const send = (e) => res.write(`data: ${JSON.stringify(e)}\n\n`);
    try {
      await runScenario(send);
    } catch (err) {
      // Surface the failure to the UI. An empty event stream and a crashed run
      // must never look the same from the browser.
      send({ type: "error", message: String(err?.message ?? err), data: {}, at: Date.now() });
    }
    return res.end();
  }

  res.writeHead(404).end("not found");
}).listen(PORT, () => {
  console.log(`Syndicate dashboard → http://localhost:${PORT}`);
  console.log(`agents: ${LLM_AVAILABLE ? "live Claude" : "scripted stand-in (no ANTHROPIC_API_KEY)"}`);
});
