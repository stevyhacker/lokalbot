// LokalBot pi extension: registers the app-configured local LLM as a
// provider and gates mutating tools behind the host UI.
//
// Runs inside pi (RPC mode) under Bun. The env contract comes from
// PiLaunchPlanner; the confirm() below surfaces in LokalBot as an
// extension_ui_request on stdout, answered over stdin.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const GATED_TOOLS = new Set(["write", "edit", "bash"]);

export default function lokalbotExtension(pi: ExtensionAPI) {
  const baseUrl = process.env.LOKALBOT_LLM_BASE_URL;
  const model = process.env.LOKALBOT_LLM_MODEL;
  if (!baseUrl || !model) {
    throw new Error(
      "LOKALBOT_LLM_BASE_URL and LOKALBOT_LLM_MODEL must be set (launched outside LokalBot?)",
    );
  }
  const contextWindow = Number(process.env.LOKALBOT_LLM_CTX ?? "16384");

  pi.registerProvider("lokalbot", {
    baseUrl,
    api: "openai-completions",
    // llama.cpp ignores the key; Ollama/LM Studio may want one.
    apiKey: process.env.LOKALBOT_LLM_API_KEY ?? "lokalbot",
    models: [
      {
        id: model,
        contextWindow,
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      },
    ],
  });

  pi.on("tool_call", async (event, ctx) => {
    if (!GATED_TOOLS.has(event.toolName)) return undefined; // reads auto-allowed

    // Machine-parseable payload: LokalBot recognizes the sentinel title and
    // parses tool + summary from the JSON message (PiUIRequest, Task 2).
    const approved = await ctx.ui.confirm(
      "lokalbot_tool_approval",
      JSON.stringify({
        tool: event.toolName,
        summary: summarize(event.toolName, event.input),
      }),
    );
    if (!approved) {
      return { block: true, reason: "Blocked by user in LokalBot." };
    }
    return undefined;
  });
}

function summarize(toolName: string, input: unknown): string {
  const args = (input ?? {}) as Record<string, unknown>;
  switch (toolName) {
    case "bash":
      return String(args.command ?? args.cmd ?? JSON.stringify(args)).slice(0, 500);
    case "write":
    case "edit":
      return String(args.path ?? args.file_path ?? JSON.stringify(args)).slice(0, 500);
    default:
      return JSON.stringify(args).slice(0, 500);
  }
}
