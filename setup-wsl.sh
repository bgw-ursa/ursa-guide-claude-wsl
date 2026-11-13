#!/usr/bin/env bash
# setup-wsl.sh: automates the Linux side of the WSL guide (Steps 2-10).
#
# Run inside WSL as your normal user, not as root and not as claude:
#   REPO=new-forge GITHUB_USER=yourname-ursa bash setup-wsl.sh
#
# Options:
#   --from STEP   start at STEP and run every step after it (e.g. --from 10)
#   --only STEP   run just STEP
#   --list        print the steps in the order they run, then exit
# STEP is a step number from the full guide, or "packages". The steps run in
# this order: packages 2 3 4 5 6 7 9 10 8. Step 8 runs last on purpose: it makes
# claude the default user and turns off the Windows drives at the next restart,
# so it only runs once everything else has succeeded.
#
# Safe to re-run: every step checks before it changes anything, so after a
# failure or a WSL restart you can run it again and it picks up where it left off.
#
# Not covered (manual): Step 1 (install WSL and Ubuntu), adding the key to
# GitHub and forking (the script pauses for this), the Windows side of Step 9
# (create the VS Code key, add the host entry, install Remote - SSH; the script
# asks you to paste the public key), the first `claude` sign-in and /sandbox
# check, and the Claude Desktop checks in Step 11.

set -euo pipefail

# ---------- settings (same values as the guide's "Customize this guide" form) ----------
REPO="${REPO:-new-forge}"
GITHUB_USER="${GITHUB_USER:-}"
SQUID_MODE="${SQUID_MODE:-open}"   # open (evaluation period: allow all domains) | allowlist (production)
NVM_VERSION="v0.40.8"
SQLMESH_VERSION="0.235.4"
DUCKDB_VERSION="1.5.6"

U="$USER"
H="$HOME"
REPO_DIR="$H/git/$REPO"
CLAUDE_HOME="/home/claude"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

# append_once FILE LINE [USER]: append LINE to FILE unless it is already there.
# With USER, the check and the append run as that user (for claude's files).
append_once() {
  local file=$1 line=$2 as=${3:-}
  if [ -n "$as" ]; then
    sudo -u "$as" -H grep -qxF -- "$line" "$file" 2>/dev/null ||
      printf '%s\n' "$line" | sudo -u "$as" -H tee -a "$file" >/dev/null
  else
    grep -qxF -- "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >> "$file"
  fi
}

STEP_ORDER=(packages 2 3 4 5 6 7 9 10 8)
FROM=""; ONLY=""
usage() { sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM=${2:-}; shift 2 || { usage; exit 1; } ;;
    --only) ONLY=${2:-}; shift 2 || { usage; exit 1; } ;;
    --list) echo "${STEP_ORDER[*]}"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done
for v in "$FROM" "$ONLY"; do
  [ -z "$v" ] || [[ " ${STEP_ORDER[*]} " == *" $v "* ]] ||
    { echo "Unknown step '$v'. Steps: ${STEP_ORDER[*]}" >&2; exit 1; }
done

# ---------- preflight ----------
if [ "$(id -u)" -eq 0 ] || [ "$U" = "claude" ]; then
  echo "Run this as your normal user (not root, not claude), e.g. from 'wsl -u <you>'." >&2
  exit 1
fi
if [ -z "$GITHUB_USER" ]; then
  read -erp "GitHub username (your personal Ursa account): " GITHUB_USER
fi
[ -n "$GITHUB_USER" ] || { echo "GitHub username is required." >&2; exit 1; }
case "$SQUID_MODE" in allowlist|open) ;; *) echo "SQUID_MODE must be allowlist or open." >&2; exit 1 ;; esac

say "Settings: user=$U repo=$REPO github=$GITHUB_USER squid=$SQUID_MODE"
sudo -v
# Keep sudo's credential cache warm until the script exits.
while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &

SYSTEMD=false
[ "$(ps -p 1 -o comm=)" = "systemd" ] && SYSTEMD=true
umask 002   # so files this script creates (node_modules, .venv) are group-writable

# ---------- packages (Steps 6, 7, 9, 10) ----------
step_packages() {
say "Installing packages"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git curl iptables squid iptables-persistent bubblewrap socat \
  openssh-server python3-pip python3-venv

}

# ---------- Step 2: GitHub key and clone ----------
step_2() {
say "Step 2: GitHub SSH key"
mkdir -p "$H/.ssh" && chmod 700 "$H/.ssh"
if [ ! -f "$H/.ssh/ursa-github" ]; then
  ssh-keygen -q -t ed25519 -N "" -C "$GITHUB_USER@wsl" -f "$H/.ssh/ursa-github"
fi
if ! grep -qx 'Host github.com' "$H/.ssh/config" 2>/dev/null; then
  cat >> "$H/.ssh/config" <<'EOF'

Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/ursa-github
  IdentitiesOnly yes
EOF
fi
chmod 600 "$H/.ssh/config"

if [ ! -d "$REPO_DIR/.git" ]; then
  # `ssh -T` exits 1 even when authentication succeeds, so test its output, not its status.
  github_ok() {
    local out
    out=$(ssh -T -o StrictHostKeyChecking=accept-new git@github.com 2>&1 || true)
    grep -q "successfully authenticated" <<<"$out"
  }
  # Put the key on the Windows clipboard, so it doesn't have to be selected in the terminal.
  # Works until Step 8's restart turns off the Windows drives; after that it quietly does nothing.
  copy_key() {
    local clip=/mnt/c/Windows/System32/clip.exe
    [ -x "$clip" ] && "$clip" < "$H/.ssh/ursa-github.pub" 2>/dev/null
  }
  until github_ok; do
    echo
    note "GitHub doesn't accept the key yet. In a browser, signed in as $GITHUB_USER:"
    note "  1. Settings > SSH and GPG keys > New SSH key, and paste this line:"
    echo
    cat "$H/.ssh/ursa-github.pub"
    echo
    if copy_key; then
      note "     It's already on your Windows clipboard: paste it in GitHub with Ctrl+V."
    fi
    note "  2. Fork https://github.com/ursahealth/$REPO into $GITHUB_USER if you haven't already."
    while true; do
      read -erp "    Press Enter to test again, or type c and Enter to copy the key again: " ans
      case "$ans" in
        c|C) if copy_key; then note "Copied."; else note "Couldn't reach the Windows clipboard. Select the line above with the mouse instead."; fi ;;
        *) break ;;
      esac
    done
  done
  mkdir -p "$H/git"
  git clone "git@github.com:$GITHUB_USER/$REPO.git" "$REPO_DIR"
fi

}

# ---------- Step 3: group and agent user ----------
step_3() {
say "Step 3: agentic group and claude user"
getent group agentic >/dev/null || sudo groupadd agentic
id claude >/dev/null 2>&1 || sudo useradd -m -s /bin/bash -G agentic claude
id -nG "$U" | grep -qw agentic || sudo usermod -aG agentic "$U"
append_once "$H/.bashrc" "alias claude='echo \"Please run claude as the claude user (e.g. wsl -u claude from cmd)\"'"

}

# ---------- Step 4: share the repository ----------
step_4() {
say "Step 4: share $REPO_DIR with claude"
sudo chgrp -R agentic "$REPO_DIR"
sudo chmod -R g+rwX "$REPO_DIR"
sudo find "$REPO_DIR" -type d -exec chmod g+s {} +
append_once "$H/.bashrc" 'umask 002'
append_once "$CLAUDE_HOME/.bashrc" 'umask 002' claude
chmod o+x "$H"

sudo mkdir -p "$CLAUDE_HOME/$REPO"
mountpoint -q "$CLAUDE_HOME/$REPO" || sudo mount --bind "$REPO_DIR" "$CLAUDE_HOME/$REPO"
FSTAB_LINE="$REPO_DIR $CLAUDE_HOME/$REPO none bind 0 0"
sudo grep -qxF -- "$FSTAB_LINE" /etc/fstab || echo "$FSTAB_LINE" | sudo tee -a /etc/fstab >/dev/null

for d in "$REPO_DIR" "$CLAUDE_HOME/$REPO"; do
  sudo -u claude -H git config --global --get-all safe.directory 2>/dev/null | grep -qxF -- "$d" ||
    sudo -u claude -H git config --global --add safe.directory "$d"
done

}

# ---------- Step 5: Claude Code for claude (must run before the network lockdown) ----------
step_5() {
say "Step 5: Claude Code for claude"
if ! sudo -u claude -H test -x "$CLAUDE_HOME/.local/bin/claude"; then
  sudo -u claude -H bash -c 'cd ~ && curl -fsSL https://claude.ai/install.sh | bash'
fi
append_once "$CLAUDE_HOME/.bashrc" 'export PATH="$HOME/.local/bin:$PATH"' claude
append_once "$CLAUDE_HOME/.bashrc" "cd $REPO_DIR 2>/dev/null" claude

}

# ---------- Step 6: network lockdown ----------
step_6() {
say "Step 6: Squid ($SQUID_MODE) and iptables"
if [ "$SQUID_MODE" = "open" ]; then
  sudo tee /etc/squid/squid.conf >/dev/null <<'EOF'
http_port 127.0.0.1:3128
acl allowed dstdomain "/etc/squid/allowed-domains.txt"
acl SSL_ports port 443
acl CONNECT method CONNECT
http_access deny CONNECT !SSL_ports
http_access allow localhost allowed
# deny all for prod
http_access allow all
# deny all for prod
cache allow all
EOF
else
  sudo tee /etc/squid/squid.conf >/dev/null <<'EOF'
http_port 127.0.0.1:3128
acl allowed dstdomain "/etc/squid/allowed-domains.txt"
acl SSL_ports port 443
acl CONNECT method CONNECT
http_access deny CONNECT !SSL_ports
http_access allow localhost allowed
http_access deny all
cache deny all
EOF
fi
# Written only once, so domains you add later survive a re-run.
if [ ! -f /etc/squid/allowed-domains.txt ]; then
  sudo tee /etc/squid/allowed-domains.txt >/dev/null <<'EOF'
.anthropic.com
.claude.ai
.claude.com
#.github.com
#.githubusercontent.com
#registry.npmjs.org
#pypi.org
#files.pythonhosted.org
EOF
fi
sudo squid -k parse
sudo service squid restart

for ipt in iptables ip6tables; do
  sudo $ipt -N CLAUDE_OUT 2>/dev/null || sudo $ipt -F CLAUDE_OUT
  sudo $ipt -A CLAUDE_OUT -o lo -j ACCEPT
  sudo $ipt -A CLAUDE_OUT -j REJECT
  sudo $ipt -C OUTPUT -m owner --uid-owner claude -j CLAUDE_OUT 2>/dev/null ||
    sudo $ipt -A OUTPUT -m owner --uid-owner claude -j CLAUDE_OUT
done
sudo netfilter-persistent save

if ! sudo -u claude -H grep -q '^export HTTP_PROXY=' "$CLAUDE_HOME/.bashrc"; then
  sudo -u claude -H tee -a "$CLAUDE_HOME/.bashrc" >/dev/null <<'EOF'
export HTTP_PROXY=http://127.0.0.1:3128 HTTPS_PROXY=http://127.0.0.1:3128
export http_proxy=$HTTP_PROXY https_proxy=$HTTPS_PROXY
export NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1
EOF
fi

}

# ---------- Step 7: sandbox ----------
step_7() {
say "Step 7: sandbox and managed settings"
if [ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" = "1" ]; then
  echo 'kernel.apparmor_restrict_unprivileged_userns = 0' | sudo tee /etc/sysctl.d/99-claude-sandbox.conf >/dev/null
  sudo sysctl --system >/dev/null
fi
sudo mkdir -p /etc/claude-code
sudo tee /etc/claude-code/managed-settings.json >/dev/null <<'EOF'
{
  "env": {
    "HTTPS_PROXY": "http://127.0.0.1:3128",
    "HTTP_PROXY": "http://127.0.0.1:3128",
    "NO_PROXY": "localhost,127.0.0.1"
  },
  "sandbox": {
    "enabled": true,
    "failIfUnavailable": true,
    "autoAllowBashIfSandboxed": true,
    "allowUnsandboxedCommands": false,
    "network": {
      "httpProxyPort": 3128,
      "allowAllUnixSockets": true
    }
  }
}
EOF

}

# ---------- Step 9: SSH server for VS Code (needs systemd) ----------
step_9() {
say "Step 9: SSH server on 127.0.0.1:2222"
sudo tee /etc/ssh/sshd_config.d/10-wsl.conf >/dev/null <<EOF
Port 2222
ListenAddress 127.0.0.1
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers $U
EOF
if $SYSTEMD; then
  sudo systemctl disable --now ssh.socket 2>/dev/null || true
  sudo systemctl enable --now ssh
  sudo systemctl restart ssh
else
  note "systemd isn't running yet, so the SSH service is set up on the next run, after the WSL restart."
fi
append_once "$H/.bashrc" "[ \"\$PWD\" = \"\$HOME\" ] && cd ~/git/$REPO 2>/dev/null"

# Authorize the VS Code key created on Windows (pasted, like the AWS keys).
AUTH="$H/.ssh/authorized_keys"
mkdir -p "$H/.ssh" && chmod 700 "$H/.ssh"
if grep -qE '^(ssh-|ecdsa-)' "$AUTH" 2>/dev/null; then
  note "VS Code key: $AUTH already has a key, so there's nothing to paste."
else
  note "Paste the VS Code public key you created on Windows: the line that starts with ssh-ed25519."
  note "Leave it blank to skip; add it later with: bash $0 --only 9"
  while true; do
    read -erp "    VS Code public key: " VSCODE_KEY
    VSCODE_KEY=$(printf '%s' "$VSCODE_KEY" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -z "$VSCODE_KEY" ] && break
    [[ "$VSCODE_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))\ [A-Za-z0-9+/=]+(\ .*)?$ ]] && break
    note "That isn't a public key. Paste the contents of wsl-vscode.pub (one line), not wsl-vscode."
  done
  if [ -n "$VSCODE_KEY" ]; then
    printf '%s\n' "$VSCODE_KEY" >> "$AUTH"
    chmod 600 "$AUTH"
    note "VS Code key added to $AUTH."
  fi
fi

}

# ---------- Step 10: New-Forge tooling ----------
step_10() {
say "Step 10: Node.js, npm packages, Python environment"
export NVM_DIR="$H/.nvm"
# The download can fail on a flaky connection, so try it up to 3 times.
for attempt in 1 2 3; do
  [ -s "$NVM_DIR/nvm.sh" ] && break
  rm -rf "$NVM_DIR"   # clear a half-finished download (no nvm.sh, so nothing usable)
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" | bash && break
  note "nvm download failed (attempt $attempt of 3)."
  [ "$attempt" -lt 3 ] && sleep 5
done
[ -s "$NVM_DIR/nvm.sh" ] || { echo "Couldn't download nvm. Check the connection, then run: bash $0 --from 10" >&2; exit 1; }
set +eu   # nvm isn't compatible with `set -e` or `set -u`
. "$NVM_DIR/nvm.sh"
if [ -f "$REPO_DIR/.nvmrc" ]; then
  cd "$REPO_DIR" && nvm install; NVM_STATUS=$?; cd - >/dev/null
else
  nvm install --lts; NVM_STATUS=$?
fi
set -eu
[ "$NVM_STATUS" -eq 0 ] || { echo "nvm couldn't install Node.js." >&2; exit 1; }
(cd "$REPO_DIR" && npm install)

[ -x "$REPO_DIR/.venv/bin/python" ] || python3 -m venv "$REPO_DIR/.venv"
"$REPO_DIR/.venv/bin/python" -m pip install --upgrade pip
"$REPO_DIR/.venv/bin/pip" install "sqlmesh==$SQLMESH_VERSION" "duckdb==$DUCKDB_VERSION"
VENV_PATH_LINE="export PATH=\"$REPO_DIR/.venv/bin:\$PATH\""
append_once "$H/.bashrc" "$VENV_PATH_LINE"
append_once "$CLAUDE_HOME/.bashrc" "$VENV_PATH_LINE" claude

mkdir -p "$H/.aws" && chmod 700 "$H/.aws"
if [ ! -f "$H/.aws/credentials" ]; then
  note "AWS keys from IT for the New-Forge IAM user. Leave the key ID blank to skip and add them later."
  while true; do
    read -erp "    Paste the AWS access key ID: " AWS_ID
    AWS_ID=$(printf '%s' "$AWS_ID" | tr -d '[:space:]')
    [ -z "$AWS_ID" ] && break
    [[ "$AWS_ID" =~ ^(AKIA|ASIA)[A-Z0-9]{16}$ ]] && break
    note "That doesn't look like an access key ID (20 characters starting with AKIA). Try again."
  done
  if [ -n "$AWS_ID" ]; then
    while true; do
      read -rsp "    Paste the AWS secret access key (hidden): " AWS_SECRET; echo
      AWS_SECRET=$(printf '%s' "$AWS_SECRET" | tr -d '[:space:]')
      [ "${#AWS_SECRET}" -eq 40 ] && break
      note "The secret should be 40 characters; got ${#AWS_SECRET}. Try again."
    done
    note "Secret received: 40 characters, ending in ...${AWS_SECRET: -4}"
    ( umask 077; printf '[default]\naws_access_key_id = %s\naws_secret_access_key = %s\n' \
        "$AWS_ID" "$AWS_SECRET" > "$H/.aws/credentials" )
  fi
fi
[ -f "$H/.aws/credentials" ] && chmod 600 "$H/.aws/credentials"

}

# ---------- Step 8: lock down WSL (takes effect after the restart) ----------
step_8() {
say "Step 8: /etc/wsl.conf (default user claude, no Windows drives)"
sudo tee /etc/wsl.conf >/dev/null <<'EOF'
[boot]
systemd=true #can fail when other WSL instances are running

[user]
default=claude

# Must be the designated, hardened claude user,
# othewise Win Desktop Claude Code,
# will have the other/normal/standard user's perms

[automount]
enabled = false
options = "metadata,umask=777"

# Default user is claude. If human user needs to access /mnt/c, then try 707.
# 707 will disallow default/claude user,
# while allow others in the group and denies those outside of group.
# Assumption: claude and human are same group
# Note that the claude group (agentic) must be 1000.
# In our current config, it winds up being 1001 and that won't work;
# all users still denied.


[interop]
appendWindowsPath = false
enabled = true

# When disabled, "code" command for vsCode in WSL will NOT launch VS Code in Windows.
# Claude agent spawn from Win Claude Desktop will also fail.

EOF

}

# ---------- what's left ----------
started=false
for st in "${STEP_ORDER[@]}"; do
  if [ -n "$ONLY" ]; then
    [ "$st" = "$ONLY" ] || continue
  elif [ -n "$FROM" ] && ! $started; then
    [ "$st" = "$FROM" ] || { note "Skipping step $st"; continue; }
  fi
  started=true
  "step_$st"
done

# Only print the wrap-up after a run that included the last step.
[ -n "$ONLY" ] && [ "$ONLY" != 8 ] && { say "Step $ONLY done."; exit 0; }
SSH_DONE=false
systemctl is-active --quiet ssh 2>/dev/null && SSH_DONE=true

say "Done with the automated part. Remaining manual steps:"
note "1. Exit WSL, then in PowerShell: wsl --shutdown"
if ! $SSH_DONE; then
  note "2. Reopen as yourself with 'wsl -u $U' and run this script again to finish the SSH server."
else
  note "2. (SSH server is already running.)"
fi
note "3. In PowerShell: add the 'wsl' SSH host entry, install Remote - SSH, and connect VS Code."
grep -qE '^(ssh-|ecdsa-)' "$H/.ssh/authorized_keys" 2>/dev/null ||
  note "   No VS Code key yet: open WSL with 'wsl -u $U' and run: bash $0 --only 9"
note "4. Type 'wsl' in PowerShell (opens as claude), run 'claude', sign in, then run /sandbox."
note "5. Check Claude Desktop."
note "Details for 1-5: Steps 4-7 of quick-setup.html."
