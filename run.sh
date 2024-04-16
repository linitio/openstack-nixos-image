#!/bin/sh

set -e

if [ -z "$VERSION" ]; then
  echo "Error: VERSION of NixOS is not set !"
  exit 1
fi

echo "---| Building NixOS ($VERSION) |---"

echo "Enables flakes and kvm features"
echo "experimental-features = nix-command flakes" >>/etc/nix/nix.conf
echo "system-features = kvm" >>/etc/nix/nix.conf

# Move inside build dir
cd /app

echo "Generating flake.nix..."
# Replace the value of flake
nix run nixpkgs#gnused -- 's/VERSION/'"$VERSION"'/g' flake.nix.template >flake.nix

echo "Building NixOS Image..."
# Build the NixOS image
nix build .#openstack

echo "Copying output to /app/nixos.qcow2"
cp -Lr result/nixos.qcow2 /app/nixos.qcow2

exit 0
