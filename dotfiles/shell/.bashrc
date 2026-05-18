# ~/.bashrc
case $- in
    *i*) ;;
      *) return;;
esac

# History
HISTCONTROL=ignoreboth
shopt -s histappend
HISTSIZE=100000
HISTFILESIZE=200000

# Window size check
shopt -s checkwinsize

# Less for non-text input
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# Color support
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
fi

# Core aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

# Bash aliases file
if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi

# Bash completion
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

# Color env
export COLORTERM=truecolor
export FORCE_COLOR=3

# Tools
eval "$(zoxide init bash)"
eval "$(starship init bash)"
eval "$(tv init bash)"
export PATH=~/.npm-global/bin:$PATH

alias ai='cd ~/AI_Space && claude'
alias air='cd ~/AI_Space && claude -r'
alias aia='cd ~/AI_Space && claude agents'
alias ag='cd ~/AI_Space && gemini -i "Read /home/ubuntu/pkm/_Meta/AI/memory/MEMORY.md and acknowledge project context before starting."'

# Claude Code cache-fix proxy
export ANTHROPIC_BASE_URL=http://127.0.0.1:9801
