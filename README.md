# AI Client Proxy

`ai-client-proxy` installs a private HTTP/SOCKS5 proxy on Ubuntu 22.04 or 24.04. The proxy listens only on the VPS loopback interface and is reached from the client through an SSH local forward. The proxy port is never exposed publicly.

## Requirements

- A VPS running Ubuntu 22.04 or 24.04.
- SSH key access to a root or sudo-capable account on the VPS.
- An SSH port reachable from the client.

The installer creates a non-root SSH user for the tunnel. It copies the valid public keys already present in the administrative account's `authorized_keys` file. The same public key can be authorized for both the administrative account and the tunnel user; the private key remains only on the client.

## Install

Connect to the VPS with your existing SSH key. Download a specific release, verify its published SHA-256 checksum, then run it:

```bash
curl -fL -o setup-ai-client-proxy.sh \
  https://raw.githubusercontent.com/ORG/ai-client-proxy/v1.0.0/setup-ai-client-proxy.sh

sha256sum setup-ai-client-proxy.sh
sudo bash setup-ai-client-proxy.sh --ssh-user ai-proxy
```

For a direct root login, the installer copies keys from `/root/.ssh/authorized_keys`. When invoked with `sudo`, it copies keys from the invoking user's `~/.ssh/authorized_keys`.

The first run prints a generated 64-character proxy password. Store it in a password manager. It is saved on the VPS at `/etc/ai-client-proxy/credentials`, owned by root with mode `0600`.

### Options

```text
--ssh-user NAME       SSH user to create and HTTP/SOCKS proxy login.
--ssh-port PORT       SSH daemon port to allow through UFW (default: 22).
--proxy-port PORT     Local sing-box proxy port (default: 1080).
--rotate-password     Generate and apply a new proxy password.
--skip-firewall       Do not alter UFW rules.
--print-password      Print the saved password on an interactive repeat run.
```

The installer does not enable UFW if it is inactive. Unless `--skip-firewall` is used, it adds an allow rule for the SSH port and never adds one for the proxy port.

## Client Tunnel

Add this to `~/.ssh/config` on the client, substituting the server address and your existing private-key filename:

```sshconfig
Host ai-client-proxy
    HostName SERVER_IP
    User ai-proxy
    IdentityFile ~/.ssh/YOUR_PRIVATE_KEY
    IdentitiesOnly yes
    LocalForward 127.0.0.1:1080 127.0.0.1:1080
    ExitOnForwardFailure yes
    ServerAliveInterval 30
    ServerAliveCountMax 10
    TCPKeepAlive yes
```

Start the tunnel in a terminal and leave it running:

```bash
ssh -N ai-client-proxy
```

Verify the proxy, replacing `PASSWORD` with the generated value:

```bash
curl --proxy 'http://ai-proxy:PASSWORD@127.0.0.1:1080' https://api.ipify.org
```

Use the resulting local HTTP proxy address and credentials in the client application. SOCKS5 is also available on the same local port.

## Re-run And Rotate

A normal re-run preserves the proxy password and existing tunnel access. It adds any administrative keys missing from the tunnel user's `authorized_keys`, restores the service, and revalidates the loopback listener.

```bash
sudo bash setup-ai-client-proxy.sh --ssh-user ai-proxy
```

Rotate the proxy password explicitly:

```bash
sudo bash setup-ai-client-proxy.sh \
  --ssh-user ai-proxy \
  --rotate-password
```

The new password is printed after successful rotation. Existing client proxy configuration must be updated.

## Operations And Troubleshooting

Check the sing-box service and its log:

```bash
sudo systemctl status sing-box
sudo journalctl -u sing-box -e
```

Confirm the proxy has no public listener:

```bash
sudo ss -lntp 'sport = :1080'
```

The listener must be `127.0.0.1:1080`, never `0.0.0.0:1080` or `[::]:1080`.

If the tunnel cannot connect, first verify that the configured SSH port is reachable and that the client uses the same private key whose public key is in the administrative account's `authorized_keys` when the installer ran.

## Uninstall

This removes the proxy service, configuration, credentials, repository, and tunnel user. It intentionally does not remove UFW rules or unrelated packages.

```bash
sudo systemctl disable --now sing-box
sudo apt-get remove --purge sing-box
sudo rm -f /etc/sing-box/config.json \
  /etc/apt/sources.list.d/sing-box.list \
  /usr/share/keyrings/sing-box.gpg
sudo rm -rf /etc/ai-client-proxy
sudo userdel --remove ai-proxy
```
