# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./music-stack.nix
    ];

  # --- Mount Phantom drive at system path ---
  # --- VirtioFS mount for melody pool ---
  boot.kernelModules = [ "virtiofs" ];

  fileSystems."/mnt/melody" = {
    device = "melodyVirt";
    fsType = "virtiofs";
    options = [ "defaults" ];
  };

  fileSystems."/mnt/Phantom" = {
    device = "192.168.7.100:/mnt/Phantom";
    fsType = "nfs";
    options = [ "vers=4.2" "nofail" "noatime" "hard" "intr" "_netdev" ];
};

# --- NFS share for Phantom drive ---
  services.nfs.server.enable = true;
  services.nfs.server.exports = ''
    /mnt/Phantom 192.168.7.101(fsid=1,rw,sync,no_subtree_check,no_root_squash)
    /mnt/melody/media 192.168.7.0/24(fsid=2,rw,sync,no_subtree_check,no_root_squash)
    '';

# --- deSEC DDNS: keep brick.gay DNS updated when IP changes ---
  systemd.services.desec-ddns = {
    description = "Update deSEC DNS A record for brick.gay";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.curl pkgs.dnsutils ];
    serviceConfig.EnvironmentFile = "/var/lib/music/secrets/desec.env";
    serviceConfig.Type = "oneshot";
    script = ''
      set -euo pipefail
      TOKEN=$DESEC_TOKEN
      API="https://desec.io/api/v1/domains/brick.gay/rrsets"
      IP=$(curl -4sf --connect-timeout 10 ifconfig.me 2>/dev/null || curl -4sf --connect-timeout 10 icanhazip.com 2>/dev/null)
      if [ -z "$IP" ]; then
        echo "ERROR: Could not determine public IP"
        exit 1
      fi
      for SUB in "@" "gateway"; do
        CURRENT=""
        if [ "$SUB" = "gateway" ]; then
          CURRENT=$(dig +short gateway.brick.gay @1.1.1.1 +noall +answer 2>/dev/null || echo "")
        fi
        if [ -z "$CURRENT" ]; then
          CURRENT=$(dig +short brick.gay @1.1.1.1 +noall +answer 2>/dev/null || echo "")
        fi
        if [ "$CURRENT" = "$IP" ]; then
          echo "OK: $SUB.brick.gay already points to $IP, skipping"
          continue
        fi
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PATCH           -H "Authorization: Token $TOKEN"           -H "Content-Type: application/json"           "$API/$SUB/A/"           -d "{\"records\":[\"$IP\"]}")
        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
          echo "OK: $SUB.brick.gay -> $IP (PATCH $HTTP_CODE)"
        else
          curl -sf -X POST             -H "Authorization: Token $TOKEN"             -H "Content-Type: application/json"             "$API/"             -d "{\"subname\":\"$SUB\",\"type\":\"A\",\"ttl\":300,\"records\":[\"$IP\"]}"
          echo "OK: $SUB.brick.gay -> $IP (POST created)"
        fi
      done
    '';
  };
  systemd.timers.desec-ddns = {
    description = "Update brick.gay DNS every 30 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/30";
      Persistent = true;
    };
  };


# Bootloader.
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";
  boot.loader.grub.useOSProber = true;

  networking.hostName = "nixos";
  networking.interfaces.ens18.useDHCP = false;
  networking.interfaces.ens18.ipv4.addresses = [{
    address = "192.168.7.102";
    prefixLength = 24;
  }]; # Define your hostname.
  networking.nameservers = [ "1.1.1.1" "8.8.8.8" ];
  networking.defaultGateway = "192.168.7.1";
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
  networking.networkmanager.enable = true;

  # Enable network manager applet
  #programs.nm-applet.enable = true;

  # Set your time zone.
  time.timeZone = "America/Los_Angeles";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_US.UTF-8";
    LC_IDENTIFICATION = "en_US.UTF-8";
    LC_MEASUREMENT = "en_US.UTF-8";
    LC_MONETARY = "en_US.UTF-8";
    LC_NAME = "en_US.UTF-8";
    LC_NUMERIC = "en_US.UTF-8";
    LC_PAPER = "en_US.UTF-8";
    LC_TELEPHONE = "en_US.UTF-8";
    LC_TIME = "en_US.UTF-8";
  };

  # Enable the X11 windowing system.
  #services.xserver.enable = true;

  # Enable the LXQT Desktop Environment.
  #services.xserver.displayManager.lightdm.enable = true;
  #services.xserver.desktopManager.lxqt.enable = true;

  # Configure keymap in X11
  #services.xserver.xkb = {
  #  layout = "us";
  #  variant = "";
  #};

  # Enable CUPS to print documents.
  #services.printing.enable = true;

  # Enable sound with pipewire.
  #services.pulseaudio.enable = false;
  #security.rtkit.enable = true;
  #services.pipewire = {
  #  enable = true;
  #  alsa.enable = true;
  #  alsa.support32Bit = true;
  #  pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;

    # use the example session manager (no others are packaged yet so this is enabled by default,
    # no need to redefine it in your config for now)
    #media-session.enable = true;
  #};
# 
  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.mrmusic = {
    isNormalUser = true;
    description = "MrMusic";
    extraGroups = [ "networkmanager" "wheel" ];
    packages = with pkgs; [
    #  thunderbird
    ];
  };

  # Install firefox.
  #programs.firefox.enable = true;

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;
  nixpkgs.config.permittedInsecurePackages = [ "python3.13-beets-2.5.1" ];

  nix.gc = {
    automatic = true;
    options = "--delete-older-than 7d";
  };

  services.journald.extraConfig = "SystemMaxUse=500M";
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [ stdenv.cc.cc.lib zlib openssl ];

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    git
    vim
    wget
      micro
    beets
  ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  services.openssh.enable = true;
  systemd.services.dbus-broker.serviceConfig.TimeoutStopSec = 10;

  # Open ports in the firewall.
  networking.firewall.allowedTCPPorts = [ 2049 ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  networking.firewall.enable = false;

  # nh — pretty rebuilds (nix-output-monitor TUI) + auto GC after rebuild
  programs.nh = {
    enable = true;
    # Point at wherever you cloned the dotfiles repo:
    flake = "/home/mrmusic/dot/hosts/nixos";
    clean.enable = true;
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.11"; # Did you read the comment?

}
