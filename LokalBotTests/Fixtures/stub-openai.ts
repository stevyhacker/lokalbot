// Minimal OpenAI-compatible stub for integration tests. Streams one fixed
// assistant message for any /v1/chat/completions request. Prints the
// chosen port on stdout as its first line.
const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/v1/models") {
      return Response.json({ object: "list", data: [{ id: "stub-model", object: "model" }] });
    }
    if (url.pathname !== "/v1/chat/completions") {
      return new Response("not found", { status: 404 });
    }
    const encoder = new TextEncoder();
    const chunk = (payload: unknown) => encoder.encode(`data: ${JSON.stringify(payload)}\n\n`);
    const body = new ReadableStream({
      start(controller) {
        const base = { id: "stub", object: "chat.completion.chunk", model: "stub-model" };
        controller.enqueue(chunk({ ...base, choices: [{ index: 0, delta: { role: "assistant" } }] }));
        controller.enqueue(chunk({ ...base, choices: [{ index: 0, delta: { content: "STUB-REPLY" } }] }));
        controller.enqueue(chunk({ ...base, choices: [{ index: 0, delta: {}, finish_reason: "stop" }] }));
        controller.enqueue(encoder.encode("data: [DONE]\n\n"));
        controller.close();
      },
    });
    return new Response(body, { headers: { "content-type": "text/event-stream" } });
  },
});
console.log(String(server.port));
