#!/usr/bin/env bash
# PROTOTYPE — throw away after choosing the M16 review-item mutation interaction.
# Three TUI variants, switchable with h/l or A/B/C, against the same ReviewCards.

set -u

variant=A
selected=0
notice="Move across every card: availability and identity should remain obvious."

items=(
  "✎ draft · local D-17|Prefer an explicit error here.|draft"
  "▸ You · Bitbucket C-8421|Could this be a named error?|owned"
  "▸ Ada · Bitbucket C-8388|I think the boundary is already right.|other"
  "✎ outcome unknown · local D-21|The POST response was lost.|unknown"
)

clear_screen() {
  printf '\033[2J\033[H'
}

item_field() {
  local index="$1"
  local field="$2"
  printf '%s' "${items[$index]}" | cut -d'|' -f"$field"
}

availability() {
  case "$(item_field "$selected" 3)" in
    draft) printf 'Edit ✓   Re-anchor ✓   Delete ✓' ;;
    owned) printf 'Edit ✓   Re-anchor — published Anchors are immutable   Delete ✓' ;;
    other) printf 'Edit — not yours   Re-anchor — published Anchors are immutable   Delete — not yours' ;;
    unknown) printf 'Edit — resolve outcome first   Re-anchor — resolve outcome first   Delete — resolve outcome first' ;;
  esac
}

draw_cards() {
  local index
  for index in 0 1 2 3; do
    if [[ "$index" -eq "$selected" ]]; then
      printf '\033[7m› %-72s\033[0m\n' "$(item_field "$index" 1)"
    else
      printf '  %-72s\n' "$(item_field "$index" 1)"
    fi
    printf '    %s\n\n' "$(item_field "$index" 2)"
  done
}

draw_header() {
  printf 'bbr · M16 review-item mutation prototype                         Variant %s\n' "$variant"
  printf '──────────────────────────────────────────────────────────────────────────────\n'
  printf ' src/review/parser.zig                                                      1/1\n\n'
  printf '   38 │     return parseToken(input);\n'
  printf '   39 │ }\n\n'
}

draw_footer() {
  printf '\n──────────────────────────────────────────────────────────────────────────────\n'
  printf '%s\n' "$notice"
  printf '[h] ‹  [A] Direct keys   [B] Action menu   [C] Inspector  › [l]    [j/k] card [q] quit\n'
}

draw_a() {
  draw_cards
  printf ' Context: %s\n' "$(item_field "$selected" 1)"
  printf ' Actions: %s\n' "$(availability)"
  printf ' Keys:    [e] edit   [a] re-anchor   [D] delete\n'
}

draw_b() {
  draw_cards
  printf ' Selected: %s\n' "$(item_field "$selected" 1)"
  printf ' [m] Manage item…   [r] Reply   [?] Help\n'
  printf ' One entry point opens a short Action menu with unavailable reasons inline.\n'
}

draw_c() {
  printf ' DIFF + REVIEWCARDS                              MANAGE SELECTED ITEM\n'
  printf ' ───────────────────────────────────────         ─────────────────────────────\n'
  local index
  for index in 0 1 2 3; do
    if [[ "$index" -eq "$selected" ]]; then
      printf '\033[7m › %-39s\033[0m        %s\n' "$(item_field "$index" 1)" "$(if [[ "$index" -eq 0 ]]; then printf 'LOCAL DRAFT'; else printf 'IDENTITY'; fi)"
    else
      printf '   %-39s        %s\n' "$(item_field "$index" 1)" "$(if [[ "$index" -eq 0 ]]; then printf 'TempId D-17'; else printf ' '; fi)"
    fi
    printf '     %-39s        %s\n' "$(item_field "$index" 2)" "$(if [[ "$index" -eq "$selected" ]]; then item_field "$index" 1; else printf ' '; fi)"
  done
  printf '\n                                                AVAILABLE ACTIONS\n'
  printf '                                                %s\n' "$(availability)"
  printf '                                                [tab] focus inspector · [enter]\n'
}

render() {
  clear_screen
  draw_header
  case "$variant" in
    A) draw_a ;;
    B) draw_b ;;
    C) draw_c ;;
  esac
  draw_footer
}

composer() {
  local identity
  identity="$(item_field "$selected" 1)"
  clear_screen
  draw_header
  draw_cards
  printf '\n                ┌─ ✎ Edit %s ─────────────────────┐\n' "$identity"
  printf '                │ %s                              │\n' "$(item_field "$selected" 2)"
  printf '                │                                          │\n'
  printf '                └─ ^D save · ^E external editor · esc ─────┘\n'
  printf '\nSame prefilled Composer; save targets the displayed identity, never a new item.\n'
  printf 'Press any key to return.'
  IFS= read -rsn1 _key
  notice="Composer preserved $(item_field "$selected" 1); prototype made no mutation."
}

confirm_delete() {
  clear_screen
  draw_header
  draw_cards
  printf '\n                    ┌─ Delete? ───────────────────────────┐\n'
  printf '                    │ %s │\n' "$(item_field "$selected" 1)"
  if [[ "$(item_field "$selected" 3)" == "draft" ]]; then
    printf '                    │ Also deletes 2 Draft reply-descendants. │\n'
  else
    printf '                    │ Bitbucket stays authoritative afterward.│\n'
  fi
  printf '                    └─ [y] delete · [esc/n] keep ─────────┘\n'
  IFS= read -rsn1 _key
  notice="Delete confirmation named $(item_field "$selected" 1); prototype kept it."
}

action_menu() {
  clear_screen
  draw_header
  draw_cards
  printf '\n                 ┌─ Manage %s ───────────────────────┐\n' "$(item_field "$selected" 1)"
  printf '                 │ [e] Edit                                      │\n'
  printf '                 │ [a] Re-anchor                                 │\n'
  printf '                 │ [d] Delete                                    │\n'
  printf '                 │                                               │\n'
  printf '                 │ %s │\n' "$(availability)"
  printf '                 └─ esc close ───────────────────────────────────┘\n'
  IFS= read -rsn1 _key
  case "$_key" in
    e) composer ;;
    d) confirm_delete ;;
    *) notice="Action menu closed; no mutation." ;;
  esac
}

unavailable_or() {
  local action="$1"
  case "$(item_field "$selected" 3)" in
    draft) return 0 ;;
    owned)
      if [[ "$action" == "re-anchor" ]]; then
        notice="Unavailable: published Bitbucket Anchors are immutable."
        return 1
      fi
      return 0
      ;;
    other)
      notice="Unavailable: this Bitbucket Comment is owned by Ada, not you."
      return 1
      ;;
    unknown)
      notice="Unavailable: outcome unknown — reconcile or resolve before editing."
      return 1
      ;;
  esac
}

while true; do
  render
  IFS= read -rsn1 key
  case "$key" in
    q) clear_screen; break ;;
    h) case "$variant" in A) variant=C ;; B) variant=A ;; C) variant=B ;; esac ;;
    l) case "$variant" in A) variant=B ;; B) variant=C ;; C) variant=A ;; esac ;;
    A|B|C) variant="$key" ;;
    j) selected=$(( (selected + 1) % 4 )); notice="Selected $(item_field "$selected" 1)." ;;
    k) selected=$(( (selected + 3) % 4 )); notice="Selected $(item_field "$selected" 1)." ;;
    e)
      if [[ "$variant" == A ]] && unavailable_or edit; then composer; fi
      ;;
    a)
      if [[ "$variant" == A ]] && unavailable_or re-anchor; then
        notice="Re-anchor would capture the current cursor/Selection for $(item_field "$selected" 1)."
      fi
      ;;
    D)
      if [[ "$variant" == A ]] && unavailable_or delete; then confirm_delete; fi
      ;;
    m)
      if [[ "$variant" == B ]]; then action_menu; fi
      ;;
    $'\t'|$'\n')
      if [[ "$variant" == C ]]; then
        notice="Inspector focused: choose only an Action marked available; Enter would invoke it."
      fi
      ;;
  esac
done

