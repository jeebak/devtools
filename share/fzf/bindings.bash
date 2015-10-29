# Keybindings to trigger scripts.
# Attempt to restore cmdline. Not perfect but OK for now :/.
bind '"\em": "\C-e \C-ufzlp\n\C-y"'
bind '"\eq": "\C-e \C-ufzgit\n\C-y"'

# Based on: http://weblog.bulknews.net/post/89635306479/ghq-peco-percol
#      and: https://gist.github.com/junegunn/f4fca918e937e6bf5bad
function fzf-src () {
  local out selected_dir

  >&2 echo "Gathering list..."
  out="$(
    ghq list --full-path |
    fzf --reverse --tiebreak=index --toggle-sort=\` --query="$LBUFFER" \
        --prompt="Search for a local git clone: " \
        --print-query
  )"

  selected_dir="$(head -2 <<< "$out" | tail -1)"

  if [[ -n "$selected_dir" ]]; then
    echo "cd ${selected_dir} && git status"
  fi
}

bind '"\es": "\C-e \C-u$(fzf-src)\n\C-y"'

# Inspired by fzf docs
fzf-edit-file() {
  local out

  >&2 echo "Gathering list..."
  out="$(
    (git ls-tree -r --name-only HEAD || find . -type f) 2> /dev/null |
    fzf --tiebreak=index
  )"

  [[ -n "$out" ]] && LBUFFER="${EDITOR:-vim} \"$out\""
}

bind '"\eo": "\C-e \C-u$(fzf-edit-file)\n\C-y"'
# Doesn't seem to work :/
bind '"\C-o": "\C-e \C-u$(fzf-edit-file)\n\C-y"'

# vim: set ft=sh:
