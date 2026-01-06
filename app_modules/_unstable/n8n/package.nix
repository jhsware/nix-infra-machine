# Custom n8n package with version selection
# Based on: https://github.com/NixOS/nixpkgs/blob/nixos-25.11/pkgs/by-name/n8/n8n/package.nix
#
# To add a new version:
# 1. Get the source hash:
#    nix-prefetch-url --unpack https://github.com/n8n-io/n8n/archive/refs/tags/n8n@VERSION.tar.gz
# 2. Get the pnpm deps hash by running a build with lib.fakeHash and copying the correct hash from error
# 3. Add entry to versionHashes below

{
  lib,
  stdenv,
  fetchFromGitHub,
  nodejs,
  pnpm_10,
  fetchPnpmDeps,
  pnpmConfigHook,
  python3,
  node-gyp,
  cctools,
  xcbuild,
  libkrb5,
  libmongocrypt,
  libpq,
  makeWrapper,
  # Custom parameters
  version ? "2.1.5",
  buildMemoryMB ? 4096,
}:

let
  # Known version hashes
  # To add a new version, run:
  #   nix-prefetch-url --unpack https://github.com/n8n-io/n8n/archive/refs/tags/n8n@VERSION.tar.gz
  # Then build with lib.fakeHash for pnpmDepsHash to get the correct hash
  versionHashes = {
    "2.1.5" = {
      srcHash = "sha256-/MPY3j/2I3CgX5rRhzj3v7bHjaQEDMNnkVfk3taCrYA=";
      pnpmDepsHash = "sha256-FRoZIINONy0kFPQAJhOwnCUv7HHwdgqm3r5SJmq4UYk=";
    };
    "2.1.4" = {
      srcHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      pnpmDepsHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    };
    "2.0.0" = {
      srcHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      pnpmDepsHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    };
    "1.120.4" = {
      srcHash = "sha256-gUqQM/eA7GnvFYiduSGkj/MCvgWNQPhDLExAJz67bHg=";
      pnpmDepsHash = "sha256-UWiN3NvI8We16KwY5JspyX0ok1PJWVg0T5zw+0SnrWk=";
    };
    "1.91.3" = {
      srcHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      pnpmDepsHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    };
  };

  # Get hashes for the requested version
  hashes = versionHashes.${version} or (throw ''
    n8n version ${version} is not supported.
    
    Supported versions: ${builtins.concatStringsSep ", " (builtins.attrNames versionHashes)}
    
    To add support for version ${version}:
    1. Get source hash: nix-prefetch-url --unpack https://github.com/n8n-io/n8n/archive/refs/tags/n8n@${version}.tar.gz
    2. Add entry to versionHashes in app_modules/_unstable/n8n/package.nix
    3. Build once with placeholder pnpmDepsHash to get the correct hash from the error message
  '');

in
stdenv.mkDerivation (finalAttrs: {
  pname = "n8n";
  inherit version;

  src = fetchFromGitHub {
    owner = "n8n-io";
    repo = "n8n";
    tag = "n8n@${finalAttrs.version}";
    hash = hashes.srcHash;
  };

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    pnpm = pnpm_10;
    fetcherVersion = 2;
    hash = hashes.pnpmDepsHash;
  };

  nativeBuildInputs = [
    pnpmConfigHook
    pnpm_10
    python3        # required to build sqlite3 bindings
    node-gyp       # required to build sqlite3 bindings
    makeWrapper
  ] ++ lib.optionals stdenv.hostPlatform.isDarwin [
    cctools
    xcbuild
  ];

  buildInputs = [
    nodejs
    libkrb5
    libmongocrypt
    libpq
  ];

  # Set memory limit for Node.js during build
  env = {
    NODE_OPTIONS = "--max-old-space-size=${toString buildMemoryMB}";
  };

  buildPhase = ''
    runHook preBuild

    pushd node_modules/sqlite3
    node-gyp rebuild
    popd

    # TODO: use deploy after resolved https://github.com/pnpm/pnpm/issues/5315
    pnpm build --filter=n8n

    runHook postBuild
  '';

  preInstall = ''
    echo "Removing non-deterministic and unnecessary files"

    find -type d -name .turbo -exec rm -rf {} +
    rm node_modules/.modules.yaml
    rm -f packages/nodes-base/dist/types/nodes.json

    CI=true pnpm --ignore-scripts prune --prod
    find -type f \( -name "*.ts" -o -name "*.map" \) -exec rm -rf {} +
    rm -rf node_modules/.pnpm/{typescript*,prettier*}
    shopt -s globstar
    # https://github.com/pnpm/pnpm/issues/3645
    find node_modules packages/**/node_modules -xtype l -delete

    echo "Removed non-deterministic and unnecessary files"
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/{bin,lib/n8n}
    mv {packages,node_modules} $out/lib/n8n

    makeWrapper $out/lib/n8n/packages/cli/bin/n8n $out/bin/n8n \
      --set N8N_RELEASE_TYPE "stable"

    runHook postInstall
  '';

  # this package has ~80000 files, these take too long and seem to be unnecessary
  dontStrip = true;
  dontPatchELF = true;
  dontRewriteSymlinks = true;

  meta = {
    description = "Free and source-available fair-code licensed workflow automation tool";
    longDescription = ''
      Free and source-available fair-code licensed workflow automation tool.
      Easily automate tasks across different services.
    '';
    homepage = "https://n8n.io";
    changelog = "https://github.com/n8n-io/n8n/releases/tag/n8n@${finalAttrs.version}";
    maintainers = with lib.maintainers; [
      gepbird
      AdrienLemaire
    ];
    license = lib.licenses.sustainableUse;
    mainProgram = "n8n";
    platforms = lib.platforms.unix;
  };
})
