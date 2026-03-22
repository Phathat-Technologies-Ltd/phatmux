# vim:ft=zsh
#
# phatmux ZDOTDIR bootstrap for zsh.
#
# GhosttyKit already uses a ZDOTDIR injection mechanism for zsh (setting ZDOTDIR
# to Ghostty's integration dir). phatmux also needs to run its integration, but
# we must restore the user's real ZDOTDIR immediately so that:
# - /etc/zshrc sets HISTFILE relative to the real ZDOTDIR/HOME (shared history)
# - zsh loads the user's real .zprofile/.zshrc normally (no wrapper recursion)
#
# We restore ZDOTDIR from (in priority order):
# - GHOSTTY_ZSH_ZDOTDIR (set by GhosttyKit when it overwrote ZDOTDIR)
# - PHATMUX_ZSH_ZDOTDIR (set by phatmux when it overwrote a user-provided ZDOTDIR)
# - unset (zsh treats unset ZDOTDIR as $HOME)

if [[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"
    builtin unset GHOSTTY_ZSH_ZDOTDIR
elif [[ -n "${PHATMUX_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$PHATMUX_ZSH_ZDOTDIR"
    builtin unset PHATMUX_ZSH_ZDOTDIR
else
    builtin unset ZDOTDIR
fi

{
    # zsh treats unset ZDOTDIR as if it were HOME. We do the same.
    builtin typeset _phatmux_file="${ZDOTDIR-$HOME}/.zshenv"
    [[ ! -r "$_phatmux_file" ]] || builtin source -- "$_phatmux_file"
} always {
    if [[ -o interactive ]]; then
        # We overwrote GhosttyKit's injected ZDOTDIR, so manually load Ghostty's
        # zsh integration if available.
        #
        # We can't rely on GHOSTTY_ZSH_ZDOTDIR here because Ghostty's own zsh
        # bootstrap unsets it before chaining into this phatmux wrapper.
        if [[ "${PHATMUX_LOAD_GHOSTTY_ZSH_INTEGRATION:-0}" == "1" ]]; then
            if [[ -n "${PHATMUX_SHELL_INTEGRATION_DIR:-}" ]]; then
                builtin typeset _phatmux_ghostty="$PHATMUX_SHELL_INTEGRATION_DIR/ghostty-integration.zsh"
            fi
            if [[ ! -r "${_phatmux_ghostty:-}" && -n "${GHOSTTY_RESOURCES_DIR:-}" ]]; then
                builtin typeset _phatmux_ghostty="$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
            fi
            [[ -r "$_phatmux_ghostty" ]] && builtin source -- "$_phatmux_ghostty"
        fi

        # Load phatmux integration (unless disabled)
        if [[ "${PHATMUX_SHELL_INTEGRATION:-1}" != "0" && -n "${PHATMUX_SHELL_INTEGRATION_DIR:-}" ]]; then
            builtin typeset _phatmux_integ="$PHATMUX_SHELL_INTEGRATION_DIR/phatmux-zsh-integration.zsh"
            [[ -r "$_phatmux_integ" ]] && builtin source -- "$_phatmux_integ"
        fi
    fi

    builtin unset _phatmux_file _phatmux_ghostty _phatmux_integ
}
