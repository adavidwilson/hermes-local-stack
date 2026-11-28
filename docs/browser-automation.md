# Browser automation (Chrome via SSH tunnel)

Optional. It lets Hermes drive a real browser on the host: Chrome listens for CDP on
`127.0.0.1:9222`, and the agent reaches it through a restricted SSH tunnel.

The **client** is the machine that runs `ssh` and holds the key — inside this stack that is
`hermes-web`, whose `/opt/data` is `runtime/hermes-home/` on the host.

- **Quadlet (rootless, recommended):** write the config to
  `runtime/hermes-home/home/.ssh/config`, owned by the host user, mode 0600. It is inside
  the mounted `HERMES_HOME`, so no extra mount is needed and the container's `hermes` user
  (UID 1000) can read it.
- **Compose (Docker):** `ssh_config` at the repo root is bind-mounted to
  `/root/.ssh/config`; `scripts/prestart.sh` creates it and it must be `root:root`.

## 1. Create the key (client)

```bash
ssh-keygen -t ed25519 -f /opt/data/home/.ssh/chromecdp_ed25519 -C chromecdp
```

## 2. Create the account (host)

```bash
sudo useradd --create-home --shell /usr/sbin/nologin chromecdp
sudo install -d -o chromecdp -g chromecdp -m 700 /home/chromecdp/.ssh
sudoedit /home/chromecdp/.ssh/authorized_keys
```

## 3. Authorize the key for one port only (host)

Paste the output of `cat ~/.ssh/chromecdp_ed25519.pub` from the client, prefixed on the same line:

```bash
restrict,port-forwarding,permitopen="127.0.0.1:9222"
```

Then:

```bash
sudo chown chromecdp:chromecdp /home/chromecdp/.ssh/authorized_keys
sudo chmod 600 /home/chromecdp/.ssh/authorized_keys
```

## 4. Restrict the account in sshd (host)

Add to `/etc/ssh/sshd_config`:

```bash
Match User chromecdp
   PubkeyAuthentication yes
   PasswordAuthentication no
   KbdInteractiveAuthentication no
   AllowTcpForwarding local
   PermitOpen 127.0.0.1:9222
   AllowAgentForwarding no
   X11Forwarding no
   PermitTTY no
   PermitTunnel no
   MaxSessions 0
```

Validate and reload:

```bash
sudo sshd -t
sudo systemctl reload ssh
```

## 5. Write the SSH config (host)

Quadlet:

```bash
install -d -m 700 runtime/hermes-home/home/.ssh
cat > runtime/hermes-home/home/.ssh/config <<'EOF'
Host <machine>
	Hostname <machine>.<tailnet>.ts.net
	User chromecdp
	IdentityFile /opt/data/home/.ssh/chromecdp_ed25519
	SessionType none
	ExitOnForwardFailure yes
	ConnectTimeout 5
	LocalForward 9222 127.0.0.1:9222
EOF
chmod 600 runtime/hermes-home/home/.ssh/config
```

Compose uses the repo-root `ssh_config` instead (same content), then:

```bash
sudo chown root:root ssh_config
sudo chmod 600 ssh_config
```

## 6. Start the tunnel (client)

```bash
ssh <machine>
```

Add firewall rules for SSH on the host if needed.

## 7. Run the browser (host)

```bash
./scripts/brave.sh
```

The profile is kept at `Browser-Profile/` in the repo root (git-ignored), so logins survive
restarts.
