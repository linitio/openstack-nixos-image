{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [
    "${toString modulesPath}/profiles/qemu-guest.nix"
    "${toString modulesPath}/profiles/headless.nix"
  ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };

  boot.growPartition = true;
  boot.kernelParams = [ "console=tty1" ];
  boot.loader.grub.device = "/dev/vda";
  boot.loader.timeout = 1;
  boot.loader.grub.extraConfig = ''
    serial --unit=1 --speed=115200 --word=8 --parity=no --stop=1
    terminal_output console serial
    terminal_input console serial
  '';

  # Allow root logins
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "no";
  };

  # Enable the serial console on tty1
  systemd.services."serial-getty@tty1".enable = true;

  # Force getting the hostname from Openstack metadata.
  networking.hostName = "";

  # Nothing can possibly hash to just "!". This way, it disable password.
  users.users.root.hashedPassword = "!";

  # Create a nixos user
  users.users.nixos = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  };

  nix.settings.auto-optimise-store = true;
  security.sudo.wheelNeedsPassword = false;

  # Fetch
  systemd.services.openstack-init = {
    path = [ pkgs.wget ];
    description = "Fetch Openstack Metadata on startup";
    wantedBy = [ "multi-user.target" ];
    before = [ "apply-openstack-data.service" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    script = ''
      metaDir=/etc/openstack-metadata
      mkdir -m 0755 -p "$metaDir"
      rm -f "$metaDir/*"

      echo "getting instance metadata..."

      wget_imds() {
        wget --retry-connrefused "$@"
      }

      wget_imds -O "$metaDir/ami-manifest-path" http://169.254.169.254/1.0/meta-data/ami-manifest-path || true
      # When no user-data is provided, the OpenStack metadata server doesn't expose the user-data route.
      (umask 077 && wget_imds -O "$metaDir/user-data" http://169.254.169.254/1.0/user-data || rm -f "$metaDir/user-data")
      wget_imds -O "$metaDir/hostname" http://169.254.169.254/1.0/meta-data/hostname || true
      wget_imds -O "$metaDir/public-keys-0-openssh-key" http://169.254.169.254/1.0/meta-data/public-keys/0/openssh-key || true
    '';
    restartIfChanged = false;
    unitConfig.X-StopOnRemoval = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
  };

  systemd.services.apply-openstack-data = {
    description = "Apply Openstack Data";
    wantedBy = [ "multi-user.target" "sshd.service" ];
    before = [ "sshd.service" ];
    after = [ "fetch-openstack-metadata.service" ];
    path = [ pkgs.iproute2 ];
    script = ''
      echo "setting host name..."
      if [ -s /etc/openstack-metadata/hostname ]; then
          ${pkgs.nettools}/bin/hostname $(cat /etc/openstack-metadata/hostname)
      fi

      if ! [ -e /home/nixos/.ssh/authorized_keys ]; then
          echo "obtaining SSH key..."
          mkdir -m 0700 -p /home/nixos/.ssh
          if [ -s /etc/openstack-metadata/public-keys-0-openssh-key ]; then
              cat /etc/openstack-metadata/public-keys-0-openssh-key >> /home/nixos/.ssh/authorized_keys
              echo "new key added to authorized_keys"
              chmod 600 /home/nixos/.ssh/authorized_keys
          fi
          chown -R nixos:users /home/nixos/.ssh
      fi

      # Extract the intended SSH host key for this machine from
      # the supplied user data, if available.  Otherwise sshd will
      # generate one normally.
      userData=/etc/openstack-metadata/user-data

      mkdir -m 0755 -p /etc/ssh

      if [ -s "$userData" ]; then
        key="$(sed 's/|/\n/g; s/SSH_HOST_DSA_KEY://; t; d' $userData)"
        key_pub="$(sed 's/SSH_HOST_DSA_KEY_PUB://; t; d' $userData)"
        if [ -n "$key" -a -n "$key_pub" -a ! -e /etc/ssh/ssh_host_dsa_key ]; then
            (umask 077; echo "$key" > /etc/ssh/ssh_host_dsa_key)
            echo "$key_pub" > /etc/ssh/ssh_host_dsa_key.pub
        fi

        key="$(sed 's/|/\n/g; s/SSH_HOST_ED25519_KEY://; t; d' $userData)"
        key_pub="$(sed 's/SSH_HOST_ED25519_KEY_PUB://; t; d' $userData)"
        if [ -n "$key" -a -n "$key_pub" -a ! -e /etc/ssh/ssh_host_ed25519_key ]; then
            (umask 077; echo "$key" > /etc/ssh/ssh_host_ed25519_key)
            echo "$key_pub" > /etc/ssh/ssh_host_ed25519_key.pub
        fi
      fi
    '';

    serviceConfig.Type = "oneshot";
    serviceConfig.RemainAfterExit = true;
  };

  systemd.services.print-host-key = {
    description = "Print SSH Host Key";
    wantedBy = [ "multi-user.target" ];
    after = [ "sshd.service" ];
    script = ''
      # Print the host public key on the console so that the user
      # can obtain it securely by parsing the output
      echo "-----BEGIN SSH HOST KEY FINGERPRINTS-----" > /dev/console
      for i in /etc/ssh/ssh_host_*_key.pub; do
          ${pkgs.openssh}/bin/ssh-keygen -l -f $i > /dev/console
      done
      echo "-----END SSH HOST KEY FINGERPRINTS-----" > /dev/console
    '';
    serviceConfig.Type = "oneshot";
    serviceConfig.RemainAfterExit = true;
  };
}
