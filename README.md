# herdr-goto

A [sessionx](https://github.com/omerxx/tmux-sessionx)-style **workspace switcher for [Herdr](https://herdr.dev)** — one `fzf` popup, bound to `prefix+o`, that fuzzy-finds across your open workspaces, the coding agents running in them, and their panes, and jumps you there. It replaces Herdr's built-in `goto` tree navigator.

Single Bash script (`goto.sh`) + `fzf` + `jq`. No compiled binary. Catppuccin Mocha themed.

> Status: personal dotfiles feature, working. **Planned:** extract to `~personal/` and publish as a proper Herdr plugin (own GitHub repo). This doc becomes the repo README. See [Roadmap](#roadmap).

---

## What it does

Open with `prefix+o`. You land in the **workspaces** scope with the *previously-focused* workspace pre-selected, so `prefix+o` then `Enter` is an instant alt-tab between two workspaces. Type to fuzzy-match a workspace **by name** (paths/branches are deliberately not matched — see [gotchas](#fzf-gotchas-notes-to-self)).

Three scopes, cycled with `Tab` (or jumped to directly):

| Scope | Shows | `Enter` |
|-------|-------|---------|
| **workspaces** (default) | open workspaces, each with its agents nested underneath (tree) | switch to workspace / jump to agent |
| **agents** | every running agent, grouped under its workspace | jump to the agent's pane |
| **panes** | every pane, grouped under its workspace | focus that pane (workspace → tab → pane) |

Agents/panes scopes render as **headings + indented children**: the workspace name appears once as a heading, members left-aligned beneath it. The cursor auto-skips heading rows (they're not selectable targets), and the heading survives filtering so a single match still shows which workspace it belongs to.

Agent state is shown by a glyph: working `●` (yellow), idle `○` (green), blocked `◆` (red) + the word `blocked`. A workspace with a blocked agent gets a red `◆` on its row.

## Keys

Inside the popup:

| Key | Action |
|-----|--------|
| `Enter` | switch workspace / jump to agent or pane |
| `Tab` / `Shift-Tab` | cycle scope forward / back |
| `alt-w` / `alt-a` / `alt-p` | jump straight to workspaces / agents / panes scope |
| `↑` / `↓` | move (skips heading rows in grouped scopes) |
| `ctrl-n` | create a **new** workspace named by the current query |
| `ctrl-x` | kill (close) the highlighted row's workspace |
| `ctrl-r` | rename the workspace (closes the popup — runs in cooked-mode) |
| `ctrl-o` / `ctrl-/` | toggle the preview pane |
| `Esc` | close |

Preview (right pane): for a workspace, a compact header (name · cwd, tabs on one line with state dots) then a live capture of the active pane; for an agent, its status/tokens/title then a live capture; for a pane, its location then a live capture.

## Install / wiring

The script lives in the dotfiles at `herdr/.config/herdr/goto.sh` and is used three ways:

1. **Stowed** to `~/.config/herdr/goto.sh` (symlink, like `config.toml`).
2. **On `$PATH`** as `herdr-goto` — a symlink `~/.local/bin/herdr-goto → ~/.config/herdr/goto.sh` — so the Herdr popup can call it by bare name (matching the `ports`/`kate` popups). Recreate on a fresh machine:
   ```sh
   ln -sf ~/.config/herdr/goto.sh ~/.local/bin/herdr-goto
   ```
3. **Bound** in `~/.config/herdr/config.toml`:
   ```toml
   [keys]
   goto = "prefix+i"          # built-in tree navigator moved here (was prefix+o)

   [[keys.command]]
   key = "prefix+o"
   type = "popup"
   command = "herdr-goto"
   description = "goto (workspace switcher)"
   width = "90%"
   height = "85%"
   ```

Dependencies: `herdr` (≥ 0.7), `fzf` (≥ 0.44 for `disable-search`/`change:reload`/`transform`/`pos()`; developed on 0.58), `jq`. Preview uses `eza` if present. Nerd Font for the glyphs.

---

## How it works (architecture)

The script is **self-reinvoking**: `fzf`'s source, preview, and action hooks all call `bash $SELF --<subcommand>`. Dispatch is a `case` on `$1` at the bottom; `$SELF` is the absolute path resolved at startup and exported.

### Per-popup state (temp files, exported)

Three `mktemp -u` paths, created once in the main invocation, exported so every self-reinvocation sees them, cleaned on `EXIT`:

- `SCOPE_FILE` — the current scope (`ws` | `agent` | `pane`). Read by `--list`, written by `--scope`.
- `INV_FILE` — cached raw inventory for the current grouped scope, so per-keystroke re-filtering doesn't re-hit `herdr`.
- `HDR_FILE` — line 1 = total rendered rows, following lines = 0-based indices of heading rows. Powers cursor-skip (`nav`).

`MRU_FILE` (`~/.local/state/herdr/goto-mru`) persists across popups: most-recently-focused workspace ids, newest first.

### Row model

Every final `fzf` row is TSV with 5 fields: `type ⇥ key ⇥ wsid ⇥ tabid ⇥ display`. `fzf` shows only field 5 (`--with-nth=5`). Action binds read `{1}..{4}` (type/key/wsid/tabid) to act; preview reads them too. `type` ∈ `ws` | `agent` | `pane` | `hdr`.

### Two rendering modes

- **workspaces scope** (`emit_ws_tree`): `fzf`'s own fuzzy search is **enabled**; it filters field 5 live. Rows are workspace headers (selectable, `Enter` = switch) with agent children nested. Ordering via `ordered_wids` (MRU, previous-first, focused-last).

- **agents / panes scopes** (`build_inventory` → `render_grouped`): `fzf`'s search is **disabled**; typing fires `change:reload-sync` which re-runs `render_grouped` over the cached `INV_FILE`. That function fuzzy-filters the inventory itself (`fzf --filter="$FZF_QUERY" --nth=1`), regroups survivors by workspace, and paints the workspace name once as a `hdr` heading row with members indented beneath. Because the script owns rendering, the label appears once yet survives filtering. This is the pattern the advisor recommended (see gotchas).

### Cursor skip (grouped scopes)

`fzf` has no non-selectable rows, so heading (`hdr`) rows are skipped by **rebinding `↑`/`↓`** to `--nav`, which reads `HDR_FILE` and emits `pos(N)` to jump straight to the next/previous non-heading row (never landing on a heading, no flicker). In the workspaces scope `--nav` just emits the built-in `up`/`down`. On entering a grouped scope (and after each filter) the cursor is sent to the first child via `+first+down`.

### Scope switching

`Tab`/`alt-*` call `--scope`, which writes `SCOPE_FILE` and prints an `fzf` action string (via `transform`): toggle `enable-search`/`disable-search`, `rebind`/`unbind(change)`, update the prompt + header tab-strip, `reload` the list, reposition. `reload-sync` is used for grouped scopes so `+first+down` runs after the new list is loaded.

### Actions

`Enter` → `become` (fzf exits, then) `--open`: `workspace focus` / `agent focus` / pane focus (`workspace focus` → `tab focus` → `pane zoom --on`/`--off`, since Herdr has no focus-pane-by-id). `ctrl-n` → `--create-named` from the query. `ctrl-x` → `--kill`. `ctrl-r` → `become --rename` (must be `become`, not `execute` — see gotchas). Every focus records the target workspace into `MRU_FILE`.

---

## fzf gotchas (notes to self)

Hard-won, and the reason the code looks the way it does. If you refactor, don't undo these:

1. **`--with-nth` collapses the shown fields into one blob for search.** With `--with-nth=5` you cannot then use `--nth` to search a *sub-part* of the displayed text — `--nth` indexes the post-`--with-nth` line (a single field), so `--nth=5` is out of range and matches nothing. Consequence: **workspace rows carry no path text at all** (name only), because anything shown in field 5 is searchable and we do not want path/branch fuzzy-matches. The path lives only in the preview.

2. **You cannot have a non-selectable row.** Any line the cursor can reach, it will stop on. Two ways to get "group headings":
   - Emit `hdr` rows and rebind `↑`/`↓` to jump over them (`pos()` + a file of heading indices). **This is what we do.** Robust, no flicker.
   - A `focus:transform` that emits `up`/`down` when landing on a header. **Abandoned** — it flickers (header shows for a frame) and needs direction inference that stutters on up-navigation. This is the "stutter" bug that drove the rewrite.

3. **Grouped-but-filterable lists:** disable fzf's search (`disable-search`), bind `change:reload`, and do the filtering + grouping yourself in the reload script (`fzf --filter` for scoring, then regroup). Lets you paint a group label once and keep it under filtering. (Advisor's call; the alternative — repeating the ws on every row — the user rejected.)

4. **`become` vs `execute` for interactive prompts.** A `read`/prompt bound via `execute` runs while fzf still holds the terminal in raw mode, so arrow/escape bytes arrive as literal `^[` garbage. Use `become` (fzf exits first → cooked terminal) for rename/create-named. Trade-off: `become` closes the popup.

5. **`reload-sync` + `first` + `down`** to deterministically land on the first child after a scope switch or filter (plain `reload` is async; the reposition can run against the old list).

6. **MRU is ours to track.** Herdr exposes `focused` but no focus *history*, so "previous workspace" only knows about switches made *through goto* (we `mru_push` on every focus action). Switching by other means won't update it. Good enough for the alt-tab use case.

7. **Testing quirk (not a bug):** in `zsh`, unquoted `$var` does not word-split, so `herdr-goto --nav $args` passes `"down 2"` as one arg. fzf passes `{n}` as its own arg, so real usage is fine — test with literal separate args.

8. **Herdr CLI shapes** that bit us: `agent get` nests the agent at `.result.agent` (not `.result`); `agent list`/`pane list` items live at `.result.agents[]`/`.result.panes[]`; a workspace's root cwd is its *first* pane's `cwd` (later panes may be at `$HOME`). Pane content only reads from `--source visible` (agents/shells run on the alternate screen, so `recent` is empty).

---

## Roadmap

- [ ] Extract to `~personal/herdr-goto/` and publish as a GitHub repo + proper Herdr plugin (`herdr-plugin.toml` with an action, like `herdr-file-viewer`), so it installs via `herdr plugin install`.
- [ ] Read colors from Herdr's `config.toml` theme instead of the hard-coded Catppuccin hex block.
- [ ] Nerd Font icons in headings/rows (folder/robot/etc.) — held off to avoid tofu; pick confirmed glyphs.
- [ ] Real **animated** working spinner. Not possible in a static fzf list (no redraw loop) — this is the strongest reason to eventually do a compiled TUI plugin, which would also give live-updating agent states.
- [ ] Optional: create-workspace-from-a-project-dir (a `dirs` scope existed briefly, removed as noise; revisit as an opt-in key if wanted).

## File map

- `goto.sh` — the whole thing (~425 lines). Sections: palette/helpers → list builders (`emit_ws_tree`, `build_inventory`, `render_grouped`, `nav`) → preview → actions (`open_entry`, `kill_ws`, `rename_ws`, `create_named`, `focus_pane`, `mru_push`) → scope switching → entry-point dispatch → the `fzf` invocation.
- `goto.md` — this doc.
- `config.toml` — the `prefix+o` popup binding + `goto = "prefix+i"`.
