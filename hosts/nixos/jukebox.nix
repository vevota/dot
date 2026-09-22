# jukebox.nix — shared Spotify account ("jukebox") -> Icecast -> browser listeners.
# Pipeline: librespot (pulseaudio backend) -> PipeWire null sink "jukebox"
#           -> ffmpeg capture+MP3 -> Icecast (127.0.0.1:8000) -> nginx /stream
{ config, pkgs, lib, ... }:

let
  stateDir = "/var/lib/brick-listen";
  sourcePass = "jukebox_local_9f3a2c";
  adminPass = "jukebox_admin_7b1d4e";

  icecastXml = pkgs.writeText "icecast-jukebox.xml" ''
    <?xml version="1.0"?>
    <icecast>
      <hostname>listen.brick.gay</hostname>
      <location>Brick Listen</location>
      <admin>admin@brick.gay</admin>
      <limits>
        <clients>200</clients>
        <sources>2</sources>
        <queue-size>524288</queue-size>
        <client-timeout>30</client-timeout>
        <header-timeout>15</header-timeout>
        <source-timeout>10</source-timeout>
        <burst-on-connect>1</burst-on-connect>
        <burst-size>65535</burst-size>
      </limits>
      <authentication>
        <source-password>${sourcePass}</source-password>
        <relay-password>${sourcePass}</relay-password>
        <admin-user>admin</admin-user>
        <admin-password>${adminPass}</admin-password>
      </authentication>
      <listen-socket>
        <port>8000</port>
        <bind-address>127.0.0.1</bind-address>
      </listen-socket>
      <http-headers>
        <header name="Access-Control-Allow-Origin" value="*" />
      </http-headers>
      <paths>
        <logdir>/var/log/icecast</logdir>
        <webroot>${pkgs.icecast}/share/icecast/web</webroot>
        <adminroot>${pkgs.icecast}/share/icecast/admin</adminroot>
      </paths>
      <logging>
        <accesslog>access.log</accesslog>
        <errorlog>error.log</errorlog>
        <loglevel>3</loglevel>
        <logsize>10000</logsize>
      </logging>
      <security>
        <chroot>0</chroot>
      </security>
    </icecast>
  '';

  # WebRTC gateway. ffmpeg publishes Opus over RTSP; MediaMTX fans it out as
  # WebRTC (WHEP) for near-real-time, tightly-synced playback.
  mediamtxCfg = pkgs.writeText "mediamtx.yml" ''
    logLevel: info
    rtsp: yes
    rtspAddress: 127.0.0.1:8554
    rtmp: no
    hls: no
    webrtc: yes
    webrtcAddress: 127.0.0.1:8889
    webrtcLocalUDPAddress: :8189
    webrtcAdditionalHosts: [ test.brick.gay, listen.brick.gay, 192.168.7.102 ]
    srt: no
    paths:
      jukebox:
        source: publisher
      jukebox-yt:
        source: publisher
  '';

  bridge = pkgs.writeShellScript "jukebox-bridge.sh" ''
    exec ${pkgs.ffmpeg}/bin/ffmpeg -hide_banner -loglevel warning \
      -f pulse -i jukebox.monitor \
      -ac 2 -ar 48000 -c:a libopus -b:a 128k -application lowdelay \
      -f rtsp -rtsp_transport tcp \
      rtsp://127.0.0.1:8554/jukebox
  '';

  # MP3-over-HTTP fallback for browsers without WebRTC.
  bridgeMp3 = pkgs.writeShellScript "jukebox-bridge-mp3.sh" ''
    exec ${pkgs.ffmpeg}/bin/ffmpeg -hide_banner -loglevel warning \
      -f pulse -i jukebox.monitor \
      -ac 2 -ar 48000 -c:a libmp3lame -b:a 192k \
      -content_type audio/mpeg -f mp3 \
      icecast://source:${sourcePass}@127.0.0.1:8000/jukebox.mp3
  '';

  # --- YouTube central player (fully separate from the Spotify jukebox) ---
  # Headless mpv + yt-dlp plays YouTube audio into its own "jukebox-yt" sink,
  # captured by its own bridges and republished on /stream-yt. Nothing here
  # touches the Spotify sink, Soloist, or /stream.
  ytXvfb = pkgs.writeShellScript "jukebox-yt-xvfb.sh" ''
    exec ${pkgs.xvfb}/bin/Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp
  '';

  # mpv renders video to the virtual display (Xvfb :99); audio goes to the
  # jukebox-yt sink as before. Best source up to 1080p.
  ytMpvRun = pkgs.writeShellScript "jukebox-yt-mpv.sh" ''
    exec ${pkgs.mpv}/bin/mpv \
      --no-config --idle=yes --keep-open=no \
      --vo=x11 --geometry=1920x1080+0+0 --no-osc --no-border --no-input-default-bindings \
      --ao=pulse --audio-device=pulse/jukebox-yt \
      --input-ipc-server=/var/lib/brick-listen/jukebox-yt.sock \
      --ytdl-format='bestvideo[height<=1080]+bestaudio/best[height<=1080]' \
      --ytdl-raw-options=extractor-args=youtube:player_client=web_embedded \
      --msg-level=all=warn
  '';

  # Capture the virtual display (mpv's video) plus the jukebox-yt audio monitor
  # and publish H.264 + Opus over RTSP for MediaMTX/WebRTC.
  bridgeYt = pkgs.writeShellScript "jukebox-yt-bridge.sh" ''
    exec ${pkgs.ffmpeg-full}/bin/ffmpeg -hide_banner -loglevel warning \
      -f x11grab -draw_mouse 0 -video_size 1920x1080 -framerate 30 -i :99.0 \
      -f pulse -i jukebox-yt.monitor \
      -map 0:v -map 1:a \
      -c:v libx264 -preset superfast -tune zerolatency -pix_fmt yuv420p \
      -g 60 -keyint_min 60 -sc_threshold 0 -crf 23 -maxrate 6M -bufsize 12M \
      -c:a libopus -b:a 128k -application lowdelay \
      -f rtsp -rtsp_transport tcp \
      rtsp://127.0.0.1:8554/jukebox-yt
  '';

  bridgeYtMp3 = pkgs.writeShellScript "jukebox-yt-bridge-mp3.sh" ''
    exec ${pkgs.ffmpeg}/bin/ffmpeg -hide_banner -loglevel warning \
      -f pulse -i jukebox-yt.monitor \
      -ac 2 -ar 48000 -c:a libmp3lame -b:a 192k \
      -content_type audio/mpeg -f mp3 \
      icecast://source:${sourcePass}@127.0.0.1:8000/jukebox-yt.mp3
  '';

  # Fetch/refresh the Spotify Soloist binary. Vendor builds expire ~90 days
  # after their build date, so pull the latest from the stable URL and restart
  # the daemon when it changes.
  soloistFetch = pkgs.writeShellScript "soloist-fetch.sh" ''
    export PATH="${lib.makeBinPath [ pkgs.curl pkgs.gnutar pkgs.coreutils pkgs.systemd pkgs.bash ]}:$PATH"
    set -euo pipefail
    dir=/var/lib/brick-listen/soloist-bin
    mkdir -p "$dir"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL -o "$tmp/soloist.tar.gz" https://soloist-builds.spotifycdn.com/soloist_release_x86_64.tar.gz
    tar -xzf "$tmp/soloist.tar.gz" -C "$tmp" soloist
    chmod 755 "$tmp/soloist"
    "$tmp/soloist" --version
    if [ -x "$dir/soloist" ] && cmp -s "$tmp/soloist" "$dir/soloist"; then
      echo "soloist unchanged"
      exit 0
    fi
    install -m 755 "$tmp/soloist" "$dir/soloist.new"
    mv -f "$dir/soloist.new" "$dir/soloist"
    echo "soloist updated"
    if systemctl --user is-active --quiet soloist.service 2>/dev/null; then
      systemctl --user restart soloist.service
    fi
  '';

  # Wrapper so the API key stays in the env file, never in the unit.
  soloistRun = pkgs.writeShellScript "soloist-run.sh" ''
    set -euo pipefail
    set -a
    . /var/lib/brick-listen/soloist.env
    set +a
    exec /var/lib/brick-listen/soloist-bin/soloist \
      --device-name brick-jukebox \
      --api-key "$SOLOIST_API_KEY" \
      --pipewire-device jukebox \
      --data-dir /var/lib/brick-listen/soloist \
      --cache-dir /var/lib/brick-listen/soloist-cache \
      --ws 127.0.0.1:9090
  '';

  # Create the persistent PipeWire null sink Soloist plays into.
  jukeboxSink = pkgs.writeShellScript "jukebox-sink.sh" ''
    exec ${pkgs.pipewire}/bin/pw-cli create-node adapter '{ factory.name=support.null-audio-sink node.name=jukebox node.description="Jukebox Sink" media.class=Audio/Sink object.linger=true audio.position=[FL FR] }'
  '';
in
{
  # --- PipeWire + a virtual "jukebox" sink that librespot plays into ---
  services.pipewire = {
    enable = true;
    # Soloist (and libpipewire clients) look for client.conf in standard
    # locations; NixOS only ships the .conf.d drop-ins, so provide it.
    configPackages = [
      (pkgs.writeTextDir "share/pipewire/client.conf" (builtins.readFile "${pkgs.pipewire}/share/pipewire/client.conf"))
    ];
    pulse.enable = true;
    alsa.enable = false;
    jack.enable = false;
    extraConfig.pipewire."50-jukebox" = {
      context.objects = [
        {
          factory = "adapter";
          args = {
            "factory.name" = "support.null-audio-sink";
            "node.name" = "jukebox";
            "node.description" = "Jukebox Sink";
            "media.class" = "Audio/Sink";
            "object.linger" = true;
            "audio.position" = [ "FL" "FR" ];
          };
        }
        {
          factory = "adapter";
          args = {
            "factory.name" = "support.null-audio-sink";
            "node.name" = "jukebox-yt";
            "node.description" = "Jukebox YouTube Sink";
            "media.class" = "Audio/Sink";
            "object.linger" = true;
            "audio.position" = [ "FL" "FR" ];
          };
        }
      ];
    };
  };

  # let the audio user services run without an interactive login
  users.users.mrmusic.linger = true;

  # --- Icecast (localhost only) ---
  users.groups.icecast = { };
  users.users.icecast = { isSystemUser = true; group = "icecast"; };
  systemd.services.icecast-jukebox = {
    description = "Icecast for the Spotify jukebox stream";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.icecast}/bin/icecast -c ${icecastXml}";
      User = "icecast";
      Group = "icecast";
      Restart = "always";
      RestartSec = "3";
      LogsDirectory = "icecast";
    };
  };

  # --- ffmpeg bridge: capture the jukebox monitor -> MP3 -> Icecast ---
  systemd.services.mediamtx = {
    description = "MediaMTX WebRTC gateway for the jukebox";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.mediamtx}/bin/mediamtx ${mediamtxCfg}";
      Restart = "always";
      RestartSec = "3";
    };
  };

  systemd.user.services.jukebox-bridge = {
    description = "Jukebox PipeWire -> Icecast bridge";
    after = [ "pipewire-pulse.service" ];
    wants = [ "pipewire-pulse.service" ];
    partOf = [ "pipewire-pulse.service" ];
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Restart = "always";
      RestartSec = "3";
      ExecStart = bridge;
    };
  };

  # --- Spotify Soloist (official headless Connect client) ---
  systemd.user.services.jukebox-bridge-mp3 = {
    description = "Jukebox PipeWire -> Icecast MP3 fallback bridge";
    after = [ "pipewire-pulse.service" ];
    wants = [ "pipewire-pulse.service" ];
    partOf = [ "pipewire-pulse.service" ];
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Restart = "always";
      RestartSec = "3";
      ExecStart = bridgeMp3;
    };
  };

  systemd.user.services.jukebox-yt-xvfb = {
    description = "Virtual X display for the jukebox-yt video player";
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Restart = "always";
      RestartSec = "3";
      ExecStart = ytXvfb;
    };
  };

  systemd.user.services.jukebox-yt-mpv = {
    description = "Headless YouTube player for the jukebox-yt stream";
    after = [ "pipewire-pulse.service" "jukebox-yt-xvfb.service" ];
    wants = [ "pipewire-pulse.service" "jukebox-yt-xvfb.service" ];
    partOf = [ "pipewire-pulse.service" ];
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Restart = "always";
      RestartSec = "3";
      Environment = [ "DISPLAY=:99" "PATH=${lib.makeBinPath [ pkgs.yt-dlp pkgs.ffmpeg pkgs.coreutils ]}" ];
      ExecStartPre = "${pkgs.coreutils}/bin/rm -f /var/lib/brick-listen/jukebox-yt.sock";
      ExecStart = ytMpvRun;
    };
  };

  systemd.user.services.jukebox-yt-bridge = {
    description = "Jukebox-yt PipeWire -> MediaMTX bridge";
    after = [ "pipewire-pulse.service" "jukebox-yt-xvfb.service" ];
    wants = [ "pipewire-pulse.service" "jukebox-yt-xvfb.service" ];
    partOf = [ "pipewire-pulse.service" ];
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Restart = "always";
      RestartSec = "3";
      Environment = [ "DISPLAY=:99" ];
      ExecStart = bridgeYt;
    };
  };

  systemd.user.services.jukebox-yt-bridge-mp3 = {
    description = "Jukebox-yt PipeWire -> Icecast MP3 fallback bridge";
    after = [ "pipewire-pulse.service" ];
    wants = [ "pipewire-pulse.service" ];
    partOf = [ "pipewire-pulse.service" ];
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Restart = "always";
      RestartSec = "3";
      ExecStart = bridgeYtMp3;
    };
  };

  systemd.user.services.soloist-fetch = {
    description = "Fetch/refresh the Spotify Soloist binary";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = soloistFetch;
      Path = [ pkgs.curl pkgs.gnutar pkgs.coreutils pkgs.systemd pkgs.bash ];
    };
  };

  systemd.user.timers.soloist-fetch = {
    description = "Weekly refresh of the Spotify Soloist binary";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "weekly"; Persistent = true; };
  };

  systemd.user.services.jukebox-sink = {
    description = "Create the PipeWire jukebox null sink";
    after = [ "pipewire.service" ];
    wants = [ "pipewire.service" ];
    partOf = [ "pipewire.service" ];
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = jukeboxSink;
    };
  };

  systemd.user.services.soloist = {
    description = "Spotify Soloist jukebox (Spotify Connect device)";
    after = [ "pipewire-pulse.service" ];
    wants = [ "pipewire-pulse.service" ];
    partOf = [ "pipewire-pulse.service" ];
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Restart = "always";
      RestartSec = "5";
      # Soloist dlopens libpipewire at runtime; make it discoverable.
      Environment = [ "LD_LIBRARY_PATH=${lib.makeLibraryPath [ pkgs.pipewire ]}" ];
      ExecStartPre = "${pkgs.bash}/bin/bash -c 'test -x /var/lib/brick-listen/soloist-bin/soloist || ${soloistFetch}'";
      ExecStart = soloistRun;
    };
  };

  # --- expose the stream through the existing site vhost ---
  services.nginx.virtualHosts."listen.brick.gay".locations."= /stream/whep" = {
    proxyPass = "http://127.0.0.1:8889/jukebox/whep";
    extraConfig = ''
      proxy_http_version 1.1;
      add_header Cache-Control no-cache;
    '';
  };

  services.nginx.virtualHosts."listen.brick.gay".locations."= /stream.mp3" = {
    proxyPass = "http://127.0.0.1:8000/jukebox.mp3";
    extraConfig = ''
      proxy_buffering off;
      add_header Cache-Control no-cache;
    '';
  };

  # --- test site: testing67 branch on port 3071 (shares the jukebox stream) ---
  systemd.services.brick-listen-test = {
    description = "brick-listen test site (testing67 branch)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "simple";
      User = "mrmusic";
      Group = "users";
      WorkingDirectory = "/home/mrmusic/brick-listen";
      ExecStart = "${pkgs.nodejs_22}/bin/node /home/mrmusic/brick-listen/node_modules/.bin/tsx server.ts";
      EnvironmentFile = "/home/mrmusic/brick-listen-test.env";
      Restart = "always";
      RestartSec = "4";
      NoNewPrivileges = true;
      ProtectSystem = "full";
      PrivateTmp = true;
      ReadWritePaths = [ stateDir "/home/mrmusic/brick-listen" ];
    };
  };

  services.nginx.virtualHosts."test.brick.gay" = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:3071";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
      '';
    };
    locations."= /stream/whep" = {
      proxyPass = "http://127.0.0.1:8889/jukebox/whep";
      extraConfig = ''
        proxy_http_version 1.1;
        add_header Cache-Control no-cache;
      '';
    };

    locations."= /stream.mp3" = {
      proxyPass = "http://127.0.0.1:8000/jukebox.mp3";
      extraConfig = ''
        proxy_buffering off;
        add_header Cache-Control no-cache;
      '';
    };

    # YouTube central player stream (test only for now; inert until driven).
    locations."= /stream-yt/whep" = {
      proxyPass = "http://127.0.0.1:8889/jukebox-yt/whep";
      extraConfig = ''
        proxy_http_version 1.1;
        add_header Cache-Control no-cache;
      '';
    };
    locations."= /stream-yt.mp3" = {
      proxyPass = "http://127.0.0.1:8000/jukebox-yt.mp3";
      extraConfig = ''
        proxy_buffering off;
        add_header Cache-Control no-cache;
      '';
    };
  };
}
