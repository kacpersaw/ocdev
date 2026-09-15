# Snapshot-based recipes and projects for ocdev

## Purpose

Provide one CLI for creating, configuring, operating, inspecting, and deleting local development environments. Recipes add reusable project orchestration to ocdev's existing Incus lifecycle.

The implementation and reference documentation are in [Recipes and projects](../recipes.md). Unit and fake-Incus tests verify the generic workflow. Public example definitions are schema-validated templates; no live application compatibility is claimed.

## Scope

- CLI only, with `--json` for noninteractive management commands.
- Existing `container/snapshot` sources, using ocdev's current clone implementation.
- Versioned YAML/JSON recipes, local registration, and pinned recipe revisions.
- Project definitions with explicit local file references and nonsecret defaults.
- Named command/Taskfile tasks, typed inputs, timeouts, and ordered lifecycle hooks.
- Setup reruns, operation history, bounded private logs, and deletion previews.
- Optional process-compose service control.

No new container build engine, image-based recipe source, snapshot-management commands, dashboard, server, cloud-resource provider, or agent-session manager is included. Application-specific behavior belongs in separately maintained recipes and scripts.

## Architecture

Extend the existing Nim executable and reuse its container lifecycle procedures directly. Keep the implementation separated by responsibility:

| Module | Responsibility |
| --- | --- |
| `recipes.nim` | Strict definition parsing, validation, canonical SHA-256 revisions, and local recipe registry. |
| `recipe_exec.nim` | Argument-safe, bounded subprocess input/output and timeouts. |
| `recipe_engine.nim` | Snapshot preflight, pinned environment state, seed delivery, tasks/hooks, services, and operation history. |
| `recipe_cli.nim` | Command routing, argument validation, human/JSON presentation, and error handling. |
| `automation.nim` | Public instance/port projections and isolation of legacy subprocess output. |
| Existing lifecycle modules | Incus creation/cloning, ports, provisioning, and ordinary environment management. |

Incus remains authoritative for instance existence and running status. Local state records recipe provenance and operation outcomes. Saved UUIDs prevent applying an old environment record to a replacement instance with the same name.

## Definitions

### Recipe

A recipe declares `schemaVersion`, `id`, `name`, an existing snapshot source, and named tasks. Optional fields define ordered `afterCreate`/`beforeDelete` hooks and process-compose configuration.

Tasks execute inside the environment as `dev`, using an executable and argument array or a Taskfile target. Inputs are typed and passed as JSON on stdin; they are not interpolated into shell strings. Shell syntax requires an explicit shell invocation.

Definitions reject unknown fields, unsupported versions, invalid paths and references, duplicate mapping keys, YAML aliases, and excessive size/nesting. Secret inputs cannot have stored defaults or choices. Before creation, both lifecycle hook lists must have satisfiable inputs because hooks cannot prompt.

Registration stores immutable recipe revisions plus an ID pointer. Existing environments retain their resolved recipe rather than silently following later registry changes. A recipe digest identifies configuration, not the contents of network downloads or external scripts.

### Project

A project selects exactly one recipe reference and declares seed files and optional nonsecret task defaults. Relative host paths resolve against the project definition, not the caller's working directory.

Use an explicitly selected project file. There is no automatic discovery, local override merge, or new port-binding schema; existing binding commands remain available.

Required file availability is checked before cloning. Seed contents travel through stdin and are written to private temporary files before final permissions and atomic replacement. Local file delivery is not a secrets manager.

## Lifecycle

### Creation and setup

1. Validate recipe and project definitions, required files, and hook inputs.
2. Check the existing source snapshot and supported clone storage.
3. Reserve ports atomically and clone with fresh proxy assignments.
4. Record the instance identity and pinned configuration.
5. Deliver project files and run ordered setup hooks.
6. Optionally start the declared supervisor.
7. Record success or failure, retaining failed setup environments for inspection.

`setup --rerun` deliberately repeats setup against the saved project references. It can overwrite configuration and repeat external side effects; it is not automatic safe resume.

Snapshots are trusted inputs and may contain application data, credentials, mounts, or startup behavior. Cloning is not sanitization. No new mount/provisioning policy system is introduced.

### Deletion and recovery

Deletion previews owned resources, checks identity, and executes declared cleanup hooks before deleting the target instance. Hook failures stop deletion and retain diagnostic state.

An authoritative query confirming an already missing instance permits metadata-only reconciliation, with unavailable hooks recorded as skipped. Backend errors are not evidence of absence. A replacement UUID still blocks deletion.

The source snapshot, its backing container, and externally managed resources are never implicitly deleted by lifecycle cleanup.

## CLI and automation

Representative commands:

```sh
ocdev recipe validate ./recipe.yaml --json
ocdev recipe add ./recipe.yaml --json
ocdev recipe list --json
ocdev recipe show example --json
ocdev project validate ./project.yaml --json

ocdev create demo --project ./project.yaml --dry-run --json
ocdev create demo --project ./project.yaml --json
ocdev inspect demo --json
ocdev task run demo test --json
ocdev setup demo --rerun --json
ocdev runs list demo --json
ocdev runs show <run-id> --json
ocdev runs logs <run-id> --tail 100 --json

ocdev services list demo --json
ocdev services start demo --json
ocdev services restart demo api --json
ocdev services logs demo api --tail 100 --json
ocdev doctor --json
ocdev delete demo --dry-run --json
ocdev delete demo --json
```

Automation rules:

- Preserve the existing `list --json` schema, null/empty semantics, and lack of state initialization.
- Emit one complete JSON document on successful stdout, without progress or subprocess output.
- Return arrays for lists and public objects for inspections/mutations.
- Fail nonzero with empty stdout and a sanitized error object on stderr; recorded failures include an operation ID.
- Preserve existing numeric exit-code meanings. Record raw task exit status in operation metadata.
- Keep mutations synchronous; starting work is not proof of completion.
- Make dry-run free of resource mutation, hook execution, reservations, and state writes; predicted allocations are provisional.
- Do not treat `--json` as consent or unexpectedly prompt during automation.
- Keep raw configuration, secret inputs, seed contents, and task output out of public metadata projections.
- Retrieve bounded task/service logs explicitly and label them sensitive. Redaction is best-effort, not a guarantee that arbitrary output is publishable.
- Apply recipe hooks and locks consistently across human/JSON output and accepted legacy command spellings.

## Implementation sequence

### 1. CLI and lifecycle foundation

Introduce structured results/errors, safe execution helpers, unique temporary files, atomic reservations, accurate hook failure reporting, and JSON support for existing commands. Preserve existing list JSON behavior and ordinary environments.

### 2. Recipe definitions and registration

Implement strict YAML/JSON parsing, validation, local registration/list/show, canonical revisions, and side-effect-free inspection. Basic definitions require no cloud service, agent tool, or live daemon for file validation.

### 3. Project creation and task orchestration

Add snapshot-backed recipe/project creation, atomic seed delivery, shared task execution, hooks, explicit reruns, operation history/logs, and deletion previews/recovery. Test missing files/snapshots, failed hooks, secret inputs, UUID mismatch, and source preservation.

### 4. Service control and examples

Add optional process-compose operations and bounded logs. Keep container state, process status, and application readiness distinct; report unknown readiness honestly. Supply generic Node/Redis and Python/PostgreSQL templates, with documented snapshot/application prerequisites.

### 5. Application-owned adoption

Application maintainers keep their own recipe/project files, secrets, service configuration, and business-specific scripts outside the public repository. Start with schema validation and a disposable-environment dry-run. Live adoption requires verified configuration, dependencies, and resource ownership; preparing a pack alone is not live verification.

Do not automatically migrate existing state or adopt/delete external databases. Additional resource integrations, reports, and disposable-task convenience commands require separate scope decisions.

## Verification and release boundaries

`make test` runs unit and isolated fake-Incus tests without contacting a live daemon. Coverage includes schema strictness, paths/defaults, registry revisions, command arguments, JSON contracts, concurrent allocation, failed/interrupted operations, atomic seed replacement, identity checks, service projections, and legacy compatibility.

`make test-live` is separately opt-in, requires an explicitly selected trusted test recipe/task, and uses existing prepared snapshots. It requests ordinary cleanup rather than bypassing failed hooks. No live smoke test has been run as part of this implementation.

Public-release review must cover tracked changes and new files, not just the tracked diff. Keep local agent/runtime state and real environment files ignored. Use synthetic test data and clearly marked dummy credentials only; never include private projects, workstation paths, private endpoints, credentials, or internal migration notes in public artifacts.

The maintained YAML parser is a deliberate dependency. Release builds remain standalone Nim executables without a Node/Python runtime requirement. An explicit binary-size budget and CI tests cover packaging changes.
