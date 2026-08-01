# herdr-goto

A [sessionx](https://github.com/omerxx/tmux-sessionx)-style **workspace switcher for [Herdr](https://herdr.dev)** — one `fzf` popup, bound to `prefix+o`, that fuzzy-finds across your open workspaces, the coding agents running in them, and their panes, and jumps you there. It replaces Herdr's built-in `goto` tree navigator.

Single Bash script (`goto.sh`) + `fzf` + `jq`. No compiled binary. Catppuccin Mocha themed.

---

## What it does

Open with `prefix+o`. You land in the **workspaces** scope with the *previously-focused* workspace pre-selected, so `prefix+o` then `Enter` is an instant alt-tab between two workspaces. Type to fuzzy-match a workspace **by name**.

Three scopes, cycled with `Tab` (or jumped to directly):

| Scope | Shows | `Enter` |
|-------|-------|---------|
| **workspaces** (default) | open workspaces, each with its agents nested underneath | switch to workspace / jump to agent |
| **agents** | every running agent, grouped under its workspace | jump to the agent's pane |
| **panes** | every pane, grouped under its workspace | focus that pane |

Agent state shows as a glyph: working `●` (yellow), idle `○` (green), blocked `◆` (red). A workspace containing a blocked agent gets a red `◆` on its row.

## Keys

Inside the popup:

| Key | Action |
|-----|--------|
| `Enter` | switch workspace / jump to agent or pane |
| `Tab` / `Shift-Tab` | cycle scope forward / back |
| `alt-w` / `alt-a` / `alt-p` | jump straight to workspaces / agents / panes |
| `↑` / `↓` | move (skips group headings) |
| `ctrl-n` | create a **new** workspace named by the current query |
| `ctrl-x` | kill (close) the highlighted workspace |
| `ctrl-r` | rename the workspace |
| `ctrl-o` / `ctrl-/` | toggle the preview pane |
| `Esc` | close |

The preview pane (right) shows a live capture of the selected workspace / agent / pane, with a compact header.

## Install

**Dependencies:** `herdr` (≥ 0.7), `fzf` (≥ 0.44; developed on 0.58), `jq`. Preview uses `eza` if present. A Nerd Font for the glyphs.

1. Clone the repo and put the script on your `$PATH` as `herdr-goto`, so the Herdr popup can call it by bare name:
   ```sh
   git clone https://github.com/imsalik/herdr-goto ~/.local/share/herdr-goto
   ln -sf ~/.local/share/herdr-goto/goto.sh ~/.local/bin/herdr-goto
   ```

2. Bind it as a popup in `~/.config/herdr/config.toml`:
   ```toml
   [keys]
   goto = "prefix+i"          # optional: move the built-in tree navigator off prefix+o

   [[keys.command]]
   key = "prefix+o"
   type = "popup"
   command = "herdr-goto"
   description = "goto (workspace switcher)"
   width = "90%"
   height = "85%"
   ```

## Development

Internals and the `fzf` constraints that shaped the code live in [DESIGN.md](DESIGN.md).
