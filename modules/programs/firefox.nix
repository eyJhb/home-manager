{ config, lib, pkgs, ... }:

with lib;

let

  inherit (pkgs.stdenv.hostPlatform) isDarwin;

  cfg = config.programs.firefox;

  mozillaConfigPath =
    if isDarwin
    then "Library/Application Support/Mozilla"
    else ".mozilla";

  firefoxConfigPath =
    if isDarwin
    then "Library/Application Support/Firefox"
    else "${mozillaConfigPath}/firefox";

  profilesPath =
    if isDarwin
    then "${firefoxConfigPath}/Profiles"
    else firefoxConfigPath;

  profiles =
    flip mapAttrs' cfg.profiles (_: profile:
      nameValuePair "Profile${toString profile.id}" {
        Name = profile.name;
        Path =
          if isDarwin
          then "Profiles/${profile.path}"
          else profile.path;
        IsRelative = 1;
        Default = if profile.isDefault then 1 else 0;
      }
    ) // {
      General = {
        StartWithLastProfile = 1;
      };
    };

  profilesIni = generators.toINI {} profiles;

  mkUserJs = prefs: extraPrefs: ''
    // Generated by Home Manager.

    ${concatStrings (mapAttrsToList (name: value: ''
      user_pref("${name}", ${builtins.toJSON value});
    '') prefs)}

    ${extraPrefs}
  '';

  # stolen from the nixos znc config module
  # this is fun/needed to do stuff like bookmarks
  # "Bookmarks": [
  #     {
  #       "Title": "Example",
  #       "URL": "https://example.com",
  #       "Favicon": "https://example.com/favicon.ico",
  #       "Placement": "toolbar" | "menu",
  #       "Folder": "FolderName"
  #     }
  #   ]
  # TODO(eyjhb) CHANGE THIS!
  semanticTypes = with types; rec {
    zncAtom = oneOf [ int bool str ];
    zncAll = oneOf [ zncAtom (listOf zncAll) (attrsOf zncAll) ];
    zncConf = attrsOf ( (zncAll)  // {
      # Since this is a recursive type and the description by default contains
      # the description of its subtypes, infinite recursion would occur without
      # explicitly breaking this cycle
      description = "TODO(eyjhb) replace";
    });
  };

  mkExtensions = exts: {
    "ExtensionSettings" = builtins.listToAttrs (forEach exts (x: {
      "name" = builtins.readFile "${x}/name";
      "value" = {
        "installation_mode" = "force_installed";
        "install_url" = "file://${x}/extension.xpi";
      };
    }));
  };

  mkPolicies = cfg: builtins.toJSON ({ "policies" = (cfg.extraPolicies // ( mkExtensions cfg.extensions ) ); });
in

{
  meta.maintainers = [ maintainers.rycee ];

  imports = [
    (mkRemovedOptionModule ["programs" "firefox" "enableAdobeFlash"]
      "Support for this option has been removed.")
    (mkRemovedOptionModule ["programs" "firefox" "enableGoogleTalk"]
      "Support for this option has been removed.")
    (mkRemovedOptionModule ["programs" "firefox" "enableIcedTea"]
      "Support for this option has been removed.")
  ];

  options = {
    programs.firefox = {
      enable = mkEnableOption "Firefox";

      package = mkOption {
        type = types.package;
        default =
          if versionAtLeast config.home.stateVersion "19.09"
          then pkgs.firefox
          else pkgs.firefox-unwrapped;
        defaultText = literalExample "pkgs.firefox";
        example = literalExample ''
          pkgs.firefox.override {
            # See nixpkgs' firefox/wrapper.nix to check which options you can use
            cfg = {
              # Gnome shell native connector
              enableGnomeExtensions = true;
              # Tridactyl native connector
              enableTridactylNative = true;
            };
          }
        '';
        description = ''
          The Firefox package to use. If state version ≥ 19.09 then
          this should be a wrapped Firefox package. For earlier state
          versions it should be an unwrapped Firefox package.
        '';
      };

      individualPolicies = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether or not to use a pr. policies.json approach, which will merge
          the global extensions and extraPolicies into each profile, and allow 
          to customize each profile, using policies with individual extensions, etc.
          This however requires a patched Firefox, which can be fond here:
          https://github.com/NixOS/nixpkgs/pull/94898
        '';
      };

      extensions = mkOption {
        type = types.listOf types.package;
        default = [];
        example = literalExample ''
          with pkgs.nur.repos.rycee.firefox-addons; [
            https-everywhere
            privacy-badger
          ]
        '';
        description = ''
          TODO(eyjhb) not correct anymore, since the new extensions does not function this way
          List of Firefox add-on packages to install. Some
          pre-packaged add-ons are accessible from NUR,
          <link xlink:href="https://github.com/nix-community/NUR"/>.
          Once you have NUR installed run

          <screen language="console">
            <prompt>$</prompt> <userinput>nix-env -f '&lt;nixpkgs&gt;' -qaP -A nur.repos.rycee.firefox-addons</userinput>
          </screen>

          to list the available Firefox add-ons.

          </para><para>

          Note that it is necessary to manually enable these
          extensions inside Firefox after the first installation.

          </para><para>

          Extensions listed here will only be available in Firefox
          profiles managed through the
          <link linkend="opt-programs.firefox.profiles">programs.firefox.profiles</link>
          option. This is due to recent changes in the way Firefox
          handles extension side-loading.
        '';
      };

      profiles = mkOption {
        type = types.attrsOf (types.submodule ({config, name, ...}: {
          options = {
            name = mkOption {
              type = types.str;
              default = name;
              description = "Profile name.";
            };

            id = mkOption {
              type = types.ints.unsigned;
              default = 0;
              description = ''
                Profile ID. This should be set to a unique number per profile.
              '';
            };

            settings = mkOption {
              type = with types; attrsOf (either bool (either int str));
              default = {};
              example = literalExample ''
                {
                  "browser.startup.homepage" = "https://nixos.org";
                  "browser.search.region" = "GB";
                  "browser.search.isUS" = false;
                  "distribution.searchplugins.defaultLocale" = "en-GB";
                  "general.useragent.locale" = "en-GB";
                  "browser.bookmarks.showMobileBookmarks" = true;
                }
              '';
              description = "Attribute set of Firefox preferences.";
            };

            extraConfig = mkOption {
              type = types.lines;
              default = "";
              description = ''
                Extra preferences to add to <filename>user.js</filename>.
              '';
            };

            userChrome = mkOption {
              type = types.lines;
              default = "";
              description = "Custom Firefox user chrome CSS.";
              example = ''
                /* Hide tab bar in FF Quantum */
                @-moz-document url("chrome://browser/content/browser.xul") {
                  #TabsToolbar {
                    visibility: collapse !important;
                    margin-bottom: 21px !important;
                  }

                  #sidebar-box[sidebarcommand="treestyletab_piro_sakura_ne_jp-sidebar-action"] #sidebar-header {
                    visibility: collapse !important;
                  }
                }
              '';
            };

            userContent = mkOption {
              type = types.lines;
              default = "";
              description = "Custom Firefox user content CSS.";
              example = ''
                /* Hide scrollbar in FF Quantum */
                *{scrollbar-width:none !important}
              '';
            };

            path = mkOption {
              type = types.str;
              default = name;
              description = "Profile path.";
            };

            isDefault = mkOption {
              type = types.bool;
              default = config.id == 0;
              defaultText = "true if profile ID is 0";
              description = "Whether this is a default profile.";
            };

            extensions = mkOption {
              type = types.listOf types.package;
              default = [];
              example = literalExample ''
              '';
              description = "";
            };

            extraPolicies = mkOption {
              type = semanticTypes.zncConf;
              default = {};
              example = literalExample ''
                "NoDefaultBookmarks" = true;
                "OfferToSaveLogins" = false;
              '';
              description = "Attribute set of Firefox policies.";
            };

          };
        }));
        default = {};
        description = "Attribute set of Firefox profiles.";
      };

      enableGnomeExtensions = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to enable the GNOME Shell native host connector. Note, you
          also need to set the NixOS option
          <literal>services.gnome3.chrome-gnome-shell.enable</literal> to
          <literal>true</literal>.
        '';
      };

      extraPolicies = mkOption {
        type = semanticTypes.zncConf;
        default = {};
        example = literalExample ''
          "NoDefaultBookmarks" = true;
          "OfferToSaveLogins" = false;
        '';
        description = "Attribute set of Firefox policies.";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      (
        let
          defaults =
            catAttrs "name" (filter (a: a.isDefault) (attrValues cfg.profiles));
        in {
          assertion = cfg.profiles == {} || length defaults == 1;
          message =
            "Must have exactly one default Firefox profile but found "
            + toString (length defaults)
            + optionalString (length defaults > 1)
                (", namely " + concatStringsSep ", " defaults);
        }
      )

      (
        let
          duplicates =
            filterAttrs (_: v: length v != 1)
            (zipAttrs
            (mapAttrsToList (n: v: { "${toString v.id}" = n; })
            (cfg.profiles)));

          mkMsg = n: v: "  - ID ${n} is used by ${concatStringsSep ", " v}";
        in {
          assertion = duplicates == {};
          message =
            "Must not have Firefox profiles with duplicate IDs but\n"
            + concatStringsSep "\n" (mapAttrsToList mkMsg duplicates);
        }
      )
    ];

    warnings = optional (cfg.enableGnomeExtensions or false) ''
      Using 'programs.firefox.enableGnomeExtensions' has been deprecated and
      will be removed in the future. Please change to overriding the package
      configuration using 'programs.firefox.package' instead. You can refer to
      its example for how to do this.
    '';

    home.packages =
      let
        # The configuration expected by the Firefox wrapper.
        fcfg = {
          enableGnomeExtensions = cfg.enableGnomeExtensions;
        };

        # A bit of hackery to force a config into the wrapper.
        browserName = cfg.package.browserName
          or (builtins.parseDrvName cfg.package.name).name;

        # The configuration expected by the Firefox wrapper builder.
        bcfg = setAttrByPath [browserName] fcfg;

        package =
          if isDarwin then
            cfg.package
          else if versionAtLeast config.home.stateVersion "19.09" then
            cfg.package.override (old: { cfg = old.cfg or {} // fcfg; })
          else
            (pkgs.wrapFirefox.override { config = bcfg; }) cfg.package { };
      in
        [ package ];

    home.file = mkMerge (
      [{
        "${firefoxConfigPath}/profiles.ini" = mkIf (cfg.profiles != {}) {
          text = profilesIni;
        };
      }]
      # merge the global config with the profiles -> policies will only be used in some cases
      ++ flip mapAttrsToList (mapAttrs (n: v: { extensions = cfg.extensions ++ v.extensions; extraPolicies = cfg.extraPolicies // v.extraPolicies; individualPolicies = cfg.individualPolicies; } // (filterAttrs (na: va: na != "extensions" && na != "extraPolicies") v)) cfg.profiles)
        (_: profile: {
        "${profilesPath}/${profile.path}/chrome/userChrome.css" =
          mkIf (profile.userChrome != "") {
            text = profile.userChrome;
          };

        "${profilesPath}/${profile.path}/chrome/userContent.css" =
          mkIf (profile.userContent != "") {
            text = profile.userContent;
          };

        "${profilesPath}/${profile.path}/user.js" =
          mkIf (profile.settings != {} || profile.extraConfig != "" || profile.extensions != [] || profile.extraPolicies != {}) {
            text = let
              settings = if (profile.extensions != [] || profile.extraPolicies != {})
              then profile.settings // (if (profile.individualPolicies == true) then { "toolkit.policies.loadFrom" = 2; } else { "toolkit.policies.perUserDir" = true; } )
              else profile.settings;
            in mkUserJs settings profile.extraConfig;
          };

        "${profilesPath}/${profile.path}/policies.json" = mkIf (profile.individualPolicies == true && (profile.extraPolicies != {} || profile.extensions != [])) {
          text = (mkPolicies profile);
        };
      })
    );

    systemd.user = {
      paths = {
        firefox-policies-writer = {
          Unit = { Description = "Firefox Policies Writer"; };
          Path = {
# 13:27:29  eyJhb | Can't seem to find this, but I have a path unit, where I would like to monitor $XDG_RUNTIME_DIR, can I use           │ ablackack
#                 | "$XDG_RUNTIME_DIR/something/file" as a path variable?                                                                │ Adbray
# 13:28:56 damjan | wild guess, not. but maybe try %t                                                                                    │ adema
# 113:29:59  eyJhb | Is there a list of varibales some place damjan ? - Also it IS a user path unit, just in case                         │ Aelius
# 113:30:21 damjan | eyJhb: afaik man systemd.unit                                                                                        │ af1cs
# 113:30:54 damjan | https://www.freedesktop.org/software/systemd/man/systemd.unit.html#Specifiers                                        │ Ahti333_
# 113:31:04  eyJhb | Uhh, nice. Lets see                                                                                                  │ aib
# 113:31:35  eyJhb | Or maybe the userid will work, if any work in that variable...                                                       │ aidalgol
            # PathExists = "/run/user/$XDG_RUNTIME_DIR/firefox/policies.json";
            PathExists = "/run/user/1000/firefox/policies.json";
            MakeDirectory = true;
            DirectoryMode = 0700;
          };
        };
      };
      services = {
        firefox-policies-writer = {
          Unit = { Description = "Firefox Policies Writer"; };

          Install = { WantedBy = [ "default.target" ]; };

          Service = {
            Environment = [ "XDG_RUNTIME_DIR=/run/user/1000" ];
            Type = "simple";

            ExecStart = let
              policiesFile = pkgs.writeText "policies.json" (mkPolicies cfg);
            in (toString (pkgs.writeShellScript "dropbox-start" ''
              # if file exists, then we do nothing
              if [[ -f $XDG_RUNTIME_DIR/firefox/policies.json ]]; then
                rm $XDG_RUNTIME_DIR/firefox/policies.json
              fi

              ln -s ${policiesFile} $XDG_RUNTIME_DIR/firefox/policies.json
            ''));
        };
      };
    };
  };

    # home.activation.runtime = hm.dag.entryAfter [ "writeBoundary" ] (let
    #   policiesFile = pkgs.writeText "policies.json" (mkPolicies cfg);
    #   shouldRun = (cfg.extensions != [] || cfg.extraPolicies != {});
    # in ''
    #   # check if this should run, if not just exit 0
    #   if [[ ! ${pkgs.lib.boolToString shouldRun} ]]; then
    #     exit 0
    #   fi

    #   # set our runtime dir + policies location here 
    #   XDG_RUNTIME_DIR="/run/user/$(id -u)"
    #   POLICIES_LOCATION="$XDG_RUNTIME_DIR/firefox/policies.json"

    #   # create the dir, so it exists else other operations will fail
    #   mkdir -p "$XDG_RUNTIME_DIR/firefox"

    #   # first remove the dir, if it exists
    #   if [[ -f $POLICIES_LOCATION ]]; then
    #     rm $POLICIES_LOCATION
    #   fi

    #   # actually link it
    #   ln -s ${policiesFile} $POLICIES_LOCATION
    # '');
  };
}
