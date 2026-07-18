---
name: marketplace
description: Browse the Tireless marketplace and install tools onto a workspace. Use when the user asks "what can I install", "browse the marketplace", "set up a Minecraft server", "install X on my VM", wants to add a tool/app/agent CLI to their Tireless cloud dev computer, or asks how a running install is going. Browsing is read-only; renting or purchasing marketplace hardware never happens through chat — that is dashboard-only.
allowed-tools: Bash(tireless-verify*), Bash(tireless list*), Bash(tireless ping*)
---

# Marketplace & installs on a Tireless workspace

Two read-only catalogs (marketplace listings, installable recipes) and one
mutation (`tireless_install_app`). The same ground rules as every tireless
skill apply: tokens never in chat, lifecycle only via
`tireless_workspace_action`, no Coder API.

## Ground rules (non-negotiable)

- **No purchases through chat.** There is deliberately NO
  rent/purchase/checkout tool — browsing is read-only. When the user wants
  to rent a listing, send them to the dashboard:
  `https://app.tirelesscode.com/dashboard/marketplace` (one listing:
  `/dashboard/marketplace/<slug>`). Never try to simulate a purchase via
  ssh, CLI, or API.
- **Revealed secrets go to the user, verbatim, immediately.** An install may
  return `revealedParams` — secret values (admin passwords, API keys) the
  platform shows exactly ONCE. Relay them to the user word-for-word in the
  same reply; never store them in files, briefs, or notes, never echo them
  into remote shells or logs, and never ask the platform to show them again
  — it won't.
- **Installs need the owner and a ready VM.** Only the workspace owner can
  install. Not connected yet → connect skill first. Suspended → resume via
  `tireless_workspace_action` `{"action":"resume"}` and follow
  `tireless_watch_state` until ready.

## Browse the marketplace (read-only)

- `tireless_marketplace_browse {query?, category?, limit?}` — published
  listings. Start broad, then narrow with `query`/`category`; keep `limit`
  small and summarize a shortlist — don't dump the catalog into chat.
- `tireless_marketplace_listing {slug}` — one listing's full details
  (description, specs, pricing). Read it before recommending anything.

Quote prices exactly as returned, and end marketplace answers with the
dashboard link — that is where renting happens.

## Installable tools & apps (read-only)

`tireless_recipes_catalog {query?, category?}` — the catalog of tools/apps
installable onto a workspace (agent CLIs, dev tools, game servers, ...).
This answers "what can I install"; each entry carries the `recipe_id` and
the params an install accepts.

## Install a tool (mutation)

`tireless_install_app {workspace, recipe_id, params?}`:

1. Resolve the workspace (`tireless_list_workspaces`; ask only when more
   than one matches) and make sure it is ready — see the ground rules.
2. Find the `recipe_id` in `tireless_recipes_catalog` — never guess ids.
3. Tell the user what you are about to install and where, then call the
   tool. Pass only params the catalog entry documents.
4. If the result contains `revealedParams`, relay them per the ground rule —
   before anything else in your reply.

"Set up a Minecraft server" = install the minecraft recipe here, then open
the game port via the workspace skill's `tireless_game_port` flow — that
step exposes raw TCP to the internet, so it has its own explicit-consent
rule; never open it as a side effect of the install.

## Follow an install (read-only)

`tireless_install_status {workspace, install_id?}` — always returns the
workspace's install list, newest first; passing `install_id` additionally
fetches that install's log tail. Poll it after `tireless_install_app` until
the install lands, and quote the log tail (not the whole log) when
something fails.
