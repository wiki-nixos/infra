{ config, lib, pkgs, inputs, ... }:

let

  inherit (lib) mkDefault mkEnableOption mkForce mkIf mkMerge mkOption mkPackageOption;
  inherit (lib) literalExpression mapAttrs optional optionalString types recursiveUpdate;

  cfg = config.services.limesurvey;
  fpm = config.services.phpfpm.pools.limesurvey;

  user = "limesurvey";
  group = config.services.nginx.group;
  stateDir = "/var/lib/limesurvey";

  configType = with types; oneOf [ (attrsOf configType) str int bool ] // {
    description = "limesurvey config type (str, int, bool or attribute set thereof)";
  };

  limesurveyConfig = pkgs.writeText "config.php" ''
    <?php
      return json_decode('${builtins.toJSON cfg.config}', true);
    ?>
  '';

  mysqlLocal = cfg.database.createLocally && cfg.database.type == "mysql";
  pgsqlLocal = cfg.database.createLocally && cfg.database.type == "pgsql";

in
{
  # interface

  options.services.limesurvey = {
    enable = mkEnableOption "Limesurvey web application";

    package = mkPackageOption pkgs "limesurvey" { };

    encryptionKeyFile = mkOption {
      type = types.str;
      default = "E17687FC77CEE247F0E22BB3ECF27FDE8BEC310A892347EC13013ABA11AA7EB5";
      description = ''
        This is a 32-byte key used to encrypt variables in the database.
        You _must_ change this from the default value.
      '';
    };

    encryptionNonceFile = mkOption {
      type = types.str;
      default = "1ACC8555619929DB91310BE848025A427B0F364A884FFA77";
      description = ''
        This is a 24-byte nonce used to encrypt variables in the database.
        You _must_ change this from the default value.
      '';
    };

    database = {
      type = mkOption {
        type = types.enum [ "mysql" "pgsql" "odbc" "mssql" ];
        example = "pgsql";
        default = "mysql";
        description = "Database engine to use.";
      };

      dbEngine = mkOption {
        type = types.enum [ "MyISAM" "InnoDB" ];
        default = "InnoDB";
        description = "Database storage engine to use.";
      };

      host = mkOption {
        type = types.str;
        default = "localhost";
        description = "Database host address.";
      };

      port = mkOption {
        type = types.port;
        default = if cfg.database.type == "pgsql" then 5442 else 3306;
        defaultText = literalExpression "3306";
        description = "Database host port.";
      };

      name = mkOption {
        type = types.str;
        default = "limesurvey";
        description = "Database name.";
      };

      user = mkOption {
        type = types.str;
        default = "limesurvey";
        description = "Database user.";
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "/run/keys/limesurvey-dbpassword";
        description = ''
          A file containing the password corresponding to
          {option}`database.user`.
        '';
      };

      socket = mkOption {
        type = types.nullOr types.path;
        default =
          if mysqlLocal then "/run/mysqld/mysqld.sock"
          else if pgsqlLocal then "/run/postgresql"
          else null
        ;
        defaultText = literalExpression "/run/mysqld/mysqld.sock";
        description = "Path to the unix socket file to use for authentication.";
      };

      createLocally = mkOption {
        type = types.bool;
        default = cfg.database.type == "mysql";
        defaultText = literalExpression "true";
        description = ''
          Create the database and database user locally.
          This currently only applies if database type "mysql" is selected.
        '';
      };
    };

    virtualHost = mkOption {
      type = types.submodule (
        recursiveUpdate
          (import "${inputs.nixpkgs}/nixos/modules/services/web-servers/nginx/vhost-options.nix" { inherit config lib; })
          { }
      );
      example = literalExpression ''
        {
          serverName = "survey.example.org";
          forceSSL = true;
          enableACME = true;
        }
      '';
      description = ''
        Nginx configuration can be done by adapting `services.nginx.virtualHosts.<name>`.
        See [](#opt-services.nginx.virtualHosts) for further information.
      '';
    };

    poolConfig = mkOption {
      type = with types; attrsOf (oneOf [ str int bool ]);
      default = {
        "pm" = "dynamic";
        "pm.max_children" = 32;
        "pm.start_servers" = 2;
        "pm.min_spare_servers" = 2;
        "pm.max_spare_servers" = 4;
        "pm.max_requests" = 500;
      };
      description = ''
        Options for the LimeSurvey PHP pool. See the documentation on `php-fpm.conf`
        for details on configuration directives.
      '';
    };

    config = mkOption {
      type = configType;
      default = { };
      description = ''
        LimeSurvey configuration. Refer to
        <https://manual.limesurvey.org/Optional_settings>
        for details on supported values.
      '';
    };
  };

  # implementation

  config = mkIf cfg.enable {

    assertions = [
      {
        assertion = cfg.database.createLocally -> cfg.database.type == "mysql";
        message = "services.limesurvey.createLocally is currently only supported for database type 'mysql'";
      }
      {
        assertion = cfg.database.createLocally -> cfg.database.user == user;
        message = "services.limesurvey.database.user must be set to ${user} if services.limesurvey.database.createLocally is set true";
      }
      {
        assertion = cfg.database.createLocally -> cfg.database.socket != null;
        message = "services.limesurvey.database.socket must be set if services.limesurvey.database.createLocally is set to true";
      }
      {
        assertion = cfg.database.createLocally -> cfg.database.passwordFile == null;
        message = "a password cannot be specified if services.limesurvey.database.createLocally is set to true";
      }
    ];

    services.limesurvey.config = mapAttrs (name: mkDefault) {
      runtimePath = "${stateDir}/tmp/runtime";
      components = {
        db = {
          connectionString = "${cfg.database.type}:dbname=${cfg.database.name};host=${if pgsqlLocal then cfg.database.socket else cfg.database.host};port=${toString cfg.database.port}" +
            optionalString mysqlLocal ";socket=${cfg.database.socket}";
          username = cfg.database.user;
          password = mkIf (cfg.database.passwordFile != null) "file_get_contents(\"${toString cfg.database.passwordFile}\");";
          tablePrefix = "limesurvey_";
        };
        assetManager.basePath = "${stateDir}/tmp/assets";
        urlManager = {
          urlFormat = "path";
          showScriptName = false;
        };
      };
      config = {
        tempdir = "${stateDir}/tmp";
        uploaddir = "${stateDir}/upload";
        # TODO: instead load these files from php
        encryptionnonce = cfg.encryptionNonceFile;
        encryptionsecretboxkey = cfg.encryptionKeyFile;
        force_ssl = mkIf (cfg.virtualHost.addSSL || cfg.virtualHost.forceSSL || cfg.virtualHost.onlySSL) "on";
        config.defaultlang = "en";
      };
    };

    services.mysql = mkIf mysqlLocal {
      enable = true;
      package = mkDefault pkgs.mariadb;
      ensureDatabases = [ cfg.database.name ];
      ensureUsers = [
        {
          name = cfg.database.user;
          ensurePermissions = {
            "${cfg.database.name}.*" = "SELECT, CREATE, INSERT, UPDATE, DELETE, ALTER, DROP, INDEX";
          };
        }
      ];
    };

    services.phpfpm.pools.limesurvey = {
      inherit user group;
      phpPackage = pkgs.php81;
      phpEnv.DBENGINE = "${cfg.database.dbEngine}";
      phpEnv.LIMESURVEY_CONFIG = "${limesurveyConfig}";
      settings = {
        "listen.owner" = user;
        "listen.group" = group;
      } // cfg.poolConfig;
    };


    services.nginx = {
      enable = true;
      recommendedGzipSettings = true;
      recommendedOptimisation = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      virtualHosts.${cfg.virtualHost.serverName} = {
        forceSSL = true;
        enableACME = true;
        root = "${cfg.package}/share/limesurvey";
        locations = {
          "/" = {
            index = "index.php";
            tryFiles = "$uri /index.php?$args";
          };

          "~ \.php$".extraConfig = ''
            fastcgi_pass unix:${config.services.phpfpm.pools."limesurvey".socket};
          '';
          "/tmp".root = "/var/lib/limesurvey";
          "/upload/".root = "/var/lib/limesurvey";

        };
      };
    };

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 ${user} ${group} - -"
      "d ${stateDir}/tmp 0750 ${user} ${group} - -"
      "d ${stateDir}/tmp/assets 0750 ${user} ${group} - -"
      "d ${stateDir}/tmp/runtime 0750 ${user} ${group} - -"
      "d ${stateDir}/tmp/upload 0750 ${user} ${group} - -"
      "C ${stateDir}/upload 0750 ${user} ${group} - ${cfg.package}/share/limesurvey/upload"
    ];

    systemd.services.limesurvey-init = {
      wantedBy = [ "multi-user.target" ];
      before = [ "phpfpm-limesurvey.service" ];
      after = optional mysqlLocal "mysql.service" ++ optional pgsqlLocal "postgresql.service";
      environment.DBENGINE = "${cfg.database.dbEngine}";
      environment.LIMESURVEY_CONFIG = limesurveyConfig;
      script = ''
        # update or install the database as required
        ${pkgs.php81}/bin/php ${cfg.package}/share/limesurvey/application/commands/console.php updatedb || \
        ${pkgs.php81}/bin/php ${cfg.package}/share/limesurvey/application/commands/console.php install admin password admin admin@example.com verbose
      '';
      serviceConfig = {
        User = user;
        Group = group;
        Type = "oneshot";
      };
    };

    systemd.services.nginx.after = optional mysqlLocal "mysql.service" ++ optional pgsqlLocal "postgresql.service";

    users.users.${user} = {
      group = group;
      isSystemUser = true;
    };

  };
}

