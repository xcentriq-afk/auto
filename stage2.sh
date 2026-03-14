info "Adding zsh plugins, aliases, and startup tools to .zshrc"
cat << 'EOF' >> /home/xc/.zshrc

# --- Plugins ---
if [ -f /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]; then
    source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
fi

# --- Aliases ---
alias update="sudo pacman -Syu --noconfirm && paccache -rk0"
alias ls="exa -al@ --colour-scale"

# --- Startup tool ---
if command -v fastfetch >/dev/null 2>&1; then
    fastfetch
fi
if command -v dysk >/dev/null 2>&1; then
    dysk
fi

EOF

info "Installing yay (AUR helper) and lazydocker"
cd /home/xc || exit 1 && \ 
sudo pacman -Sy --needed --noconfirm git base-devel && \
git clone https://aur.archlinux.org/yay.git && \
cd yay && \
sudo mkdir -p /home/xc/.cache/go-build && \
sudo chown -R xc:xc /home/xc/.cache/go-build && \
makepkg -si --noconfirm && \
sudo rm -rf /home/xc/yay && \  
yay -Sy --needed --noconfirm lazydocker 