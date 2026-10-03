sudo mkdir -p /etc/pacman.d/hooks
sudo tee /etc/pacman.d/hooks/90-kernel-install-add.hook >/dev/null <<'EOF'
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/modules/*/vmlinuz

[Action]
Description = Adding kernel to ESP (kernel-install)...
When = PostTransaction
Exec = /bin/sh -c 'while read -r f; do v="${f#usr/lib/modules/}"; v="${v%/vmlinuz}"; kernel-install add "$v" "/$f"; done'
NeedsTargets
EOF
sudo tee /etc/pacman.d/hooks/91-kernel-install-remove.hook >/dev/null <<'EOF'
[Trigger]
Type = Path
Operation = Remove
Target = usr/lib/modules/*/vmlinuz

[Action]
Description = Removing old kernel from ESP (kernel-install)...
When = PostTransaction
Exec = /bin/sh -c 'while read -r f; do v="${f#usr/lib/modules/}"; v="${v%/vmlinuz}"; kernel-install remove "$v"; done'
NeedsTargets
EOF
