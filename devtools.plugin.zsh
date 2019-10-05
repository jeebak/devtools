PLUGIN_D="${0:a:h}"
export PATH="${PLUGIN_D}/bin:${PATH}"

alias acc='accomplice'
alias macc='maccomplice'
alias ql='maccomplice ql'

# Using aliases to avoid having to manipulate $PATH, for now
alias artisan="$PLUGIN_D/bin/artisan"
alias cap="$PLUGIN_D/bin/cap"
alias drupal="$PLUGIN_D/bin/drupal"
alias drush="$PLUGIN_D/bin/drush"
alias wp="$PLUGIN_D/bin/wp"
