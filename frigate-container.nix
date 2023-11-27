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

  frigateCfg = toJSON {
    mqtt = {
      enabled = true;
      inherit (cfg.mqtt) host port user;
      password = "{FRIGATE_MQTT_PASSWORD}";
    };
    logger.default = cfg.log-level;
    ffmpeg.hwaccel_args = [ "preset-intel-vaapi" ];
    cameras = mapAttrs' (_: camOpts:
      nameValuePair camOpts.name {
        ffmpeg.inputs = [
          {
            path = camOpts.streams.high;
            roles = [ "record" ];
          }
          {
            path = camOpts.streams.low;
            roles = [ "detect" ];
          }
        ];
      }) cfg.cameras;
    detectors = cfg.detectors;
    record = {
      enabled = true;
      retain = {
        days = cfg.retention.default;
        mode = "motion";
      };
      events.retain = {
        default = cfg.retention.events;
        mode = "active_objects";
        objects = cfg.retention.objects;
      };
    };
  };

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

    retention = {
      default = mkOption {
        type = int;
        description = "Retention time for all motion, in days.";
        default = 7;
      };

      events = mkOption {
        type = int;
        description = "Retention time for all detected objects, in days.";
        default = 14;
      };

      objects = mkOption {
        type = attrsOf int;
        description = "Map of object type to retention time in days.";
        default = {
          person = 60;
          dog = 30;
          cat = 30;
        };
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
      type = attrsOf (attrsOf any);
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
          camPasswd = readFile cfg.camera-password-file;
          mqttPasswd = readFile cfg.mqtt.passwd-file;
        in mkEnvFile {
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
            devices = cfg.devices;
            ports = [
              "${cfg.ports.frigate}:5000"
              "${cfg.ports.rtsp}:8554"
              "${cfg.ports.webrtc}:8555/tcp"
              "${cfg.ports.webrtc}:8555/udp"
            ];
            env_file = hostSecrets.frigateEnv.target-file;
          };
        };
      };
    in { imports = [ image ]; };
  };
}
