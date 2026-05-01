# Lapis Obscura fish theme
# Dark stone, sparse sacred geometry, Gruvbox mineral accents.

set -g fish_greeting ''

# Syntax colors
set -g fish_color_normal c8c8d0
set -g fish_color_command d8a657
set -g fish_color_keyword 8f7dff
set -g fish_color_quote 98971a
set -g fish_color_redirection 83a598
set -g fish_color_end 918999
set -g fish_color_error cc241d
set -g fish_color_param c8c8d0
set -g fish_color_comment 55515d
set -g fish_color_selection --background=171522
set -g fish_color_search_match --background=24212c --bold
set -g fish_color_operator fabd2f
set -g fish_color_escape 8ec07c
set -g fish_color_autosuggestion 55515d
set -g fish_color_cancel cc241d

# Completion pager colors
set -g fish_pager_color_progress 918999
set -g fish_pager_color_prefix d8a657 --bold
set -g fish_pager_color_completion c8c8d0
set -g fish_pager_color_description 918999
set -g fish_pager_color_selected_background --background=171522
set -g fish_pager_color_selected_prefix fabd2f --bold
set -g fish_pager_color_selected_completion e4e0e8
set -g fish_pager_color_selected_description 83a598

function fish_prompt --description 'Lapis Obscura prompt'
    set -l last_status $status
    set -l cwd (prompt_pwd)

    set_color 55515d
    printf '◇ '
    set_color d8a657
    printf '%s' $USER
    set_color 55515d
    printf '@'
    set_color 83a598
    printf '%s' (prompt_hostname)
    set_color 55515d
    printf ' · '
    set_color c8c8d0
    printf '%s' $cwd

    if command git rev-parse --is-inside-work-tree >/dev/null 2>&1
        set -l branch (command git branch --show-current 2>/dev/null)
        if test -n "$branch"
            set_color 55515d
            printf ' · '
            set_color 8f7dff
            printf '⬡ %s' $branch
        end
    end

    if test $last_status -ne 0
        set_color cc241d
        printf ' △ %s' $last_status
    end

    set_color normal
    printf '\n'
    set_color d8a657
    printf '◆ '
    set_color normal
end

function fish_right_prompt --description 'Lapis Obscura right prompt'
    set_color 55515d
    printf '☾ '
    set_color 918999
    date '+%H:%M'
    set_color normal
end

# Minimal convenience abbreviations. Keep this small: stone first, no shell bloat.
abbr -a -- ll 'ls -lh --group-directories-first'
abbr -a -- la 'ls -lah --group-directories-first'
abbr -a -- gs 'git status --short --branch'
abbr -a -- v nvim
