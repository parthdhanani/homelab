import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import http from "node:http";

const N8N_BASE_URL = process.env.N8N_BASE_URL ?? "http://cryptex-n8n:5678";
const N8N_API_KEY = process.env.N8N_API_KEY ?? "";
const PORT = parseInt(process.env.PORT ?? "3100");

function n8nHeaders() {
  return { "X-N8N-API-KEY": N8N_API_KEY, "Content-Type": "application/json" };
}

async function n8nFetch(path: string, opts: RequestInit = {}) {
  const res = await fetch(`${N8N_BASE_URL}/api/v1${path}`, {
    ...opts,
    headers: { ...n8nHeaders(), ...(opts.headers ?? {}) },
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`n8n ${res.status}: ${body}`);
  }
  return res.json();
}

const server = new McpServer({
  name: "n8n-mcp",
  version: "1.0.0",
});

server.tool("list_workflows", "List all n8n workflows with their active status", {}, async () => {
  const data = await n8nFetch("/workflows?limit=50");
  const rows = (data.data ?? []).map((w: any) =>
    `[${w.id}] ${w.name} — ${w.active ? "active" : "inactive"}`
  );
  return { content: [{ type: "text", text: rows.join("\n") || "No workflows found." }] };
});

server.tool(
  "get_workflow",
  "Get full JSON of a workflow by ID",
  { id: z.string().describe("Workflow ID") },
  async ({ id }) => {
    const data = await n8nFetch(`/workflows/${id}`);
    return { content: [{ type: "text", text: JSON.stringify(data, null, 2) }] };
  }
);

server.tool(
  "execute_workflow",
  "Trigger a workflow execution. Only works on active workflows with a webhook/manual trigger.",
  {
    id: z.string().describe("Workflow ID"),
    payload: z.record(z.unknown()).optional().describe("Optional JSON payload"),
  },
  async ({ id, payload }) => {
    const data = await n8nFetch(`/workflows/${id}/run`, {
      method: "POST",
      body: JSON.stringify({ data: payload ?? {} }),
    });
    return { content: [{ type: "text", text: `Execution started: ${JSON.stringify(data)}` }] };
  }
);

server.tool(
  "get_executions",
  "Get recent workflow executions, optionally filtered by workflow ID",
  {
    workflowId: z.string().optional().describe("Filter by workflow ID"),
    limit: z.number().default(10).describe("Number of results (default 10)"),
  },
  async ({ workflowId, limit }) => {
    const params = new URLSearchParams({ limit: String(limit) });
    if (workflowId) params.set("workflowId", workflowId);
    const data = await n8nFetch(`/executions?${params}`);
    const rows = (data.data ?? []).map((e: any) =>
      `[${e.id}] workflow=${e.workflowId} status=${e.status} started=${e.startedAt}`
    );
    return { content: [{ type: "text", text: rows.join("\n") || "No executions." }] };
  }
);

server.tool(
  "create_workflow",
  "Create a new n8n workflow from a JSON definition. The workflow will be inactive by default.",
  {
    name: z.string().describe("Workflow name"),
    nodes: z.array(z.record(z.unknown())).describe("Array of n8n node objects"),
    connections: z.record(z.unknown()).describe("n8n connections object linking nodes"),
    settings: z.record(z.unknown()).optional().describe("Optional workflow settings"),
  },
  async ({ name, nodes, connections, settings }) => {
    const data = await n8nFetch("/workflows", {
      method: "POST",
      body: JSON.stringify({ name, nodes, connections, settings: settings ?? {} }),
    });
    return {
      content: [{ type: "text", text: `Created workflow ID=${data.id} name="${data.name}"` }],
    };
  }
);

server.tool(
  "update_workflow",
  "Update an existing workflow. Provide the full updated nodes + connections.",
  {
    id: z.string().describe("Workflow ID to update"),
    name: z.string().optional(),
    nodes: z.array(z.record(z.unknown())).optional(),
    connections: z.record(z.unknown()).optional(),
  },
  async ({ id, name, nodes, connections }) => {
    const current = await n8nFetch(`/workflows/${id}`);
    const updated = {
      ...current,
      ...(name && { name }),
      ...(nodes && { nodes }),
      ...(connections && { connections }),
    };
    const data = await n8nFetch(`/workflows/${id}`, {
      method: "PUT",
      body: JSON.stringify(updated),
    });
    return { content: [{ type: "text", text: `Updated workflow ID=${data.id}` }] };
  }
);

server.tool(
  "set_workflow_active",
  "Activate or deactivate a workflow",
  {
    id: z.string().describe("Workflow ID"),
    active: z.boolean().describe("true to activate, false to deactivate"),
  },
  async ({ id, active }) => {
    const endpoint = active ? `/workflows/${id}/activate` : `/workflows/${id}/deactivate`;
    const data = await n8nFetch(endpoint, { method: "POST" });
    return {
      content: [{ type: "text", text: `Workflow ${id} is now ${data.active ? "active" : "inactive"}` }],
    };
  }
);

server.tool(
  "delete_workflow",
  "Permanently delete a workflow by ID",
  { id: z.string().describe("Workflow ID") },
  async ({ id }) => {
    await n8nFetch(`/workflows/${id}`, { method: "DELETE" });
    return { content: [{ type: "text", text: `Deleted workflow ${id}` }] };
  }
);

// HTTP server with streamable transport (one transport per request)
const httpServer = http.createServer(async (req, res) => {
  if (req.method === "GET" && req.url === "/health") {
    res.writeHead(200).end("ok");
    return;
  }
  if (req.url !== "/mcp") {
    res.writeHead(404).end("Not found");
    return;
  }
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
  res.on("close", () => transport.close());
  await server.connect(transport);
  await transport.handleRequest(req, res);
});

httpServer.listen(PORT, "0.0.0.0", () => {
  console.log(`n8n MCP server listening on :${PORT}/mcp`);
});
