
# source shared helpers placed next to scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
if [ -f "$SCRIPT_DIR/common.sh" ]; then
   # shellcheck source=/dev/null
   source "$SCRIPT_DIR/common.sh"
else
   echo "[WARN] common.sh not found in $SCRIPT_DIR; continuing without shared helpers"
fi

# Helper to check previous command status and report via ok()/err()
check() {
   local rc=${1:-$?}
   local msg=${2:-"command"}
   if [ "$rc" -ne 0 ]; then
      err "$msg failed (exit code $rc)"
      return $rc
   else
      ok "$msg succeeded"
      return 0
   fi
}

info "Etap 1: instalacja pakietów, konfiguracja usług i uruchomienie kontenerów"

info "Aktualizuję bazę pakietów i instaluję wymagane pakiety systemowe"
pacman -Syu --noconfirm
check $? "pacman -Syu"

info "Instaluję zbiór przydatnych narzędzi i bibliotek (tmux, reflector, docker, samba itp.)"
for pkg in  tmux reflector btop ncdu dysk unp unzip base-devel wget curl zsh mc openssh exa nano docker zsh-syntax-highlighting samba smbclient ntfs-3g fuse aria2 fastfetch htop pacman-contrib; do
   pacman -S --needed --noconfirm "$pkg"
done
check $? "install packages with pacman"

info "Aktualizuję listę mirrorów pacman przy pomocy reflector (najlepsze HTTPS)"
reflector --verbose --latest 30 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
check $? "reflector -- save mirrorlist"

info "Włączam i uruchamiam usługę SSH (sshd)"
systemctl start sshd
check $? "systemctl start sshd"
systemctl enable sshd
check $? "systemctl enable sshd"

info "Kopiuję konfigurację Homer do katalogu użytkownika"
cp -r /home/xc/auto/config/Homer/ /home/xc/.config/Homer
check $? "copy Homer config"

info "Instaluję rozszerzenia i konfigurację edytora nano (nanorc)"
git clone https://github.com/scopatz/nanorc.git
check $? "git clone nanorc"
cd nanorc
check $? "cd nanorc"
make install
check $? "nanorc make install"
bash install.sh
check $? "nanorc install.sh"
cd ..
rm -r nanorc
check $? "remove nanorc directory"

info "Konfiguruję i uruchamiam Docker oraz instaluję Portainer do zarządzania kontenerami"
systemctl daemon-reload
check $? "systemctl daemon-reload"
systemctl start docker.socket
check $? "systemctl start docker.socket"
systemctl enable docker.service
check $? "systemctl enable docker.service"

usermod -aG docker xc
check $? "usermod -aG docker xc"

docker pull portainer/portainer-ce:latest
check $? "docker pull portainer"
docker run -d -p 9000:9000 -p 9443:9443 --name=portainer --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest
check $? "docker run portainer"

generate_content() {
    cat <<'EOF'
[global]
   workgroup = MYGROUP
   server string = Samba Server
   server role = standalone server
   log file = /usr/local/samba/var/log.%m
   max log size = 50
   dns proxy = no

[filmy]
   path = /media/usb3/Filmy
   writable = yes
   guest ok = no

[Downloads]
   path = /media/usb3/Downloads
   writable = yes
   guest ok = no

[Soft]
   path = /media/usb3/Soft
   writable = yes
   guest ok = no

[Adi]
   path = /media/usb3/Adi
   writable = yes
   guest ok = no

[seriale]
   path = /media/usb3/Seriale
   writable = yes
   guest ok = no

[kopie]
   path = /media/usb3/KOPIE
   writable = yes
   guest ok = no

[qbit]
   path = /home/xc/Downloads
   writable = yes
   guest ok = no
EOF
}

#read -s -p "Enter Samba password: " PASSWORD
#echo

info "Konfiguruję Samba: ustawię fstab, wygeneruję smb.conf i dodam użytkownika Samba"
printf "Enter Samba password: "
stty -echo
read PASSWORD
stty echo
echo

mkdir -p /media/usb3
if blkid -U 6CEAD123EAD0EA7A &>/dev/null; then
    echo 'UUID=6CEAD123EAD0EA7A /media/usb3 ntfs-3g rw,defaults 0 2' >> /etc/fstab
    mount -a
      check $? "mount -a after adding fstab entry"
    #cp smb.conf /etc/samba/smb.conf
        if [ ! -f /etc/samba/smb.conf ]; then
            generate_content > /etc/samba/smb.conf
            check $? "generate /etc/samba/smb.conf"
        fi
    #echo -e "$PASSWORD\n$PASSWORD" | smbpasswd -s -a xc
    printf "%s\n%s\n" "$PASSWORD" "$PASSWORD" | smbpasswd -s -a xc
   check $? "smbpasswd add user xc"
    unset PASSWORD
    systemctl start smb nmb
   check $? "systemctl start smb nmb"
    systemctl enable smb nmb
   check $? "systemctl enable smb nmb"
else
    echo "UUID=6CEAD123EAD0EA7A not found, skipping /etc/fstab entry"
fi

# Helper: call available compose implementation (prefer `docker compose`, fall back to `docker-compose`)
compose() {
   if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
      docker compose "$@"
      return $?
   fi
   if command -v docker-compose >/dev/null 2>&1; then
      docker-compose "$@"
      return $?
   fi
      echo "Neither 'docker compose' nor 'docker-compose' found — attempting to install docker-compose via pacman..." >&2
      if command -v pacman >/dev/null 2>&1; then
         pacman -S --needed --noconfirm docker-compose || true
         if command -v docker-compose >/dev/null 2>&1; then
            docker-compose "$@"
            return $?
         fi
         echo "Installation completed but 'docker-compose' still not available." >&2
         return 1
      else
         echo "Error: pacman not found — cannot install docker-compose automatically." >&2
         return 1
      fi
}

info "Uruchamiam zestaw usług Docker Compose z dostępnych plików YAML"
compose -f browser.yaml up -d
check $? "compose browser.yaml up"
compose -f homer.yaml up -d
check $? "compose homer.yaml up"
compose -f jellyfin.yaml up -d
check $? "compose jellyfin.yaml up"
compose -f qbittorrent.yaml up -d
check $? "compose qbittorrent.yaml up"
compose -f jdownloader.yaml up -d
check $? "compose jdownloader.yaml up"
compose -f watchtower.yaml up -d
check $? "compose watchtower.yaml up"

info "Na koniec: instrukcja instalacji Oh My Zsh dla zwykłego użytkownika"
echo "Please log as regular user (su xc) and copy and paste the following command into your terminal:"
echo "sh -c \"\$(wget https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -O -)\""

#docker run --detach --name watchtower --volume /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower
