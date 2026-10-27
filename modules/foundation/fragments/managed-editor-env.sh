# The workstation editor is nvim (modules/editor): a capability naming a
# tool declares its env, so the editor env defaults ride the managed shell
# environment. The operator's shell.extras render LATER (slot 100) and may
# override these per machine.
export EDITOR="nvim"
export VISUAL="nvim"
export GIT_EDITOR="nvim"
