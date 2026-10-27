# Workstation foundation fragment: eza is the managed ls (icons).
command -v eza >/dev/null 2>&1 && alias ls='eza -lh --group-directories-first --icons=auto'
