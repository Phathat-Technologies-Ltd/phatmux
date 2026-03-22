# vim:ft=zsh
#
# Compatibility shim: with the current integration model, phatmux restores
# ZDOTDIR in .zshenv so this file should never be reached. If it is, restore
# ZDOTDIR and behave like vanilla zsh by sourcing the user's .zprofile.

if [[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"
    builtin unset GHOSTTY_ZSH_ZDOTDIR
elif [[ -n "${PHATMUX_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$PHATMUX_ZSH_ZDOTDIR"
    builtin unset PHATMUX_ZSH_ZDOTDIR
else
    builtin unset ZDOTDIR
fi

builtin typeset _phatmux_file="${ZDOTDIR-$HOME}/.zprofile"
[[ ! -r "$_phatmux_file" ]] || builtin source -- "$_phatmux_file"
builtin unset _phatmux_file
