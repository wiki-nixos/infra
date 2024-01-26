{ config, lib, pkgs, ...}:

{
  services.nginx = {
    enable = true;
    enableReload = true;

    recommendedBrotliSettings = true;
    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;
    recommendedZstdSettings = true;

    proxyTimeout = "900s";

    virtualHosts."hydra.nixos.org" = {
      forceSSL = true;
      enableACME = true;

      extraConfig = ''
        error_page 503 /503.html;
        location = /503.html {
          root ${./nginx-error-pages};
          internal;
        }
      '';

      locations."/" = {
        proxyPass = "http://127.0.0.1:3000";
      };

      locations."/static/" = {
        alias = "${config.services.hydra-dev.package}/libexec/hydra/root/static/";
      };

      locations."=/favicon.ico" = {
        alias = ./hydra-favicon.png;
      };
    };
  };

}
