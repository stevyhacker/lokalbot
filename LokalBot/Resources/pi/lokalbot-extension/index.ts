// LokalBot pi extension: registers the app-configured local LLM as a
// provider and gates mutating tools behind the host UI.
//
// Runs inside pi (RPC mode) under Bun. The env contract comes from
// PiLaunchPlanner; the confirm() below surfaces in LokalBot as an
// extension_ui_request on stdout, answered over stdin.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { resolve } from "node:path";
import { homedir } from "node:os";

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
        // Required: pi's registerProvider path does NOT default `input`
        // (unlike its models.json path), and pi-ai's openai-completions
        // dereferences model.input unguarded — omitting this crashes every
        // completion with "undefined is not an object".
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      },
    ],
  });

  pi.on("tool_call", async (event, ctx) => {
    if (!GATED_TOOLS.has(event.toolName)) return undefined; // reads auto-allowed

    // Machine-parseable payload: the host renders exact commands and file
    // changes, rather than relying on a model-authored summary.
    const approved = await ctx.ui.confirm(
      "lokalbot_tool_approval",
      JSON.stringify(approvalPayload(event.toolName, event.input)),
    );
    if (!approved) {
      return {
        block: true,
        reason:
          "The user denied this request in LokalBot. Nothing changed. Do not retry it or suggest changing approval settings unless the user explicitly asks.",
      };
    }
    return undefined;
  });
}

function resolvedPath(value: unknown): string | undefined {
  const path = String(value ?? "");
  if (!path) return undefined;
  if (path === "~") return homedir();
  if (path.startsWith("~/")) return resolve(homedir(), path.slice(2));
  return resolve(process.cwd(), path);
}

function approvalPayload(toolName: string, input: unknown): Record<string, unknown> {
  const args = (input ?? {}) as Record<string, unknown>;
  const payload: Record<string, unknown> = {
    tool: toolName,
    workspace: process.cwd(),
    truncated: false,
  };

  switch (toolName) {
    case "bash": {
      payload.command = String(args.command ?? args.cmd ?? JSON.stringify(args));
      break;
    }
    case "write": {
      payload.path = resolvedPath(args.path ?? args.file_path);
      payload.content = String(args.content ?? "");
      break;
    }
    case "edit": {
      const edits = Array.isArray(args.edits)
        ? args.edits.map((value) => {
            const edit = (value ?? {}) as Record<string, unknown>;
            return {
              oldText: String(edit.oldText ?? edit.old_text ?? ""),
              newText: String(edit.newText ?? edit.new_text ?? ""),
            };
          })
        : [];
      payload.path = resolvedPath(args.path ?? args.file_path);
      payload.edits = edits;
      break;
    }
  }
  return payload;
}
