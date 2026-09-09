# brick-listen — synchronized listen-along rooms at listen.brick.gay
# App source lives in /home/mrmusic/brick-listen (own git repo, NOT in dot).
{ config, pkgs, lib, ... }:

let
  appDir = "/home/mrmusic/brick-listen";
  stateDir = "/var/lib/brick-listen";
in
{
  # node for building + running the app
  environment.systemPackages = [ pkgs.nodejs_20 ];

  systemd.tmpfiles.settings.brickListen."${stateDir}" = {
    d = { mode = "0750"; user = "mrmusic"; group = "users"; };
  };

  systemd.services.brick-listen = {
    description = "brick-listen synced listening rooms";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "simple";
      User = "mrmusic";
      Group = "users";
      WorkingDirectory = appDir;
      ExecStart = "${pkgs.nodejs_20}/bin/node ${appDir}/node_modules/.bin/tsx server.ts";
      Restart = "always";
      RestartSec = "4";
      EnvironmentFile = lib.mkIf (lib.pathExists "${stateDir}/env") "${stateDir}/env";
      NoNewPrivileges = true;
      ProtectSystem = "full";
      PrivateTmp = true;
      ReadWritePaths = [ stateDir appDir ];
    };
  };

  services.nginx.virtualHosts."listen.brick.gay" = {
    enableACME = true;
    forceSSL = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:3070";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        client_max_body_size 4m;
      '';
    };
  };
}
