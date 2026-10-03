pacman -Q xdg-utils
grep -i -A6 'hoffice' /var/log/pacman.log | grep -i -E 'scriptlet|error|warning' | tail -10
grep -H -E '^(Exec|TryExec|Icon|NoDisplay|OnlyShowIn|NotShowIn|Hidden)=' $(pacman -Ql hoffice | awk '/\.desktop$/{print $2}')
