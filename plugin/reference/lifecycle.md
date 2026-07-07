# Why lifecycle mutations via the CLI are forbidden

## The reconciler owns the truth

Tireless models every workspace as two fields in the platform database:
`desired_state` (what the user asked for) and `observed_state` (what actually
runs). A reconciler continuously drives reality toward `desired_state` —
provisioning, restarting, suspending, resuming, backing up, billing.

The `tireless` CLI is the stock Coder CLI (rebranded). It can talk directly
to the region's Coder control plane, which means `tireless start`,
`tireless stop`, `tireless delete`, `tireless create`, and raw Coder API
calls all mutate infrastructure BEHIND the reconciler's back:

- The platform still believes its own `desired_state`, detects the drift,
  and **fights or reverts the change** — your `stop` gets undone, your
  `start` re-suspended.
- Billing, backups, suspend timers, and health checks key off platform
  state; out-of-band mutations desynchronize them.
- `delete` is worst-case: the platform-side record, backups, and billing
  survive while the VM state is gone — an inconsistent, support-ticket
  outcome.

**Rule: Coder credentials are for connectivity (ssh, editors, port proxy).
Lifecycle goes through the platform API.**

## What agents may do instead

| Intent | Correct path |
|---|---|
| restart / suspend / resume | `tireless_workspace_action` MCP tool (`{"action": "restart"\|"suspend"\|"resume"}`) — the platform updates `desired_state` and the reconciler does the work |
| follow a transition | `tireless_watch_state` until the target state |
| create | `tireless_create_workspace`, confirm-gated: no `confirm: true` without the user's explicit yes in the conversation (paid resources on their card) |
| delete | **nothing** — no tool, no CLI, no API. Deletion is dashboard-only, by the user, with typed confirmation |
| no MCP tools available | send the user to the dashboard |

The MCP surface enforces this server-side too: agent-scoped tokens get
`403 {"error": "agent_scope"}` on workspace deletion, billing, and admin
routes — the skill text and the server agree.
