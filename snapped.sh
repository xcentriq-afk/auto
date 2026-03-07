#!/usr/bin/env bash
#
# install-snapper-snap-pac-auto.sh
# Usage: sudo ./install-snapper-snap-pac-auto.sh
#
# Installs Snapper + grub-btrfs and builds snap-pac from AUR in user's home.
# Ensures makepkg runs as non-root. Automatically imports missing PGP keys if needed.
#
set -euo pipefail
IFS=$'\n\t'

info(){ printf "\e[1;34m[INFO]\e[0m %s\n" "$*"; }
ok(){   printf "\e[1;32m[ OK ]\e[0m %s\n" "$*"; }
warn(){ printf "\e[1;33m[WARN]\e[0m %s\n" "$*"; }
err(){  printf "\e[1;31m[ERR ]\e[0m %s\n" "$*"; }

if [ "$(id -u)" -ne 0 ]; then
  err "Uruchom skrypt jako root (sudo)."
  exit 2
fi

# ----------------- DETECT REAL USER -----------------
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

# ----------------- PACKAGES -----------------
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

# ----------------- BTRFS QUOTA -----------------
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

# ----------------- SNAPPR / GRUB -----------------
info "Tworzę konfigurację snapper (root) jeśli nie istnieje..."
if snapper -c root list >/dev/null 2>&1; then
  ok "snapper root config exists"
else
  snapper -c root create-config / && ok "snapper root config created" || warn "snapper create-config returned non-zero"
fi

info "Opcjonalnie tworzenie snapper dla /home (jeśli jest oddzielny mount)..."
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

# ----------------- AUR BUILD: snap-pac (Variant C) -----------------
AUR_PKG="snap-pac"
BUILD_DIR="$USER_HOME/.cache/aurbuild/$AUR_PKG"

# create build base
info "Przygotowuję katalog build: $BUILD_DIR"
mkdir -p "$BUILD_DIR"
chown -R "$REAL_USER":"$REAL_USER" "$(dirname "$BUILD_DIR")"

# helper: run command as user and capture stdout+stderr
run_as_user() {
  local cmd="$1"
  sudo -u "$REAL_USER" bash -lc "$cmd"
}

# helper: try importing a PGP key via several keyservers
import_pgp_key() {
  local key="$1"
  info "Importing PGP key: $key"
  # try multiple keyservers
  local servers=("hkps://keyserver.ubuntu.com" "hkps://keys.openpgp.org" "hkps://pgp.mit.edu")
  for s in "${servers[@]}"; do
    info "  trying keyserver $s ..."
    if sudo -u "$REAL_USER" gpg --keyserver "$s" --recv-keys "$key" >/dev/null 2>&1; then
      ok "Imported key $key from $s"
      return 0
    fi
  done

  # as fallback try fetching raw key via keyserver web interface
  info "  trying HTTP fetch from keyserver.ubuntu.com"
  if sudo -u "$REAL_USER" bash -lc "curl -s 'https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${key}' | gpg --import >/dev/null 2>&1"; then
    ok "Imported key $key via HTTP fetch"
    return 0
  fi

  warn "Nie udało się zaimportować klucza $key automatycznie"
  return 1
}

# function: build AUR package as REAL_USER, try to auto-resolve missing PGP keys
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
  # run makepkg and capture output
  set +e
  run_as_user "cd '$builddir' && makepkg -f" > /tmp/makepkg-output-$$.txt 2>&1
  MKRC=$?
  set -e

  if [ $MKRC -eq 0 ]; then
    ok "makepkg succeeded for $pkg"
    # install produced package(s)
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

  # if failed, inspect output for "unknown public key" pattern
  OUTPUT_FILE="/tmp/makepkg-output-$$.txt"
  if [ -f "$OUTPUT_FILE" ]; then
    if grep -q -E "unknown public key|NO_PUBKEY|failed \\(unknown public key|could not be verified" "$OUTPUT_FILE"; then
      # try to extract hex key IDs like E4B5E45AA3B8C5C3 or 0xE4B5...
      KEYIDS=$(grep -Po "([A-F0-9]{8,40})" "$OUTPUT_FILE" | awk '{print $1}' | uniq || true)
      # filter plausible long hex strings (>=16 hex chars)
      KEYIDS=$(echo "$KEYIDS" | awk 'length($0)>=16' || true)
      info "Detected potential missing key ids: ${KEYIDS:-<none>}"
      for key in $KEYIDS; do
        # ensure uppercase and strip 0x
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
            # continue trying other keys if any
          fi
        fi
      done
      warn "Nie udało się odtworzyć makepkg poprzez import kluczy. Zostawiam builddir dla debugu: $builddir"
      # print last 200 lines for user
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

# run the build
info "Buduję AUR package: $AUR_PKG"
if build_aur_with_pgp_retry "$AUR_PKG"; then
  ok "$AUR_PKG built & installed successfully"
else
  warn "Build/install $AUR_PKG failed or needs manual intervention. See messages above."
fi

# ----------------- FINAL CHECKS -----------------
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

info "DONE. If AUR build left a directory for debugging, check: $USER_HOME/.cache/aurbuild/$AUR_PKG"
info "Tworzę pierwszy snapshot użytkownika..."
snapper -c root create -d "pierwszy snapshot po instalacji" --cleanup-algorithm=number && \
ok "Pierwszy snapshot utworzony."
rm -rf ~/.cache/aurbuild
rm -rf ~/snap-pac

info "Zalogój się na konto 'root' i uruchom ponownie snapped.sh, aby dokończyć konfigurację."
info "su root"
