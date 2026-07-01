---
description: Generate a VS Code .vscode/launch.json for debugging this Go/Gin project with Delve — one launch config per cmd/ entrypoint, plus debug-test / debug-current-file / attach. Detects entrypoints and .env from the real repo layout.
allowed-tools: Read, Glob, Grep, Bash, Write, Edit
argument-hint: "[entrypoint] (optional cmd path, e.g. cmd/api — omit to include all)"
---

The user wants a VS Code debug configuration (`.vscode/launch.json`) for this Go/Gin
project. Debugging Go uses the `go` debug type (Delve via the Go extension).

Procedure:

1. **Detect entrypoints.** Glob `cmd/*/main.go` (and a top-level `main.go` if present).
   Each `main.go` package dir is one launchable program. If `$ARGUMENTS` names a
   specific path (e.g. `cmd/api`), scope to that one; otherwise include every entrypoint.
   If none are found, tell the user (this harness expects `cmd/<name>/main.go`) and stop.

2. **Detect an env file.** If `.env` exists at the repo root, reference it via
   `"envFile": "${workspaceFolder}/.env"` on the server config(s). If not, omit `envFile`
   rather than pointing at a missing file.

3. **Build the configurations.** For each entrypoint, emit a `launch`/`mode: debug`
   config with `"program": "${workspaceFolder}/cmd/<name>"`. Then always add:
   - **Debug current file** — `mode: debug`, `program: "${file}"`
   - **Debug package tests** — `mode: test`, `program: "${fileDirname}"` (debugs the
     test in the currently open dir; works with the race detector via `"args": ["-test.v"]`)
   - **Attach to process** — `request: attach`, `mode: local`,
     `processId: "${command:pickProcess}"`

   Skeleton (adapt names/entrypoints to the real repo):
   ```json
   {
     "version": "0.2.0",
     "configurations": [
       {
         "name": "Debug api server",
         "type": "go",
         "request": "launch",
         "mode": "debug",
         "program": "${workspaceFolder}/cmd/api",
         "envFile": "${workspaceFolder}/.env",
         "args": []
       },
       {
         "name": "Debug current file",
         "type": "go",
         "request": "launch",
         "mode": "debug",
         "program": "${file}"
       },
       {
         "name": "Debug package tests",
         "type": "go",
         "request": "launch",
         "mode": "test",
         "program": "${fileDirname}",
         "args": ["-test.v"]
       },
       {
         "name": "Attach to process",
         "type": "go",
         "request": "attach",
         "mode": "local",
         "processId": "${command:pickProcess}"
       }
     ]
   }
   ```

4. **Write the file.** Create `.vscode/` if needed and write `.vscode/launch.json`.
   If the file already exists, do NOT clobber it — Read it, merge the new configurations
   into the existing `configurations` array (match on `name`, replace stale duplicates),
   and preserve any unrelated configs the user already had.

5. **Report** the entrypoints detected, whether `.env` was wired in, and the final path.
   Remind the user that Delve debugging needs the Go extension + `dlv` on PATH
   (`go install github.com/go-delve/delve/cmd/dlv@latest`).

Do not hardcode `cmd/api` if the repo's entrypoint is named differently — always derive
names from the actual glob results.
