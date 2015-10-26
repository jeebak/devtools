# Based on: http://weblog.bulknews.net/post/89635306479/ghq-peco-percol
#      and: https://gist.github.com/junegunn/f4fca918e937e6bf5bad
function fzf-src () {
  local out selected_dir

  echo "Gathering list..."
  out="$(
    ghq list --full-path |
    fzf --reverse --tiebreak=index --toggle-sort=\` --query="$LBUFFER" \
        --prompt="Search for a local git clone: " \
        --print-query
  )"

  selected_dir="$(head -2 <<< "$out" | tail -1)"

  if [[ -n "$selected_dir" ]]; then
    BUFFER="cd ${selected_dir} && git status"
    zle accept-line
  fi
  zle clear-screen
}

zle -N fzf-src
bindkey '\es' fzf-src

# vim: set ft=zsh:
