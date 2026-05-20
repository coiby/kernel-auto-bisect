#!/bin/bash
set -x

# TMT_TREE should be the root of the project
echo "TMT_TREE: $TMT_TREE"
ls -l "$TMT_TREE/tests/ssh_keys/"

# Fix private key permissions on all guests (needed for client)
PRIVATE_KEY="$TMT_TREE/tests/ssh_keys/id_ecdsa"
if [ -f "$PRIVATE_KEY" ]; then
    chmod 600 "$PRIVATE_KEY"
else
    echo "Warning: Private key not found at $PRIVATE_KEY"
fi

# Set up authorized_keys on all guests (needed for server)
mkdir -p /root/.ssh
chmod 700 /root/.ssh

PUB_KEY="$TMT_TREE/tests/ssh_keys/id_ecdsa.pub"
if [ -f "$PUB_KEY" ]; then
    # Ensure newline before appending if file exists
    if [ -s /root/.ssh/authorized_keys ]; then
        sed -i '$a\' /root/.ssh/authorized_keys
    fi
    
    # Check if key already exists to avoid duplicates
    if ! grep -qf "$PUB_KEY" /root/.ssh/authorized_keys 2>/dev/null; then
        cat "$PUB_KEY" >>/root/.ssh/authorized_keys
        echo "Added public key to authorized_keys"
    else
        echo "Public key already in authorized_keys"
    fi
else
    echo "Error: Public key not found at $PUB_KEY"
    exit 1
fi

chmod 600 /root/.ssh/authorized_keys

# SELinux restorecon
if command -v restorecon >/dev/null 2>&1; then
    restorecon -Rv /root/.ssh
fi

# Open firewall for SSH if firewalld is running
if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --add-service=ssh --permanent || true
    firewall-cmd --reload || true
    firewall-cmd --add-service=ssh || true
fi

# Also try to stop firewalld entirely for testing
systemctl stop firewalld || true
iptables -F || true

# Network diagnostics
echo "Network interfaces:"
ip addr
echo "Routing table:"
ip route
echo "Hosts file:"
cat /etc/hosts
echo "Listening ports:"
ss -tlpn

# Ensure PermitRootLogin is allowed on the server
SSHD_CONFIG="/etc/ssh/sshd_config"
if [ -f "$SSHD_CONFIG" ]; then
    changed=0
    # Use a separate config file in sshd_config.d if supported, it's cleaner
    if [ -d /etc/ssh/sshd_config.d ]; then
        echo "PermitRootLogin yes" > /etc/ssh/sshd_config.d/00-permit-root.conf
        echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config.d/00-permit-root.conf
        changed=1
    else
        # Fallback to editing main config
        if ! grep -q "^PermitRootLogin yes" "$SSHD_CONFIG"; then
            sed -i 's/^[# \t]*PermitRootLogin.*/PermitRootLogin yes/' "$SSHD_CONFIG"
            if ! grep -q "^PermitRootLogin yes" "$SSHD_CONFIG"; then
                echo "PermitRootLogin yes" >> "$SSHD_CONFIG"
            fi
            changed=1
        fi
        if ! grep -q "^PubkeyAuthentication yes" "$SSHD_CONFIG"; then
            sed -i 's/^[# \t]*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"
            if ! grep -q "^PubkeyAuthentication yes" "$SSHD_CONFIG"; then
                echo "PubkeyAuthentication yes" >> "$SSHD_CONFIG"
            fi
            changed=1
        fi
    fi
    
    if [ $changed -eq 1 ]; then
        echo "Restarting sshd..."
        systemctl restart sshd || service sshd restart || true
    fi
fi
