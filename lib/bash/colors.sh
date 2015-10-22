#!/usr/bin/env sh

# Colors definitions
export black="$(tput setaf 0)"
export red="$(tput setaf 1)"
export green="$(tput setaf 2)"
export yellow="$(tput setaf 3)"
export blue="$(tput setaf 4)"
export magenta="$(tput setaf 5)"
export cyan="$(tput setaf 6)"
export white="$(tput setaf 7)"

export black_bold="$(tput setaf 0; tput bold)"
export red_bold="$(tput setaf 1; tput bold)"
export green_bold="$(tput setaf 2; tput bold)"
export yellow_bold="$(tput setaf 3; tput bold)"
export blue_bold="$(tput setaf 4; tput bold)"
export magenta_bold="$(tput setaf 5; tput bold)"
export cyan_bold="$(tput setaf 6; tput bold)"
export white_bold="$(tput setaf 7; tput bold)"

export reset_colors="$(tput sgr0)"
