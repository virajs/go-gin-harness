---
name: mcp-go
description: Create, debug, test, and publish Model Context Protocol (MCP) servers in Go — tools / prompts / resources, stdio vs HTTP transport, integration with the Go API or as standalone binaries. Use when building or changing an MCP server in this repo (relevant to agentic features that expose internal capabilities to LLM clients like Claude Code).
allowed-tools: Read, Glob, Grep, Edit, Write, Bash, WebFetch, Skill
---

# MCP servers in Go

The Model Context Protocol (MCP) is an open spec for exposing **tools** (callable
functions), **prompts** (parametrized templates), and **resources** (read-only data) to
LLM clients. The harness uses Go MCP servers in two ways:

1. **Internal tools** — your API exposes some of its use cases as MCP tools that LLM
   features (in the same product) or developer LLM clients (Claude Code) can call.
2. **Adapters to external systems** — wrap a third-party service (a DB, a CRM, a doc
   store) as an MCP server consumable by any MCP client.

Source-of-truth: [modelcontextprotocol.io](https://modelcontextprotocol.io). The Go SDK is
`github.com/modelcontextprotocol/go-sdk` (requires per-module owner approval). Verify the
current import path on pkg.go.dev — the SDK is evolving.

## Decision: stdio or HTTP

| Transport | When | Hosting |
|---|---|---|
| **stdio** | Claude Code (or local CLI) launches a child process; per-session | Build a single binary under `cmd/mcp-<name>/` |
| **HTTP (SSE)** | A long-running server; multiple clients connect over the network | Mount under an existing `cmd/api` route or stand up `cmd/mcp-<name>/` as its own service |

Default to **stdio** for tool servers consumed by Claude Code. Use **HTTP** when the MCP
is part of the product surface (e.g. an agentic feature in the SaaS calls it).

## Project layout

```
cmd/mcp-<name>/main.go            entry point — wires transport, registers tools/prompts/resources
internal/mcp/<name>/              tool/prompt/resource implementations
internal/mcp/<name>/tools/
internal/mcp/<name>/prompts/
internal/mcp/<name>/resources/
```

The tools usually delegate to existing use cases in `internal/app/<feature>/` — DON'T
duplicate logic. The MCP layer is a thin adapter (like the Gin API layer).

## Sketch — stdio server

```go
// cmd/mcp-projects/main.go
package main

import (
    "context"
    "log/slog"
    "os"

    mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"
    "{{ProjectName}}/internal/mcp/projects"
)

func main() {
    logger := slog.New(slog.NewTextHandler(os.Stderr, nil)) // logs go to stderr; stdio is the protocol channel

    deps := projects.Deps{ /* wire app-layer dependencies */ }
    server := mcpsdk.NewServer(mcpsdk.ServerOptions{
        Name:    "{{ProjectName}}-projects",
        Version: "0.1.0",
    })

    projects.RegisterTools(server, deps)
    projects.RegisterPrompts(server)
    projects.RegisterResources(server, deps)

    if err := server.Serve(context.Background(), mcpsdk.NewStdioTransport()); err != nil {
        logger.Error("mcp server failed", "err", err)
        os.Exit(1)
    }
}
```

## Authoring a tool

```go
// internal/mcp/projects/tools/create_project.go
package tools

import (
    "context"
    "encoding/json"

    mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"
    app "{{ProjectName}}/internal/app/projects"
)

type CreateProjectInput struct {
    TenantID string `json:"tenant_id"`
    Name     string `json:"name"`
}

func RegisterCreateProject(s *mcpsdk.Server, uc *app.CreateProjectHandler) {
    s.AddTool(mcpsdk.Tool{
        Name:        "create_project",
        Description: "Create a new project for the given tenant.",
        InputSchema: mustSchema(CreateProjectInput{}),
        Handler: func(ctx context.Context, raw json.RawMessage) (mcpsdk.ToolResult, error) {
            var in CreateProjectInput
            if err := json.Unmarshal(raw, &in); err != nil {
                return mcpsdk.ErrorResult(err), nil
            }
            resp, err := uc.Handle(ctx, app.CreateProjectCommand{
                TenantID: app.TenantID(in.TenantID),
                Name:     in.Name,
            })
            if err != nil {
                return mcpsdk.ErrorResult(err), nil
            }
            return mcpsdk.JSONResult(resp), nil
        },
    })
}
```

**Rules:**
- **InputSchema** is JSON Schema. Generate from the input struct via `jsonschema-go` or
  hand-write. The schema is what the LLM sees to know how to call the tool.
- **Description** is the LLM's primary signal for *when* to call the tool. Write it as
  precise, action-oriented prose ("Create a new project for the given tenant. Returns the
  project id.").
- **The handler is thin** — bind, dispatch, return.
- **Errors are returned as `ToolResult` with `isError: true`** — the LLM can recover; a Go
  error here aborts the whole protocol session.

## Authoring a prompt

A prompt is a parametrized template the client can fetch and render:

```go
s.AddPrompt(mcpsdk.Prompt{
    Name:        "summarize_project",
    Description: "Summarize a project's recent activity.",
    Arguments: []mcpsdk.PromptArgument{
        {Name: "project_id", Description: "UUIDv7 project id", Required: true},
    },
    Handler: func(ctx context.Context, args map[string]string) (mcpsdk.PromptResult, error) {
        id := args["project_id"]
        // Fetch context, render the prompt text.
        return mcpsdk.PromptResult{
            Messages: []mcpsdk.PromptMessage{
                {Role: "user", Content: mcpsdk.TextContent("Summarize project " + id + " ...")},
            },
        }, nil
    },
})
```

## Authoring a resource

A resource is read-only data — files, DB rows projected as JSON, etc. Identified by a URI:

```go
s.AddResource(mcpsdk.Resource{
    URI:         "{{ProjectName}}://projects/{id}",
    Name:        "Project",
    Description: "A project's full state, including recent events.",
    MIMEType:    "application/json",
    Handler: func(ctx context.Context, uri string) (mcpsdk.ResourceContent, error) {
        id := extractID(uri)
        proj, err := uc.Get(ctx, app.GetProjectQuery{ID: app.ID(id)})
        if err != nil { return mcpsdk.ResourceContent{}, err }
        return mcpsdk.JSONResource(proj), nil
    },
})
```

## Testing

- **Unit-test the handlers** — they're just functions taking a context + struct, returning
  a struct. Same patterns as the use cases.
- **Integration-test the full protocol round-trip** using the SDK's test harness or by
  launching the binary and writing JSONRPC framing manually. The MCP spec is JSONRPC 2.0
  over the transport.
- **Conformance test**: run the MCP Inspector
  (https://github.com/modelcontextprotocol/inspector) against your binary; it tries every
  tool and resource and reports issues.

## Hosting (HTTP transport)

If the MCP server is part of the API (e.g. an agentic feature exposes it to internal LLM
callers), mount it on the Gin router:

```go
// in cmd/api/main.go
mcpServer := mcpsdk.NewServer(...)
projects.RegisterTools(mcpServer, deps.Projects)
r.GET("/v1/mcp/projects/sse", mcpsdk.GinSSEHandler(mcpServer))
```

Auth is the SAME middleware stack as the rest of the API (JWT → tenancy). MCP clients
authenticate via OAuth (spec-defined) or the LLM platform's credential mechanism.

## Hard rules

- **Don't duplicate logic.** Tools call existing use cases.
- **Authz on every tool call.** The tool runs in the user/tenant context; assert the
  caller is permitted.
- **No secrets in tool inputs or outputs.** A tool that exposes an API key in its result
  is a leak.
- **Bounded execution.** Every tool takes `ctx`; the server enforces a per-tool timeout.
- **Idempotency where possible** — a tool that mutates should be safe to retry.
- **Versioning.** When you change a tool's schema, bump the server version. MCP clients
  cache schemas.

## What this skill does NOT do

- Authoring MCP **clients** (the LLM provider's SDK does that — see `claude-api`).
- Hosting on protocols other than stdio / HTTP — those are spec-extensions and need
  per-module approval.
