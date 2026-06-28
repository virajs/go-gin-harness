# Security Policy

## Reporting a vulnerability

If you discover a security vulnerability in `go-gin-harness`, **please do not open a
public GitHub issue.** Instead, report it privately so the maintainers can investigate
and ship a fix before public disclosure.

### How to report

- **Email**: viraj2005@gmail.com  *(replace with a dedicated security alias if/when available)*
- **GitHub private vulnerability report**: use [GitHub's Security Advisory feature](https://github.com/virajs/go-gin-harness/security/advisories/new) on this repo.

### What to include

- A clear description of the vulnerability and its impact.
- Steps to reproduce (or a minimal proof-of-concept).
- The plugin version (`claude plugin list` output) where you observed it.
- Any suggested mitigation, if you have one in mind.

### What you can expect

- Acknowledgement within **3 business days**.
- A status update on triage and intended fix timeline within **7 business days**.
- Credit in the release notes (unless you prefer to remain anonymous).
- For confirmed vulnerabilities, a coordinated disclosure timeline — typically 30–90
  days depending on severity.

## Scope

In scope:

- The **plugin manifest, agents, workflows, skills, hooks, and commands** distributed in this repo.
- The **per-repo template** that the bootstrap skill installs into target projects.
- Any **shell or generation step** the plugin invokes that could be subverted (hook
  scripts, Makefile targets shipped in the template).

Out of scope:

- Vulnerabilities in **upstream tools** the harness recommends or invokes
  (`golangci-lint`, `gofumpt`, `goimports`, `govulncheck`, `sqlc`, `goose`, Anthropic's
  Claude Code CLI, etc.) — report those to the respective projects.
- **Token misuse** by AI agents during a `/run-impl-loop` (this is a design
  concern handled by the multi-layer review model, not a security defect).
- **User-introduced misconfigurations** of permissions, hooks, or rules in a
  bootstrapped repo (e.g. disabling the protect-commands hook). The harness ships
  conservative defaults; downstream changes are the operator's responsibility.
- **Prompt-injection** vectors arising from user-supplied content the agents process
  — these are an inherent property of LLM agents and should be treated at the
  operator's threat-model level. See the harness's `permissions.deny` defaults +
  hooks as the primary mitigations.

## Hardening recommendations for operators

If you operate the harness in a sensitive environment:

1. **Review the `permissions.deny` list** in your repo's `.claude/settings.json`. The
   default denies reads of `.env`, `secrets/**`, `*.pem`, `*.key`. Add anything
   sensitive to your codebase.
2. **Keep the `protect-commands.sh` hook enabled** unless you have an explicit reason
   not to. It gates destructive shell at the tool-call layer.
3. **Run `govulncheck ./...`** as part of `make ci`. The harness wires this by default;
   don't disable it.
4. **Pin the plugin version** in your install command (`claude plugin install
   go-gin-harness@<version>`) if you want to opt out of auto-updates for review-before-
   upgrade workflows.
5. **Review agent prompts** in `agents/*.md` before adopting in regulated environments.
   They are plain Markdown and shouldn't contain anything sensitive, but verify against
   your org's policy.

## Supported versions

Pre-1.0, only the latest minor version is supported for security fixes. Once v1.0
ships, the previous minor remains supported for 6 months alongside the current minor.

| Version | Supported |
|---|---|
| 0.1.x | ✅ |
| < 0.1 | ❌ |
