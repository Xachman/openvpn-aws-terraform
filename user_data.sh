#!/bin/bash
set -e

echo install deps
# Update and install OpenVPN + iptables services
dnf update -y
dnf install -y openvpn iptables-services tar wget unzip

echo Installing easy-rsa
# Install Easy-RSA manually
EASYRSA_VERSION="3.1.7"
EASYRSA_DIR="/etc/openvpn/easy-rsa"
mkdir -p $EASYRSA_DIR
wget -q https://github.com/OpenVPN/easy-rsa/releases/download/v$${EASYRSA_VERSION}/EasyRSA-$${EASYRSA_VERSION}.tgz
tar xzf EasyRSA-$${EASYRSA_VERSION}.tgz -C /etc/openvpn
mv /etc/openvpn/EasyRSA-$${EASYRSA_VERSION}/* $EASYRSA_DIR
chmod +x $EASYRSA_DIR/easyrsa

echo Initialize easy-rsa
# Initialize PKI
cd $EASYRSA_DIR
./easyrsa init-pki
echo -ne '\n' | ./easyrsa build-ca nopass
./easyrsa gen-dh
./easyrsa --batch build-server-full server nopass
./easyrsa gen-crl

# Copy server keys
cp pki/ca.crt pki/private/server.key pki/issued/server.crt pki/dh.pem /etc/openvpn/

# Create server config
cat > /etc/openvpn/server.conf <<EOF
port 1194
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
$(for route in ${routes}; do echo "push \"route $${route}\""; done)
keepalive 10 120
cipher AES-256-CBC
persist-key
persist-tun
status openvpn-status.log
verb 3
EOF

# Enable IP forwarding
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-sysctl.conf
sysctl -p /etc/sysctl.d/99-sysctl.conf

# Enable NAT for VPN clients
ETH_IF=$(ip route get 8.8.8.8 | awk '{print $5; exit}')
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o $ETH_IF -j MASQUERADE
service iptables save

# Enable and start OpenVPN
systemctl enable openvpn-server@server
systemctl start openvpn-server@server
