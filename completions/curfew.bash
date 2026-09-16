# bash completion for curfew — source this file, or install it where your
# bash-completion setup auto-loads per-command scripts (see `make install`).

# Lists profile names from $CURFEW_PROFILES_DIR and the bundled profiles dir,
# same lookup order as curfew itself (user profiles, then bundled). When
# CURFEW_BUILTIN_PROFILES_DIR isn't set, resolves it relative to wherever
# `curfew` itself resolves to on PATH (following symlinks), mirroring the
# script's own SCRIPT_DIR logic so completion works for an installed symlink.
_curfew_profile_names() {
  local profiles_dir="${CURFEW_PROFILES_DIR:-$HOME/.config/curfew/profiles}"
  local builtin_dir="${CURFEW_BUILTIN_PROFILES_DIR:-}"

  if [[ -z "$builtin_dir" ]]; then
    local script dir
    script="$(command -v curfew 2>/dev/null)"
    if [[ -n "$script" ]]; then
      while [[ -L "$script" ]]; do
        dir="$(cd -P "$(dirname "$script")" >/dev/null 2>&1 && pwd)"
        script="$(readlink "$script")"
        [[ "$script" != /* ]] && script="$dir/$script"
      done
      builtin_dir="$(dirname "$script")/profiles"
    fi
  fi

  local d
  for d in "$profiles_dir"/*/ "${builtin_dir:-/nonexistent}"/*/; do
    [[ -d "$d" ]] || continue
    basename "$d"
  done | sort -u
}

_curfew() {
  local cur prev
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD - 1]}"

  COMPREPLY=()

  if [[ "$COMP_CWORD" -eq 1 ]]; then
    COMPREPLY=($(compgen -W "$(_curfew_profile_names) --list --new --detect-games --help" -- "$cur"))
    return
  fi

  case "${COMP_WORDS[1]}" in
    --new)
      # curfew --new <name> [--from a,b,c] — only the flag itself is
      # completable; the new name and --from list are free-form.
      if [[ "$COMP_CWORD" -eq 3 ]]; then
        COMPREPLY=($(compgen -W "--from" -- "$cur"))
      fi
      return
      ;;
    --list | --detect-games | --help)
      return
      ;;
  esac

  # curfew <profile> [user] --for <duration> | --until <time>
  if [[ "$prev" == "--for" || "$prev" == "--until" ]]; then
    return
  fi
  COMPREPLY=($(compgen -W "--for --until" -- "$cur"))
}

complete -F _curfew curfew
