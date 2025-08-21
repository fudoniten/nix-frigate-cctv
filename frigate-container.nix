{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.services.frigateContainer;

  makeEnvFile = envVars:
    let
      envLines =
        mapAttrsToList (var: val: ''${var}="${toString val}"'') envVars;
    in pkgs.writeText "envFile" (concatStringsSep "\n" envLines);

  hostSecrets = config.fudo.secrets.host-secrets."${config.instance.hostname}";

  removeNewline = removeSuffix "\n";

  flatMapAttrs' = f: attrs: listToAttrs (mapConcat f attrs);

  frigateCfg = let
    content = builtins.toJSON {
      mqtt = {
        enabled = true;
        inherit (cfg.mqtt) host port user;
        password = "{FRIGATE_MQTT_PASSWORD}";
      };
      logger.default = cfg.log-level;
      ffmpeg.hwaccel_args = optional (cfg.hwaccel != null) cfg.hwaccel;
      cameras = mapAttrs' (_: camOpts:
        nameValuePair camOpts.name {
          birdseye.mode = if camOpts.default then "continuous" else "objects";
          ffmpeg.inputs = [{
            path = camOpts.streams.high;
            roles = [ "record" "detect" ];
          }];
        }) cfg.cameras;
      go2rtc.streams = mapAttrs'
        (_: camOpts: nameValuePair camOpts.name [ camOpts.streams.high ])
        cfg.cameras;
      inherit (cfg) detectors;
      record = {
        enabled = true;
        retain = {
          days = cfg.retention.default;
          mode = "motion";
        };
        detections.retain = {
          mode = "motion";
          days = cfg.retention.detections;
        };
        alerts.retain = {
          mode = "motion";
          days = cfg.retention.alerts;
        };
      };
      birdseye = {
        enabled = true;
        mode = "continuous";
      };
    };
  in pkgs.writeText "frigate.yaml" content;

in {
  options.services.frigateContainer = with types; {
    enable = mkEnableOption "Enable Frigate CCTV in a container.";

    state-directory = mkOption {
      type = str;
      description = "Path at which to store Frigate recordings & data.";
    };

    log-level = mkOption {
      type = str;
      description = "Level at which to output Frigate logs.";
      default = "error";
    };

    images = {
      frigate = mkOption {
        type = str;
        description = "Frigate Docker image to run.";
      };
    };

    hwaccel = mkOption {
      type = nullOr str;
      description = "Hardware acceleration driver.";
      default = "auto";
    };

    retention = {
      default = mkOption {
        type = int;
        description = "Retention time for all motion, in days.";
        default = 1;
      };

      detections = mkOption {
        type = int;
        description = "Retention time for all detected objects, in days.";
        default = 7;
      };

      alerts = mkOption {
        type = int;
        description = "Retention time for all detected objects, in days.";
        default = 7;
      };
    };

    ports = {
      frigate = mkOption {
        type = port;
        description = "Port on which to listen for Frigate web traffic.";
        default = 5000;
      };

      rtsp = mkOption {
        type = port;
        description = "Port on which to listen for Frigate RTSP traffic.";
        default = 8554;
      };

      webrtc = mkOption {
        type = port;
        description = "Port on which to listen for Frigate WebRTC traffic.";
        default = 8555;
      };
    };

    devices = mkOption {
      type = listOf str;
      description = "List of devices to pass to the container (for hw accel).";
      default = [ ];
    };

    camera-password-file = mkOption {
      type = str;
      description =
        "Path on build host to file containing the camera password.";
    };

    detectors = mkOption {
      type = attrsOf (attrsOf str);
      default = { };
    };

    cameras = let
      cameraOpts = { name, ... }: {
        options = {
          name = mkOption {
            type = str;
            description = "Camera name.";
            default = name;
          };

          default = mkEnableOption "Make camera the primary birds-eye view.";

          streams = {
            low = mkOption {
              type = str;
              description = "URL of the low-quality stream.";
            };
            high = mkOption {
              type = str;
              description = "URL of the high-quality stream.";
            };
          };
        };
      };
    in mkOption {
      type = attrsOf (submodule cameraOpts);
      description = "Cameras for Frigate CCTV to use.";
      default = { };
    };

    mqtt = {
      host = mkOption {
        type = str;
        description = "Hostname of the MQTT server.";
      };

      port = mkOption {
        type = port;
        description = "Port on which to contact the MQTT server.";
      };

      user = mkOption {
        type = str;
        description = "User as which to connect to server.";
      };

      password-file = mkOption {
        type = str;
        description =
          "File containing password with which to authenticate to MQTT server.";
      };
    };
  };

  config = mkIf cfg.enable {
    fudo.secrets.host-secrets."${config.instance.hostname}" = {
      frigateEnv = {
        source-file = let
          camPasswd = removeNewline (readFile cfg.camera-password-file);
          mqttPasswd = removeNewline (readFile cfg.mqtt.password-file);
        in makeEnvFile {
          FRIGATE_RTSP_PASSWORD = camPasswd;
          FRIGATE_MQTT_PASSWORD = mqttPasswd;
        };
        target-file = "/run/frigate/camera.passwd";
      };
    };

    virtualisation.arion.projects.frigate.settings = let
      image = { pkgs, ... }: {
        project.name = "frigate-cctv";
        services = {
          frigate.service = {
            image = cfg.images.frigate;
            hostname = "frigate";
            restart = "always";
            volumes = [
              "${frigateCfg}:/config/config.yml"
              "${cfg.state-directory}:/media/frigate"
            ];
            # shm_size = cfg.shm-size;
            inherit (cfg) devices;
            ports = [
              "${toString cfg.ports.frigate}:5000"
              "${toString cfg.ports.rtsp}:8554"
              "${toString cfg.ports.webrtc}:8555/tcp"
              "${toString cfg.ports.webrtc}:8555/udp"
            ];
            env_file = [ hostSecrets.frigateEnv.target-file ];
          };
          # TODO: add metrics exporter
        };

        docker-compose.raw.services.frigate = {
          shm_size =
            let memsize = toString (512 * (length (attrNames cfg.cameras)));
            in "${memsize}m";
        };
      };
    in { imports = [ image ]; };
  };
}
