---
name: go-ai-stack
description: Wire LLM features into the Go API — provider abstraction, streaming (SSE), structured output (JSON schema), tool calling, prompt caching, evals. Use when adding or changing anything that talks to a model. Skip if the product doesn't use LLMs.
allowed-tools: Read, Glob, Grep, Edit, Write, Bash, Skill
---

# Go AI stack

The harness assumes a small, provider-agnostic adapter pattern. The product decides the
default provider (Anthropic / OpenAI / Gemini / Bedrock / etc.); the adapter abstracts
the wire format so the use cases stay portable.

If the LLM feature uses Anthropic specifically, the `claude-api` skill (installed) is the
authority for ids, pricing, prompt caching, tool use, MCP, etc. **Quote it over memory.**

## Adapter shape

```go
// internal/app/ai/client.go — interface declared by the consumers.
package ai

import "context"

type Message struct {
    Role    string // "user" | "assistant" | "system"
    Content string // simple text; for multimodal, extend with a Parts field
}

type CompleteRequest struct {
    Model       string
    System      string
    Messages    []Message
    MaxTokens   int
    Temperature float64
    Stop        []string
    Tools       []Tool        // optional, structured tool calls
    Stream      bool
    Cache       bool          // prompt caching hint (provider-specific)
}

type CompleteResponse struct {
    ID           string
    Model        string
    Content      string
    StopReason   string
    InputTokens  int
    OutputTokens int
    Cost         float64       // computed by the adapter from token counts + price table
}

type StreamEvent struct {
    Type    string // "delta", "tool_use", "stop", "error"
    Delta   string
    ToolCall *ToolCall
    Err     error
}

type Client interface {
    Complete(ctx context.Context, req CompleteRequest) (*CompleteResponse, error)
    Stream(ctx context.Context, req CompleteRequest) (<-chan StreamEvent, error)
}
```

Implementations go in `internal/infra/ai/<provider>/`:

```go
// internal/infra/ai/anthropic/client.go
type AnthropicClient struct {
    apiKey string
    http   *http.Client
    prices PriceTable
}

func (c *AnthropicClient) Complete(ctx context.Context, req ai.CompleteRequest) (*ai.CompleteResponse, error) {
    // Map ai.Message → Anthropic JSON; call /v1/messages; map response.
}
```

Use the `claude-api` skill to write the Anthropic adapter — it has the up-to-date model
ids, payload shapes, and caching semantics.

## Streaming (SSE)

The API endpoint streams tokens via SSE:

```go
func chatHandler(uc *chat.SendHandler) gin.HandlerFunc {
    return func(c *gin.Context) {
        var req SendRequest
        if err := c.ShouldBindJSON(&req); err != nil {
            middleware.WriteBindError(c, err); return
        }
        tenant, _ := middleware.TenantFromContext(c.Request.Context())

        c.Writer.Header().Set("Content-Type",  "text/event-stream")
        c.Writer.Header().Set("Cache-Control", "no-cache")
        c.Writer.Header().Set("Connection",    "keep-alive")
        c.Writer.WriteHeader(http.StatusOK)
        flusher := c.Writer.(http.Flusher)

        events, err := uc.Handle(c.Request.Context(), chat.SendCommand{
            TenantID: tenant,
            Prompt:   req.Prompt,
        })
        if err != nil { writeSSEError(c, err); return }

        for ev := range events {
            switch ev.Type {
            case "delta":
                fmt.Fprintf(c.Writer, "event: token\ndata: %s\n\n", jsonEscape(ev.Delta))
            case "tool_use":
                fmt.Fprintf(c.Writer, "event: tool\ndata: %s\n\n", jsonMarshal(ev.ToolCall))
            case "stop":
                fmt.Fprintf(c.Writer, "event: done\ndata: {}\n\n")
            case "error":
                fmt.Fprintf(c.Writer, "event: error\ndata: %s\n\n", jsonMarshal(map[string]any{
                    "code": "stream_error", "message": ev.Err.Error(),
                }))
                flusher.Flush(); return
            }
            flusher.Flush()
            if c.Request.Context().Err() != nil { return } // client disconnected
        }
    }
}
```

**Rules:**
- `Content-Type: text/event-stream`. `Cache-Control: no-cache`. `Connection: keep-alive`.
- **Flush after each event.** Gin's `c.Writer` implements `http.Flusher`.
- **Honor cancellation.** Check `c.Request.Context().Err()`; cancelling propagates to the
  upstream client (the provider client also takes the same context).
- **Error frames as `event: error`** — not HTTP status changes. The status is already 200
  once streaming starts.
- **No buffering middleware** in the chain (a request-body recorder that wraps `c.Writer`
  with a buffered ResponseWriter breaks streaming).

## Structured output (JSON schema)

For deterministic JSON responses, use the provider's structured output / JSON mode.
Validate the model output against your schema; reject and re-prompt on validation failure.

```go
type ExtractionSchema struct {
    Title    string   `json:"title"`
    Author   string   `json:"author"`
    Keywords []string `json:"keywords"`
}

resp, err := client.Complete(ctx, ai.CompleteRequest{
    Model: "claude-sonnet-4-6",
    System: "Extract metadata. Respond ONLY with JSON matching the schema.",
    Messages: []ai.Message{{Role: "user", Content: doc}},
    MaxTokens: 1024,
})
if err != nil { return nil, err }

var out ExtractionSchema
if err := json.Unmarshal([]byte(resp.Content), &out); err != nil {
    return nil, fmt.Errorf("model output invalid JSON: %w", err)
}
// further validation: required fields, value ranges, allow-listed values
```

For higher reliability: send the JSON Schema in the request (Anthropic's tool-use, OpenAI's
JSON mode). See the `claude-api` skill for the Anthropic specifics.

## Tool calling

```go
type Tool struct {
    Name        string
    Description string
    Schema      json.RawMessage // JSON Schema for the parameters
}

type ToolCall struct {
    ID    string
    Name  string
    Input json.RawMessage
}
```

The handler dispatches tool calls back into your own use cases (`projects.Create`,
`projects.List`, etc.). Multi-turn loop: model emits tool_use → handler runs the tool →
sends tool_result message → model continues.

**Rules:**
- **Tools live in the same use-case interface as the API**, so the model's "tools" are
  the product's primitives. No parallel implementation.
- **Authz on every tool call.** The tool runs in the tenant context; assert the user is
  permitted to run it.
- **Time-bound tool execution.** A tool that hangs hangs the conversation. `context.
  WithTimeout` per tool call.

## Prompt caching

Provider-specific (Anthropic supports prompt caching with 5-minute TTL; OpenAI's
implementation differs). Use the `claude-api` skill for the Anthropic specifics — it
covers exactly which prefixes are cacheable and how to structure messages for best hit rate.

General pattern: long system prompt + tool definitions stay constant; vary only the user
turn. Cache the constant prefix; pay per-token only for the variable suffix.

## Evals

LLM features are tested with **evals**, not unit tests. See the `run-evals` skill and the
`eval-run` workflow.

- Dataset: `evals/<suite>/dataset.jsonl` — one case per line `{id, input, expected}`.
- Runner: `evals/<suite>/runner.go` — calls the feature against `case.input`.
- Grader: `evals/<suite>/grader.go` — scores the output (deterministic OR LLM-as-judge).
- Baseline: `evals/<suite>/baseline.json` — last-promoted scorecard; runs compare to it.

## Cost / token observability

The adapter emits metrics:

```
ai_request_tokens_total{provider="anthropic", model="...", direction="input"}
ai_request_tokens_total{provider="anthropic", model="...", direction="output"}
ai_request_cost_usd_total{provider="anthropic", model="..."}
ai_request_duration_seconds{provider="anthropic", model="..."}
ai_request_errors_total{provider="anthropic", model="...", code="..."}
```

Per-tenant labeling at the data-product scale, aggregate above that.

## Hard rules

- **No raw provider keys in source.** Env var or secrets manager.
- **No raw provider HTTP in `internal/app/`** — only the adapter interface.
- **Every model call takes `ctx`.** The request's deadline applies to the model call.
  Provider clients usually expose a context-aware method — use it.
- **Log redaction.** Don't log prompt text in `Info` level — it may contain customer data.
  Use `Debug` and redact in prod handlers.
- **Eval before promoting** — never ship a prompt change without an eval run, and never
  auto-promote the baseline.

## What this skill does NOT do

- Cover MCP server authoring (see the `mcp-go` skill).
- Cover vector search / RAG specifics (add when you adopt a vector store — pgvector
  on Postgres is the natural fit since we're already on Postgres).
- Replace the `claude-api` skill for Anthropic-specific behavior.
