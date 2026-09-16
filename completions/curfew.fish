# fish completion for curfew — fish auto-loads this from
# ~/.config/fish/completions/curfew.fish (see `make install`), no sourcing
# needed.

# Lists profile names from $CURFEW_PROFILES_DIR and the bundled profiles
# dir, same lookup order as curfew itself (user profiles, then bundled).
# When CURFEW_BUILTIN_PROFILES_DIR isn't set, resolves it relative to
# wherever `curfew` itself resolves to on PATH (following symlinks),
# mirroring the script's own SCRIPT_DIR logic so completion works for an
# installed symlink.
function __curfew_profile_names
    set -l profiles_dir $CURFEW_PROFILES_DIR
    if test -z "$profiles_dir"
        set profiles_dir $HOME/.config/curfew/profiles
    end

    set -l builtin_dir $CURFEW_BUILTIN_PROFILES_DIR
    if test -z "$builtin_dir"
        set -l script (command -v curfew)
        if test -n "$script"
            while test -L "$script"
                set -l dir (cd (dirname "$script"); and pwd)
                set script (readlink "$script")
                if not string match -q '/*' -- "$script"
                    set script "$dir/$script"
                end
            end
            set builtin_dir (dirname "$script")/profiles
        end
    end

    for d in $profiles_dir/*/ $builtin_dir/*/
        if test -d "$d"
            basename "$d"
        end
    end | sort -u
end

function __curfew_first_arg
    set -l cmd (commandline -opc)
    test (count $cmd) -eq 1
end

function __curfew_second_arg_is_new
    set -l cmd (commandline -opc)
    test (count $cmd) -ge 2; and test "$cmd[2]" = --new
end

# curfew --new <name> [--from a,b,c] — only --from is completable; the new
# name and the --from list itself are free-form.
function __curfew_from_flag_position
    __curfew_second_arg_is_new; and test (count (commandline -opc)) -eq 3
end

function __curfew_prev_is_time_flag
    set -l cmd (commandline -opc)
    test (count $cmd) -ge 1; and contains -- "$cmd[-1]" --for --until
end

# curfew <profile> [user] --for <duration> | --until <time>
function __curfew_after_profile
    set -l cmd (commandline -opc)
    test (count $cmd) -ge 2
    and not contains -- "$cmd[2]" --list --new --detect-games --help
    and not __curfew_prev_is_time_flag
end

complete -c curfew -f

complete -c curfew -n __curfew_first_arg -a '(__curfew_profile_names)' -d profile
complete -c curfew -n __curfew_first_arg -l list -d 'List available profiles'
complete -c curfew -n __curfew_first_arg -l new -d 'Scaffold a new profile'
complete -c curfew -n __curfew_first_arg -l detect-games -d 'Preview which installed games would be blocked'
complete -c curfew -n __curfew_first_arg -l help -d 'Show help'

complete -c curfew -n __curfew_from_flag_position -l from -d 'Comma-separated parent profiles'

complete -c curfew -n __curfew_after_profile -l for -d 'Apply and lock for a duration'
complete -c curfew -n __curfew_after_profile -l until -d 'Apply and lock until a time'
