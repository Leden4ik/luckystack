# Автодополнение для luckyctl (bash).
_luckyctl() {
	local cur prev cmds
	cur="${COMP_WORDS[COMP_CWORD]}"
	prev="${COMP_WORDS[COMP_CWORD-1]}"
	cmds="install adopt uninstall status check log paths diagnostics update rollback add-php remove-php timezone backup restore self-update version help"
	if ((COMP_CWORD == 1)); then
		COMPREPLY=($(compgen -W "$cmds" -- "$cur")); return
	fi
	case "${COMP_WORDS[1]}" in
		install)
			case "$prev" in
				--only|--from) COMPREPLY=($(compgen -W "preflight database webserver php nodejs phpmyadmin postgresql mail rspamd dns ftp ssl security monit webmail ispconfig hostcert rcplugins maildeliver mailsni tuning backup malware" -- "$cur")) ;;
				*) COMPREPLY=($(compgen -W "--resume --only --from --unattended --reconfigure --force --dry-run --clean-build" -- "$cur")) ;;
			esac ;;
		update)   COMPREPLY=($(compgen -W "pkgs security confcustom tuning mail certs rcplugins backup notify nginx ispconfig --dry-run" -- "$cur")) ;;
		rollback) ((COMP_CWORD == 2)) && COMPREPLY=($(compgen -W "nginx roundcube luckystack" -- "$cur")) ;;
		backup)   ((COMP_CWORD == 2)) && COMPREPLY=($(compgen -W "list" -- "$cur")) ;;
		add-php)  ((COMP_CWORD == 2)) && COMPREPLY=($(compgen -W "7.4 8.0 8.1 8.2 8.3 8.4 8.5" -- "$cur")) ;;
		timezone) ((COMP_CWORD == 2)) && COMPREPLY=($(compgen -W "$(timedatectl list-timezones 2>/dev/null)" -- "$cur")) ;;
		uninstall) COMPREPLY=($(compgen -W "--purge" -- "$cur")) ;;
		help)     ((COMP_CWORD == 2)) && COMPREPLY=($(compgen -W "$cmds" -- "$cur")) ;;
	esac
}
complete -F _luckyctl luckyctl
