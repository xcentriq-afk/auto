#!/usr/bin/env bash
# Merged script: common.sh + run.sh + snapped.sh + stage1.sh
# Usage: sudo ./install_all.sh
set -euo pipefail
IFS=$'\n\t'

# ----------------- COMMON HELPERS (from common.sh) -----------------
info(){ printf "\e[1;34m[INFO]\e[0m %s\n" "$*"; }
ok(){   printf "\e[1;32m[ OK ]\e[0m %s\n" "$*"; }
warn(){ printf "\e[1;33m[WARN]\e[0m %s\n" "$*"; }
err(){  printf "\e[1;31m[ERR ]\e[0m %s\n" "$*"; }

# ----------------- STAGE1 HELPERS (from stage1.sh) -----------------
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

# Helper: call available compose implementation (from stage1.sh)
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

# ----------------- SNAPPED / AUR BUILD HELPERS (from snapped.sh) -----------------
run_as_user() {
  local cmd="$1"
  sudo -u "$REAL_USER" bash -lc "$cmd"
}

import_pgp_key() {
  local key="$1"
  info "Importing PGP key: $key"
  local servers=("hkps://keyserver.ubuntu.com" "hkps://keys.openpgp.org" "hkps://pgp.mit.edu")
  for s in "${servers[@]}"; do
    info "  trying keyserver $s ..."
    if sudo -u "$REAL_USER" gpg --keyserver "$s" --recv-keys "$key" >/dev/null 2>&1; then
      ok "Imported key $key from $s"
      return 0
    fi
  done
  info "  trying HTTP fetch from keyserver.ubuntu.com"
  if sudo -u "$REAL_USER" bash -lc "curl -s 'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${key}' | gpg --import >/dev/null 2>&1"; then
    ok "Imported key $key via HTTP fetch"
    return 0
  fi
  warn "Nie udało się zaimportować klucza $key automatycznie"
  return 1
}

build_aur_with_pgp_retry() {
  local pkg="$1"
  local builddir="$USER_HOME/.cache/aurbuild/$pkg"
  rm -rf "$builddir"
  mkdir -p "$builddir"
  chown -R "$REAL_USER":"$REAL_USER" "$builddir"

  info "Cloning $pkg AUR repo into $builddir (as $REAL_USER)"
  if ! run_as_user "git clone https://aur.archlinux.org/${pkg}.git '$builddir'"; then
    warn "git clone failed for ${pkg}"
    return 1
  fi

  pushd "$builddir" >/dev/null

  info "Starting makepkg (as $REAL_USER) for $pkg. If PGP signature missing, script will try to import key and retry."
  set +e
  run_as_user "cd '$builddir' && makepkg -f" > /tmp/makepkg-output-$$.txt 2>&1
  MKRC=$?
  set -e

  if [ $MKRC -eq 0 ]; then
    ok "makepkg succeeded for $pkg"
    PKGFILE=$(run_as_user "ls -1t $builddir/*.pkg.tar.* 2>/dev/null || true")
    if [ -n "$PKGFILE" ]; then
      info "Installing produced package(s):"
      for f in $PKGFILE; do
        info "  pacman -U $f"
        pacman -U --noconfirm "$f" || { warn "pacman -U failed for $f"; popd >/dev/null; return 1; }
      done
      popd >/dev/null
      ok "$pkg built & installed"
      rm -f /tmp/makepkg-output-$$.txt
      return 0
    else
      warn "Brak wygenerowanego pliku pakietu, mimo że makepkg zakończył się powodzeniem"
      popd >/dev/null
      return 1
    fi
  fi

  OUTPUT_FILE="/tmp/makepkg-output-$$.txt"
  if [ -f "$OUTPUT_FILE" ]; then
    if grep -q -E "unknown public key|NO_PUBKEY|failed \\(unknown public key|could not be verified" "$OUTPUT_FILE"; then
      KEYIDS=$(grep -Po "([A-F0-9]{8,40})" "$OUTPUT_FILE" | awk '{print $1}' | uniq || true)
      KEYIDS=$(echo "$KEYIDS" | awk 'length($0)>=16' || true)
      info "Detected potential missing key ids: ${KEYIDS:-<none>}"
      for key in $KEYIDS; do
        key=$(echo "$key" | sed 's/^0x//I' | tr '[:lower:]' '[:upper:]')
        if [ -z "$key" ]; then continue; fi
        if import_pgp_key "$key"; then
          info "Re-trying makepkg after importing $key"
          set +e
          run_as_user "cd '$builddir' && makepkg -f" > /tmp/makepkg-output-$$.txt 2>&1
          MKRC2=$?
          set -e
          if [ $MKRC2 -eq 0 ]; then
            ok "makepkg succeeded after importing key $key"
            PKGFILE=$(run_as_user "ls -1t $builddir/*.pkg.tar.* 2>/dev/null || true")
            if [ -n "$PKGFILE" ]; then
              for f in $PKGFILE; do
                pacman -U --noconfirm "$f" || { warn "pacman -U failed for $f"; popd >/dev/null; return 1; }
              done
              popd >/dev/null
              rm -f /tmp/makepkg-output-$$.txt
              return 0
            else
              warn "Brak paczki po udanym makepkg"
              popd >/dev/null
              return 1
            fi
          else
            warn "makepkg nadal nie działa po imporcie klucza $key"
          fi
        fi
      done
      warn "Nie udało się odtworzyć makepkg poprzez import kluczy. Zostawiam builddir dla debugu: $builddir"
      tail -n 200 "$OUTPUT_FILE" || true
      popd >/dev/null
      return 2
    else
      warn "makepkg nie powiódł się z innego powodu. Zawartość logu:"
      tail -n 200 "$OUTPUT_FILE" || true
      popd >/dev/null
      return 3
    fi
  else
    warn "Brak logu makepkg (coś poszło nie tak)"
    popd >/dev/null
    return 4
  fi
}

# ----------------- TASK FUNCTIONS (merged bodies) -----------------

do_snapped() {
  # This function is adapted from snapped.sh
  if [ "$(id -u)" -ne 0 ]; then
    err "Uruchom skrypt jako root (sudo)."
    exit 2
  fi

  # DETECT REAL USER
  REAL_USER=""
  if command -v logname >/dev/null 2>&1; then
    REAL_USER=$(logname 2>/dev/null || true)
  fi
  if [ -z "$REAL_USER" ] && [ -n "${SUDO_USER-}" ]; then
    REAL_USER="$SUDO_USER"
  fi
  if [ -z "$REAL_USER" ]; then
    REAL_USER=$(awk -F: '($3>=1000 && $1!="nobody"){print $1; exit}' /etc/passwd || true)
  fi
  if [ -z "$REAL_USER" ]; then
    err "Nie mogę ustalić zwykłego użytkownika (REAL_USER). Uruchom skrypt przez sudo z konta użytkownika."
    exit 3
  fi
  USER_HOME=$(eval echo "~$REAL_USER")
  info "Real user: $REAL_USER"
  info "User home: $USER_HOME"

  REQ_PKGS=(snapper grub-btrfs btrfs-progs base-devel git gnupg)
  info "Instaluję / sprawdzam pakiety: ${REQ_PKGS[*]}"
  pacman -Syu --noconfirm >/dev/null 2>&1 || true
  for p in "${REQ_PKGS[@]}"; do
    if pacman -Qi "$p" >/dev/null 2>&1; then
      ok "$p already installed"
    else
      info "Instaluję $p..."
      pacman -S --noconfirm --needed "$p"
    fi
  done

  info "Sprawdzam btrfs quota..."
  if btrfs qgroup show / >/dev/null 2>&1; then
    ok "Btrfs quotas available"
  else
    info "Włączam btrfs quota (best-effort)..."
    set +e
    btrfs quota enable / >/dev/null 2>&1 || true
    set -e
    if btrfs qgroup show / >/dev/null 2>&1; then
      ok "Btrfs quota enabled"
    else
      warn "Nie udało się włączyć btrfs quota automatycznie. Możesz uruchomić ręcznie: sudo btrfs quota enable /"
    fi
  fi

  info "Tworzę konfigurację snapper (root) jeśli nie istnieje..."
  if snapper -c root list >/dev/null 2>&1; then
    ok "snapper root config exists"
  else
    snapper -c root create-config / && ok "snapper root config created" || warn "snapper create-config returned non-zero"
  fi

  if mountpoint -q /home; then
    if snapper -c home list >/dev/null 2>&1; then
      ok "snapper home config exists"
    else
      snapper -c home create-config /home && ok "snapper home config created" || warn "snapper create-config /home returned non-zero"
    fi
  else
    info "/home nie jest osobnym punktem montowania — pomijam"
  fi

  info "Włączam snapper-timers"
  systemctl enable --now snapper-timeline.timer || warn "Could not enable snapper-timeline.timer"
  systemctl enable --now snapper-cleanup.timer || warn "Could not enable snapper-cleanup.timer"

  info "Włączam i restartuję grub-btrfsd"
  systemctl enable --now grub-btrfsd.service || warn "Could not enable grub-btrfsd.service"
  systemctl restart grub-btrfsd.service || warn "Restart grub-btrfsd failed"

  if command -v grub-mkconfig >/dev/null 2>&1; then
    info "Regeneruję grub.cfg"
    grub-mkconfig -o /boot/grub/grub.cfg || warn "grub-mkconfig returned non-zero"
  fi

  AUR_PKG="snap-pac"
  BUILD_DIR="$USER_HOME/.cache/aurbuild/$AUR_PKG"

  info "Przygotowuję katalog build: $BUILD_DIR"
  mkdir -p "$BUILD_DIR"
  chown -R "$REAL_USER":"$REAL_USER" "$(dirname "$BUILD_DIR")"

  if build_aur_with_pgp_retry "$AUR_PKG"; then
    ok "$AUR_PKG built & installed successfully"
  else
    warn "Build/install $AUR_PKG failed or needs manual intervention. See messages above."
  fi

  info "Final checks:"
  info "- snapper root list:"
  snapper -c root list || true

  if mountpoint -q /home; then
    info "- snapper home list (if configured):"
    snapper -c home list || true
  fi

  info "- grep grub.cfg for snapshot lines (if grub-btrfs created entries):"
  if command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
  fi
  if grep -n -E 'Snapshot|snapshot|Snapshots|snapper' /boot/grub/grub.cfg >/dev/null 2>&1; then
    ok "Found snapshot entries in /boot/grub/grub.cfg"
    grep -n -E 'Snapshot|snapshot|Snapshots|snapper' /boot/grub/grub.cfg | sed -n '1,120p' || true
  else
    warn "No snapshot entries found in grub.cfg (maybe grub-btrfsd needs debugging)"
  fi

  info "Tworzę pierwszy snapshot użytkownika..."
  snapper -c root create -d "pierwszy snapshot po instalacji" --cleanup-algorithm=number && ok "Pierwszy snapshot utworzony."
  rm -rf ~/.cache/aurbuild
  rm -rf ~/snap-pac

  info "---*---*---*---*---*---*---*---*---*---*---*---*---*---*---*---*---*---*---*---*---*---*---*---*---*---*---"
  info "Etap 1 zakończony. Usługi powinny być uruchomione. Możesz sprawdzić status kontenerów poleceniem: docker ps"
  info "Proszę zalogować się jako xc (su xc) i skopiować poniższy command do terminala:"
  info "sh -c \"\$(wget https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -O -)\""
  info "---*---*---*---*---*---*---*---*---*---*---*---*---*---*---*---*---*---*---*---*---*---*---*---*---*---*---"
}


do_stage1() {
  # Adapted from stage1.sh main actions
  info "Etap 1: instalacja pakietów, konfiguracja usług i uruchomienie kontenerów"

  info "Aktualizuję bazę pakietów i instaluję wymagane pakiety systemowe"
  pacman -Syu --noconfirm
  check $? "pacman -Syu"

  info "Instaluję zbiór przydatnych narzędzi i bibliotek"
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
  mkdir -p /home/xc/.config/Homer
  cp -r /home/xc/auto/config/Homer/ /home/xc/.config/
  check $? "copy Homer config"

  mkdir -p /media/usb3 && chown xc:xc /media/usb3 && chmod 755 /media/usb3 && ok "Created /media/usb3 with proper permissions"
  echo 'UUID=6CEAD123EAD0EA7A /media/usb3 ntfs-3g rw,defaults 0 2' >> /etc/fstab && ok "Added USB drive to /etc/fstab"
  mount -a || warn "mount -a failed (check /etc/fstab and disk UUID)" 
  cp smb.conf /etc/samba/smb.conf && check $? "copy smb.conf"
  smbpasswd -a xc && check $? "smbpasswd -a xc"
  systemctl start smb nmb && check $? "systemctl start smb nmb"
  systemctl enable smb nmb  && check $? "systemctl enable smb nmb"

  info "Instaluję rozszerzenia i konfigurację edytora nano (nanorc)"
  git clone https://github.com/scopatz/nanorc.git
  check $? "git clone nanorc"
  cd nanorc || true
  check $? "cd nanorc"
  make install || true
  check $? "nanorc make install"
  bash install.sh || true
  check $? "nanorc install.sh"
  cd .. || true
  rm -r nanorc || true
  check $? "remove nanorc directory"

  info "Konfiguruję i uruchamiam Docker oraz instaluję Portainer do zarządzania kontenerami"
  systemctl daemon-reload
  check $? "systemctl daemon-reload"
  systemctl start docker.socket
  check $? "systemctl start docker.socket"
  systemctl enable docker.service
  check $? "systemctl enable docker.service"

  usermod -aG docker xc || true
  check $? "usermod -aG docker xc"

  docker pull portainer/portainer-ce:latest || true
  check $? "docker pull portainer"
  docker run -d -p 9000:9000 -p 9443:9443 --name=portainer --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest || true
  check $? "docker run portainer"

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
  info "Wszystkie kontenery powinny być uruchomione. Sprawdź: docker ps"
}

# ----------------- MAIN ENTRYPOINT -----------------
main() {
  echo
  info ">>> Uruchamianie kroków: stage1 i snapped"
  echo

  # Ensure script is executable and run tasks
  do_stage1
  do_snapped
}

main "$@"
