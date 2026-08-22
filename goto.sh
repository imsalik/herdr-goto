#!/usr/bin/env bash
# herdr-goto — a sessionx-style workspace switcher for Herdr.
#
# Launch scope: defaults to workspaces; pass a bare scope arg (or set GOTO_SCOPE)
# to open straight into that scope, e.g. `herdr-goto agent`.
#
# One fzf popup, three scopes (Tab cycles; alt-w/a/p jump directly):
#   • workspaces (default) — MRU-ordered, previous first, so popup+Enter = alt-tab.
#       Project dirs are folded in as "+ create here" candidates. Agent presence
#       is badged onto the workspace row (2✻) instead of listed separately.
#   • agents — every running coding agent, grouped by state (blocked/working/
#       idle/done) with its workspace shown inline; Enter jumps to its pane.
#   • panes  — every pane (ws:tab); Enter focuses it.
# Enter switches/creates/jumps · ctrl-x kill workspace · ctrl-r rename · ctrl-n
# new named workspace (from the typed query) · ctrl-o toggle preview.
#
# Bound to prefix+o via a [[keys.command]] popup in config.toml. The script
# re-invokes itself for fzf's source/preview/action hooks so it stays one file.
set -uo pipefail

herdr="${HERDR_BIN_PATH:-herdr}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/herdr"
MRU_FILE="$STATE_DIR/goto-mru"          # most-recently-focused workspace ids, newest first
SCOPE_FILE="${SCOPE_FILE:-}"            # per-popup current scope; exported before fzf launches

# "Create a workspace here" candidate roots. Left empty on purpose: roots are
# DERIVED at runtime from where your open workspaces already live (the parent of
# each open workspace's dir, or the dir itself when that parent is $HOME). Add
# paths here only to pin extra roots that no open workspace would reveal.
ROOTS=()

# ── Catppuccin Mocha palette (truecolor) ────────────────────────────────────
RESET=$'\e[0m'; BOLD=$'\e[1m'
MAUVE=$'\e[38;2;203;166;247m'   # workspaces  (#cba6f7)
PINK=$'\e[38;2;245;194;231m'    # agents      (#f5c2e7)
GREEN=$'\e[38;2;166;227;161m'   # ok/focused  (#a6e3a1)
YELLOW=$'\e[38;2;249;226;175m'  # working     (#f9e2af)
RED=$'\e[38;2;243;139;168m'     # blocked     (#f38ba8)
BLUE=$'\e[38;2;137;180;250m'    # dirs/panes  (#89b4fa)
DIM=$'\e[38;2;127;132;156m'     # meta        (#7f849c)
TAB=$'\t'

# Entity icons, prefixed before a name so the kind reads at a glance. Swap here.
WS_ICON='▦'    # workspace
TAB_ICON='❐'   # tab
PANE_ICON='◫'  # pane

tilde() { case "$1" in "$HOME"/*) printf '~/%s' "${1#"$HOME"/}";; "$HOME") printf '~';; *) printf '%s' "$1";; esac; }

agent_glyph() {  # state glyph (static: fzf can't animate a list — filled = active)
  case "$1" in
    working)  printf '%s●' "$YELLOW";;   # active
    blocked)  printf '%s◆' "$RED";;
    idle|done)printf '%s○' "$GREEN";;    # ready
    *)        printf '%s✻' "$PINK";;
  esac
}
agent_label() {  # trailing text: only blocked gets a word (working conveys via glyph)
  case "$1" in blocked) printf '%sblocked' "$RED";; esac
}
agent_icon() {  # per-agent-type mark, shown instead of the agent-name word
  case "$1" in
    claude) printf '✻';;
    *)      printf '◈';;
  esac
}
# Bucket a raw agent_status into an ordered display group, and its accent color.
state_bucket() { case "$1" in blocked) printf blocked;; working) printf working;; idle) printf idle;; done) printf done;; *) printf other;; esac; }
state_color()  { case "$1" in blocked) printf '%s' "$RED";; working) printf '%s' "$YELLOW";; idle|done) printf '%s' "$GREEN";; *) printf '%s' "$DIM";; esac; }

read_scope() { local s; s="$(cat "$SCOPE_FILE" 2>/dev/null)"; printf '%s' "${s:-ws}"; }

# ── MRU tracking ─────────────────────────────────────────────────────────────
mru_push() {  # prepend a workspace id, deduped, capped
  local wid="$1" rest
  [ -n "$wid" ] || return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  rest="$(grep -vxF "$wid" "$MRU_FILE" 2>/dev/null | head -30)"
  { printf '%s\n' "$wid"; printf '%s\n' "$rest"; } | grep -v '^$' > "$MRU_FILE.tmp" 2>/dev/null \
    && mv "$MRU_FILE.tmp" "$MRU_FILE" 2>/dev/null
}

# ── List builder ─────────────────────────────────────────────────────────────
# Final fzf rows are TSV: 1=type 2=key 3=wsid 4=tabid 5=display(ansi); fzf shows
# field 5 (--with-nth=5). The default `ws` scope is a selectable workspace tree
# (search on names). The secondary scopes (agent/pane/dir) render grouped: fzf's
# own search is disabled and typing re-runs render_grouped, which fuzzy-filters
# an inventory then paints the group label (workspace/root) only on the first
# surviving row of each group — no selectable header rows, label survives filter.

# Workspace ids in MRU order: previous workspace first, focused one last, so the
# cursor opens on the workspace you'd alt-tab to. One id per line.
ordered_wids() {
  local ws_json="$1"
  declare -A LBL FOC; local order=() wid l f
  while IFS=$'\t' read -r wid l f; do
    [ -n "$wid" ] || continue; LBL[$wid]="$l"; FOC[$wid]="$f"; order+=("$wid")
  done < <(printf '%s' "$ws_json" | jq -r '.result.workspaces[]? | [.workspace_id, .label, (.focused|tostring)] | @tsv')
  declare -A SEEN; local out=() cur=""
  while IFS= read -r wid; do
    [ -n "$wid" ] || continue
    [ -n "${LBL[$wid]:-}" ] && [ -z "${SEEN[$wid]:-}" ] && { out+=("$wid"); SEEN[$wid]=1; }
  done < <(cat "$MRU_FILE" 2>/dev/null)
  for wid in "${order[@]}"; do [ -z "${SEEN[$wid]:-}" ] && { out+=("$wid"); SEEN[$wid]=1; }; done
  for wid in "${out[@]}"; do
    if [ "${FOC[$wid]}" = true ]; then cur="$wid"; else printf '%s\n' "$wid"; fi
  done
  [ -n "$cur" ] && printf '%s\n' "$cur"
}

# Default scope: workspace tree (selectable ws headers + nested agent rows).
emit_ws_tree() {
  local ws_json agents
  ws_json="$("$herdr" workspace list 2>/dev/null)"
  agents="$("$herdr" agent list 2>/dev/null)"

  declare -A WS_LABEL WS_TABS WS_FOCUS
  local wid label tabs focused
  while IFS=$'\t' read -r wid label tabs focused; do
    [ -n "$wid" ] || continue
    WS_LABEL[$wid]="$label"; WS_TABS[$wid]="$tabs"; WS_FOCUS[$wid]="$focused"
  done < <(printf '%s' "$ws_json" | jq -r '.result.workspaces[]? | [.workspace_id, .label, (.tab_count|tostring), (.focused|tostring)] | @tsv')

  declare -A CHILD WS_BLOCKED
  local pid agent tabid st cline
  while IFS=$'\t' read -r pid wid agent tabid st; do
    [ -n "$pid" ] || continue
    [ "$st" = blocked ] && WS_BLOCKED[$wid]=1
    printf -v cline 'agent\t%s\t%s\t%s\t%s  └ %s %s%s%s  %s%s' \
      "$pid" "$wid" "$tabid" \
      "$DIM" "$(agent_glyph "$st")$RESET" "$PINK" "$agent" "$RESET" \
      "$(agent_label "$st")" "$RESET"
    CHILD[$wid]+="$cline"$'\n'
  done < <(printf '%s' "$agents" | jq -r '.result.agents[]? | [.pane_id, .workspace_id, .agent, .tab_id, .agent_status] | @tsv')

  local mark labcol blocked
  while IFS= read -r wid; do
    [ -n "$wid" ] || continue
    label="${WS_LABEL[$wid]}"; tabs="${WS_TABS[$wid]}"
    mark="  "; labcol="$MAUVE"
    [ "${WS_FOCUS[$wid]}" = true ] && { mark="${GREEN}●${RESET} "; labcol="${GREEN}${BOLD}"; }
    blocked=""; [ -n "${WS_BLOCKED[$wid]:-}" ] && blocked=" ${RED}◆${RESET}"
    printf 'ws\t%s\t%s\t\t%s%s%s %-16s%s %s%s tabs%s%s\n' \
      "$wid" "$wid" "$mark" "$labcol" "$WS_ICON" "$label" "$RESET" "$DIM" "$tabs" "$RESET" "$blocked"
    printf '%s' "${CHILD[$wid]:-}"
  done < <(ordered_wids "$ws_json")
}

# Raw inventory for a grouped scope. One record per line:
#   MATCHKEY \t GROUPKEY \t GROUPLABEL \t type \t key \t wsid \t tabid \t render
# MATCHKEY = plain text fuzzy-searched; render = colored detail (no group label).
build_inventory() {
  local scope="$1"
  local ws_json; ws_json="$("$herdr" workspace list 2>/dev/null)"
  declare -A WS_LABEL; local wid lbl
  while IFS=$'\t' read -r wid lbl; do WS_LABEL[$wid]="$lbl"; done \
    < <(printf '%s' "$ws_json" | jq -r '.result.workspaces[]? | [.workspace_id, .label] | @tsv')

  case "$scope" in
    agent)
      # Grouped by STATE (blocked → working → idle → done → other); the workspace
      # is shown inline on each row instead of as a group heading. Within a state,
      # rows keep MRU-workspace order. MATCHKEY carries agent/ws/state/title so a
      # single query narrows across all of them.
      declare -A BUCKET TAB_LABEL; local pid agent tabid st title glyph sb icon render rec wl tl
      while IFS=$'\t' read -r tabid tl; do [ -n "$tabid" ] && TAB_LABEL[$tabid]="$tl"; done \
        < <(printf '%s' "$("$herdr" tab list 2>/dev/null)" | jq -r '.result.tabs[]? | [.tab_id, .label] | @tsv')
      while IFS=$'\t' read -r pid wid agent tabid st title; do
        [ -n "$pid" ] || continue
        wl="${WS_LABEL[$wid]:-$wid}"; tl="${TAB_LABEL[$tabid]:-}"
        glyph="$(agent_glyph "$st")$RESET"; sb="$(state_bucket "$st")"; icon="$(agent_icon "$agent")"
        # icon replaces the agent-name word; title is the prominent colored text;
        # ws + tab trails on the right in grey.
        render="$glyph ${PINK}${icon}${RESET}"
        [ -n "$title" ] && render+="  ${PINK}${title}${RESET}"
        render+="   ${DIM}${WS_ICON} ${wl}${tl:+   ${TAB_ICON} $tl}${RESET}"
        printf -v rec '%s %s %s %s %s\t%s\t%s\tagent\t%s\t%s\t%s\t%s' \
          "$agent" "$wl" "$tl" "$sb" "$title" \
          "$sb" "$(state_color "$st")${sb}$RESET" \
          "$pid" "$wid" "$tabid" "$render"
        BUCKET["$sb"$'\x1f'"$wid"]+="$rec"$'\n'
      done < <(printf '%s' "$("$herdr" agent list 2>/dev/null)" | jq -r '.result.agents[]? | [.pane_id, .workspace_id, .agent, .tab_id, .agent_status, .terminal_title_stripped] | @tsv')
      local sbk
      for sbk in blocked working idle done other; do
        while IFS= read -r wid; do
          [ -n "$wid" ] || continue
          printf '%s' "${BUCKET["$sbk"$'\x1f'"$wid"]:-}"
        done < <(ordered_wids "$ws_json")
      done
      ;;
    pane)
      declare -A PROWS TAB_LABEL; local pid tabid cwd title rec wl t tl
      while IFS=$'\t' read -r tabid tl; do [ -n "$tabid" ] && TAB_LABEL[$tabid]="$tl"; done \
        < <(printf '%s' "$("$herdr" tab list 2>/dev/null)" | jq -r '.result.tabs[]? | [.tab_id, (.label // "")] | @tsv')
      while IFS=$'\t' read -r pid wid tabid cwd title; do
        [ -n "$pid" ] || continue
        wl="${WS_LABEL[$wid]:-$wid}"; t="$(tilde "$cwd")"; tl="${TAB_LABEL[$tabid]:-}"
        # path stays the primary (blue) column; tab label trails on the right in grey.
        printf -v rec '%s %s %s\t%s\t%s\tpane\t%s\t%s\t%s\t%s' \
          "$wl" "$t" "$tl" "$wid" "${MAUVE}${WS_ICON} ${wl}${RESET}" "$pid" "$wid" "$tabid" \
          "${BLUE}${PANE_ICON} ${t}${RESET}${tl:+   ${DIM}${TAB_ICON} ${tl}${RESET}}"
        PROWS[$wid]+="$rec"$'\n'
      done < <(printf '%s' "$("$herdr" pane list 2>/dev/null)" | jq -r '.result.panes[]? | [.pane_id, .workspace_id, .tab_id, .cwd, .terminal_title_stripped] | @tsv')
      while IFS= read -r wid; do printf '%s' "${PROWS[$wid]:-}"; done < <(ordered_wids "$ws_json")
      ;;
  esac
}

# Read inventory on stdin, fuzzy-filter by query, group survivors, paint the
# group label on the first row of each group. Emits final fzf rows AND records
# the 0-based line indices of heading (`hdr`) rows into HDR_FILE (line 1 = total
# rows) so nav() can jump the cursor straight over them.
render_grouped() {
  local query="$1" inv li=0 hdr=""
  inv="$(cat)"
  if [ -n "$query" ] && [ -n "$inv" ]; then
    inv="$(printf '%s' "$inv" | fzf --filter="$query" --delimiter="$TAB" --nth=1 2>/dev/null)"
  fi
  if [ -z "$inv" ]; then printf '0\n' > "$HDR_FILE" 2>/dev/null; return 0; fi
  declare -A GROUP GLABEL; local gorder=() mk gk gl type key wsid tabid render
  while IFS=$'\t' read -r mk gk gl type key wsid tabid render; do
    [ -n "$key" ] || continue
    [ -z "${GROUP[$gk]+x}" ] && { gorder+=("$gk"); GLABEL[$gk]="$gl"; }
    GROUP[$gk]+="$type"$'\t'"$key"$'\t'"$wsid"$'\t'"$tabid"$'\t'"$render"$'\n'
  done <<< "$inv"
  for gk in "${gorder[@]}"; do
    hdr+="$li"$'\n'
    printf 'hdr\t\t\t\t%s%s%s\n' "$BOLD" "${GLABEL[$gk]}" "$RESET"; li=$((li+1))
    while IFS=$'\t' read -r type key wsid tabid render; do
      [ -n "$key" ] || continue
      printf '%s\t%s\t%s\t%s\t  %s\n' "$type" "$key" "$wsid" "$tabid" "$render"; li=$((li+1))
    done <<< "${GROUP[$gk]}"
  done
  { printf '%s\n' "$li"; printf '%s' "$hdr"; } > "$HDR_FILE" 2>/dev/null
}

# Up/Down handler. In ws scope it just performs the built-in move. In grouped
# scopes it jumps the cursor to the next/previous NON-heading row (using the
# heading indices in HDR_FILE), so the cursor never rests on a heading and there
# is no skip-flicker. Emits an fzf action string (`up`/`down`, or `pos(N)`).
nav() {
  local dir="$1" n="${2:-0}" scope total hdrs t
  scope="$(read_scope)"
  [ "$scope" = ws ] && { printf '%s' "$dir"; return 0; }
  total="$(head -1 "$HDR_FILE" 2>/dev/null)"; total="${total:-0}"
  hdrs=" $(tail -n +2 "$HDR_FILE" 2>/dev/null | tr '\n' ' ') "
  if [ "$dir" = down ]; then
    t=$((n+1))
    [ "$t" -ge "$total" ] && { printf 'pos(%d)' "$((n+1))"; return 0; }   # at bottom: stay
    case "$hdrs" in *" $t "*) t=$((t+1));; esac                            # step over a heading
    printf 'pos(%d)' "$((t+1))"
  else
    t=$((n-1))
    [ "$t" -lt 0 ] && { printf 'pos(%d)' "$((n+1))"; return 0; }
    case "$hdrs" in *" $t "*) t=$((t-1));; esac
    [ "$t" -lt 0 ] && t="$n"                                              # first child is the ceiling
    printf 'pos(%d)' "$((t+1))"
  fi
}

emit_list() {
  local scope; scope="$(read_scope)"
  case "$scope" in
    agent|pane) build_inventory "$scope" > "$INV_FILE"; render_grouped "${FZF_QUERY:-}" < "$INV_FILE" ;;
    *)          emit_ws_tree ;;
  esac
}

# change:reload target for grouped scopes — re-filter the cached inventory only
# (no herdr calls per keystroke).
refilter() { render_grouped "${FZF_QUERY:-}" < "$INV_FILE" 2>/dev/null; }

# ── Preview ──────────────────────────────────────────────────────────────────
capture() { [ -n "$1" ] && "$herdr" pane read "$1" --source visible --lines 100 --format ansi 2>/dev/null | sed 's/[[:space:]]\{1,\}$//'; }

# Thin full-bleed rule, dim.
rule() { printf '%s%s%s\n' "$DIM" "────────────────────────────────────────────────" "$RESET"; }

preview() {
  local type="$1" key="$2" wsid="${3:-}" tabid="${4:-}"
  case "$type" in
    ws)
      local info label atab panes cwd apane tline ttid tnum tlabel tstatus dot
      info="$("$herdr" workspace get "$key" 2>/dev/null)"
      label="$(printf '%s' "$info" | jq -r '.result.workspace.label // empty')"
      atab="$(printf '%s' "$info" | jq -r '.result.workspace.active_tab_id // empty')"
      panes="$("$herdr" pane list --workspace "$key" 2>/dev/null)"
      cwd="$(printf '%s' "$panes" | jq -r '.result.panes[0].cwd // empty')"
      apane="$(printf '%s' "$panes" | jq -r --arg t "$atab" '([.result.panes[] | select(.tab_id==$t)][0].pane_id) // .result.panes[0].pane_id // empty')"
      # Line 1: accent bar + name + cwd
      printf '%s▌%s %s%s %s%s   %s %s%s\n' \
        "$MAUVE" "$RESET" "$MAUVE$BOLD" "$WS_ICON" "$label" "$RESET" "$DIM" "$(tilde "$cwd")" "$RESET"
      # Line 2: tabs on a single row; active tab bright, agent tabs get a state dot
      tline=""
      while IFS=$'\t' read -r ttid tnum tlabel tstatus; do
        [ -n "$tnum" ] || continue
        case "$tstatus" in working) dot=" ${YELLOW}●${RESET}";; blocked) dot=" ${RED}◆${RESET}";; idle|done) dot=" ${GREEN}●${RESET}";; *) dot="";; esac
        if [ "$ttid" = "$atab" ]; then tline+="${MAUVE}${BOLD}${TAB_ICON} ${tnum}·${tlabel}${RESET}${dot}   "
        else tline+="${DIM}${TAB_ICON} ${tnum}·${tlabel}${RESET}${dot}   "; fi
      done < <("$herdr" tab list --workspace "$key" 2>/dev/null | jq -r '.result.tabs[]? | [.tab_id,(.number|tostring),.label,.agent_status] | @tsv')
      printf '%s\n' "$tline"
      rule; capture "$apane"
      ;;
    agent)
      local info agent st tok title dot
      info="$("$herdr" agent get "$key" 2>/dev/null)"
      agent="$(printf '%s' "$info" | jq -r '.result.agent.agent // "agent"')"
      st="$(printf '%s' "$info" | jq -r '.result.agent.agent_status // ""')"
      tok="$(printf '%s' "$info" | jq -r '.result.agent.tokens // {} | to_entries[0].value // ""')"
      title="$(printf '%s' "$info" | jq -r '.result.agent.terminal_title_stripped // ""')"
      dot="$(agent_glyph "$st")$RESET"
      printf '%s %s%s%s%s   %s%s%s   %s%s%s\n' \
        "$dot" "$PINK$BOLD" "$agent" "$RESET" "" "$DIM" "$st" "$RESET" "$GREEN" "$tok" "$RESET"
      printf '%s%s%s\n' "$DIM" "$title" "$RESET"
      rule; capture "$key"
      ;;
    pane)
      local cwd wl
      cwd="$("$herdr" pane list 2>/dev/null | jq -r --arg p "$key" '[.result.panes[] | select(.pane_id==$p)][0].cwd // empty')"
      wl="$("$herdr" workspace get "$wsid" 2>/dev/null | jq -r '.result.workspace.label // empty')"
      printf '%s▌%s %s%s %s%s   %s %s%s\n' \
        "$BLUE" "$RESET" "$BLUE$BOLD" "$PANE_ICON" "${wl:-$key}" "$RESET" "$DIM" "$(tilde "$cwd")" "$RESET"
      rule; capture "$key"
      ;;
  esac
}

# ── Actions ──────────────────────────────────────────────────────────────────
focus_pane() {  # jump to a specific pane: workspace -> tab -> pane
  local pid="$1" wsid="$2" tabid="$3"
  [ -n "$wsid" ] && "$herdr" workspace focus "$wsid" >/dev/null 2>&1
  [ -n "$tabid" ] && "$herdr" tab focus "$tabid" >/dev/null 2>&1
  "$herdr" pane zoom "$pid" --on >/dev/null 2>&1
  exec "$herdr" pane zoom "$pid" --off
}

open_entry() {
  local type="$1" key="$2" wsid="${3:-}" tabid="${4:-}"
  case "$type" in
    hdr)   exit 0 ;;   # group heading (cursor normally skips these) — no action
    ws)    mru_push "$key"; exec "$herdr" workspace focus "$key" ;;
    agent) mru_push "$wsid"; exec "$herdr" agent focus "$key" ;;
    pane)  mru_push "$wsid"; focus_pane "$key" "$wsid" "$tabid" ;;
    dir)
      local existing
      existing="$("$herdr" pane list 2>/dev/null | jq -r --arg d "$key" '[.result.panes[]? | select(.cwd == $d)][0].workspace_id // empty')"
      if [ -n "$existing" ]; then mru_push "$existing"; exec "$herdr" workspace focus "$existing"
      else exec "$herdr" workspace create --cwd "$key" --label "$(basename "$key")" --focus; fi
      ;;
  esac
}

create_named() {  # ctrl-n: make a new workspace from the typed query
  local name="$1"
  if [ -n "$name" ]; then exec "$herdr" workspace create --label "$name" --focus
  else exec "$herdr" workspace create --focus; fi
}

kill_ws() { [ -n "${1:-}" ] && "$herdr" workspace close "$1" >/dev/null 2>&1 || true; }

rename_ws() {  # runs via `become`, so the terminal is in cooked mode: read works
  local wsid="${1:-}"; [ -n "$wsid" ] || exit 0
  local cur new
  cur="$("$herdr" workspace get "$wsid" 2>/dev/null | jq -r '.result.workspace.label // empty')"
  read -e -r -p "Rename workspace [$cur] → " new || exit 0
  [ -n "$new" ] && "$herdr" workspace rename "$wsid" "$new" >/dev/null 2>&1 || true
}

# ── Scope switching (emits an fzf action string via `transform`) ─────────────
scope_name() { case "$1" in agent) printf 'agents';; pane) printf 'panes';; dir) printf 'dirs';; *) printf 'workspaces';; esac; }

scope_header() {  # tab-strip; active scope bracketed + accented, others dim
  local active="$1" out="" s name col ic
  for s in ws agent pane; do
    name="$(scope_name "$s")"
    case "$s" in ws) col="$MAUVE"; ic="$WS_ICON";; agent) col="$PINK"; ic="$(agent_icon claude)";; pane) col="$BLUE"; ic="$PANE_ICON";; esac
    if [ "$s" = "$active" ]; then out+="${col}${BOLD}${ic} [${name}]${RESET}"; else out+="${DIM}${ic} ${name}${RESET}"; fi
    out+="   "
  done
  printf '%s⇥ scope' "$out"
}

set_scope() {  # write scope + emit fzf actions (search mode differs per scope)
  local next="$1" search
  printf '%s' "$next" > "$SCOPE_FILE"
  # ws scope uses fzf's own name search; grouped scopes disable it and drive a
  # per-keystroke reload instead (rebind `change`; unbind it back in ws scope).
  local tail
  if [ "$next" = ws ]; then search='enable-search+unbind(change)'; tail='reload(bash %q --list)+first'
  else search='disable-search+rebind(change)'; tail='reload-sync(bash %q --list)+first+down'; fi
  printf "%s+clear-query+change-prompt(%s ❯ )+change-header(%s)+$tail" \
    "$search" "$(scope_name "$next")" "$(scope_header "$next")" "$SELF"
}

cycle_scope() {  # $1 = next|prev
  local cur; cur="$(read_scope)"
  local order=(ws agent pane) i
  for i in 0 1 2; do [ "${order[$i]}" = "$cur" ] && break; done
  if [ "$1" = prev ]; then i=$(((i+2)%3)); else i=$(((i+1)%3)); fi
  set_scope "${order[$i]}"
}

# ── Entry point ──────────────────────────────────────────────────────────────
SELF="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/$(basename "${BASH_SOURCE[0]:-$0}")"

case "${1:-}" in
  --list)         emit_list; exit 0 ;;
  --refilter)     refilter; exit 0 ;;
  --nav)          nav "${2:-down}" "${3:-0}"; exit 0 ;;
  --startpos)     # one-shot: after the initial load, land on the first child
    [ -s "${STARTPOS_FILE:-}" ] && { rm -f "$STARTPOS_FILE"; printf 'pos(2)'; }
    exit 0 ;;
  --preview)      preview "$2" "$3" "${4:-}" "${5:-}"; exit 0 ;;
  --open)         open_entry "$2" "$3" "${4:-}" "${5:-}"; exit 0 ;;
  --create-named) create_named "${2:-}"; exit 0 ;;
  --kill)         kill_ws "${2:-}"; exit 0 ;;
  --rename)       rename_ws "${2:-}"; exit 0 ;;
  --scope)
    case "${2:-}" in set:*) set_scope "${2#set:}";; prev) cycle_scope prev;; *) cycle_scope next;; esac
    exit 0 ;;
esac

# Per-popup state, shared with every self-reinvocation fzf spawns: the current
# scope, and the cached inventory for grouped scopes (re-filtered per keystroke).
SCOPE_FILE="$(mktemp -u "${TMPDIR:-/tmp}/herdr-goto-scope.XXXXXX")"
INV_FILE="$(mktemp -u "${TMPDIR:-/tmp}/herdr-goto-inv.XXXXXX")"
HDR_FILE="$(mktemp -u "${TMPDIR:-/tmp}/herdr-goto-hdr.XXXXXX")"

# Launch scope: GOTO_SCOPE env or a bare first arg (agent|pane|ws); default ws.
case "${GOTO_SCOPE:-${1:-}}" in agent|pane|ws) START_SCOPE="${GOTO_SCOPE:-$1}";; *) START_SCOPE=ws;; esac
printf '%s' "$START_SCOPE" > "$SCOPE_FILE"
# ws opens with fzf's own live search. For a grouped start scope the initial pipe
# has ALREADY emitted the right list (no reload needed — a reload racing the
# still-reading pipe strands the cursor on row 0). We only disable fzf's search at
# `start` (change is bound by default for refilter). The cursor jump to the first
# child can't happen at `start` — the pipe hasn't loaded yet — so it's driven off
# the `load` event via a one-shot flag (STARTPOS_FILE): `load` fires when the
# reader finishes (and after every reload), so --startpos emits pos(2) exactly
# once then deletes the flag, leaving Tab-switch/refilter loads untouched.
STARTPOS_FILE="$(mktemp -u "${TMPDIR:-/tmp}/herdr-goto-spos.XXXXXX")"
if [ "$START_SCOPE" = ws ]; then START_BIND="start:unbind(change)"
else START_BIND="start:disable-search"; printf 1 > "$STARTPOS_FILE"; fi
export SCOPE_FILE INV_FILE HDR_FILE STARTPOS_FILE SELF
trap 'rm -f "$SCOPE_FILE" "$INV_FILE" "$HDR_FILE" "$STARTPOS_FILE"' EXIT

emit_list | fzf \
  --ansi \
  --delimiter="$TAB" \
  --with-nth=5 \
  --no-sort \
  --layout=reverse \
  --border=rounded \
  --border-label=' ↵ open · ⇥ scope · ^x kill · ^r rename · ^n new ' \
  --border-label-pos=bottom \
  --prompt="$(scope_name "$START_SCOPE") ❯ " \
  --pointer='▶' \
  --marker='✓' \
  --info=inline-right \
  --height=100% \
  --header="$(scope_header "$START_SCOPE")" \
  --preview="bash '$SELF' --preview {1} {2} {3} {4}" \
  --preview-window='right,50%,border-left,nowrap' \
  --color='bg+:#313244,bg:#1e1e2e,spinner:#f5e0dc,hl:#f38ba8' \
  --color='fg:#cdd6f4,header:#cdd6f4,info:#cba6f7,pointer:#f5e0dc' \
  --color='marker:#a6e3a1,fg+:#cdd6f4,prompt:#cba6f7,hl+:#f38ba8' \
  --color='border:#585b70,label:#7f849c,preview-border:#585b70' \
  --color='selected-bg:#45475a' \
  --bind="$START_BIND" \
  --bind="load:transform:bash '$SELF' --startpos" \
  --bind="change:reload-sync(bash '$SELF' --refilter)+first+down" \
  --bind="down:transform:bash '$SELF' --nav down {n}" \
  --bind="up:transform:bash '$SELF' --nav up {n}" \
  --bind="enter:become(bash '$SELF' --open {1} {2} {3} {4})" \
  --bind="ctrl-n:become(bash '$SELF' --create-named {q})" \
  --bind="ctrl-x:execute-silent(bash '$SELF' --kill {3})+reload(bash '$SELF' --list)" \
  --bind="ctrl-r:become(bash '$SELF' --rename {3})" \
  --bind="tab:transform:bash '$SELF' --scope next" \
  --bind="btab:transform:bash '$SELF' --scope prev" \
  --bind="alt-w:transform:bash '$SELF' --scope set:ws" \
  --bind="alt-a:transform:bash '$SELF' --scope set:agent" \
  --bind="alt-p:transform:bash '$SELF' --scope set:pane" \
  --bind="ctrl-o:toggle-preview" \
  --bind="ctrl-/:toggle-preview"
