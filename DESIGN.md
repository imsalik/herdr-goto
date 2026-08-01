# herdr-goto — design notes

Internals and the hard-won `fzf` constraints that shaped the code. If you hack on `goto.sh`, read this first.

## Architecture

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

- **agents / panes scopes** (`build_inventory` → `render_grouped`): `fzf`'s search is **disabled**; typing fires `change:reload-sync` which re-runs `render_grouped` over the cached `INV_FILE`. That function fuzzy-filters the inventory itself (`fzf --filter="$FZF_QUERY" --nth=1`), regroups survivors by workspace, and paints the workspace name once as a `hdr` heading row with members indented beneath. Because the script owns rendering, the label appears once yet survives filtering (see gotcha 3).

### Cursor skip (grouped scopes)

`fzf` has no non-selectable rows, so heading (`hdr`) rows are skipped by **rebinding `↑`/`↓`** to `--nav`, which reads `HDR_FILE` and emits `pos(N)` to jump straight to the next/previous non-heading row (never landing on a heading, no flicker). In the workspaces scope `--nav` just emits the built-in `up`/`down`. On entering a grouped scope (and after each filter) the cursor is sent to the first child via `+first+down`.

### Scope switching

`Tab`/`alt-*` call `--scope`, which writes `SCOPE_FILE` and prints an `fzf` action string (via `transform`): toggle `enable-search`/`disable-search`, `rebind`/`unbind(change)`, update the prompt + header tab-strip, `reload` the list, reposition. `reload-sync` is used for grouped scopes so `+first+down` runs after the new list is loaded.

### Actions

`Enter` → `become` (fzf exits, then) `--open`: `workspace focus` / `agent focus` / pane focus (`workspace focus` → `tab focus` → `pane zoom --on`/`--off`, since Herdr has no focus-pane-by-id). `ctrl-n` → `--create-named` from the query. `ctrl-x` → `--kill`. `ctrl-r` → `become --rename` (must be `become`, not `execute` — see gotcha 4). Every focus records the target workspace into `MRU_FILE`.

### Why it's a popup, not a plugin action

`goto` is launched by a `type = "popup"` keybinding that runs the script directly in the popup's terminal. It is deliberately **not** wired through `herdr plugin action invoke` (the way pane/tab plugins like `herdr-file-viewer` are): that call is a background dispatch with no tty, so `fzf` fails with `inappropriate ioctl for device`. A popup tool must own the terminal. The `herdr-plugin.toml` in this repo only registers the plugin for `herdr plugin list`; the popup binding is what launches the UI.

## fzf gotchas

Hard-won constraints, and the reason the code looks the way it does. If you refactor, keep them:

1. **`--with-nth` collapses the shown fields into one blob for search.** With `--with-nth=5` you cannot then use `--nth` to search a *sub-part* of the displayed text — `--nth` indexes the post-`--with-nth` line (a single field), so `--nth=5` is out of range and matches nothing. Consequence: **workspace rows carry no path text at all** (name only), because anything shown in field 5 is searchable and we do not want path/branch fuzzy-matches. The path lives only in the preview.

2. **You cannot have a non-selectable row.** Any line the cursor can reach, it will stop on. Two ways to get "group headings":
   - Emit `hdr` rows and rebind `↑`/`↓` to jump over them (`pos()` + a file of heading indices). **This is what the code does.** Robust, no flicker.
   - A `focus:transform` that emits `up`/`down` when landing on a header. **Abandoned** — it flickers (header shows for a frame) and needs direction inference that stutters on up-navigation.

3. **Grouped-but-filterable lists:** disable fzf's search (`disable-search`), bind `change:reload`, and do the filtering + grouping yourself in the reload script (`fzf --filter` for scoring, then regroup). Lets you paint a group label once and keep it under filtering. (The alternative — repeating the workspace name on every row — was rejected as noisy.)

4. **`become` vs `execute` for interactive prompts.** A `read`/prompt bound via `execute` runs while fzf still holds the terminal in raw mode, so arrow/escape bytes arrive as literal `^[` garbage. Use `become` (fzf exits first → cooked terminal) for rename/create-named. Trade-off: `become` closes the popup.

5. **`reload-sync` + `first` + `down`** to deterministically land on the first child after a scope switch or filter (plain `reload` is async; the reposition can run against the old list).

6. **MRU is the tool's to track.** Herdr exposes `focused` but no focus *history*, so "previous workspace" only knows about switches made *through goto* (`mru_push` runs on every focus action). Switching by other means won't update it. Good enough for the alt-tab use case.

7. **Testing quirk (not a bug):** in `zsh`, unquoted `$var` does not word-split, so `herdr-goto --nav $args` passes `"down 2"` as one arg. fzf passes `{n}` as its own arg, so real usage is fine — test with literal separate args.

8. **Herdr CLI shapes** worth knowing: `agent get` nests the agent at `.result.agent` (not `.result`); `agent list`/`pane list` items live at `.result.agents[]`/`.result.panes[]`; a workspace's root cwd is its *first* pane's `cwd` (later panes may be at `$HOME`). Pane content only reads from `--source visible` (agents/shells run on the alternate screen, so `recent` is empty).
