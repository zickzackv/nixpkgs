{
  lib,
  stdenv,
  cacert,
  git,
  cargo,
  python3,
}:
let
  cargo-vendor-normalise = stdenv.mkDerivation {
    name = "cargo-vendor-normalise";
    src = ./cargo-vendor-normalise.py;
    nativeBuildInputs = [ python3.pkgs.wrapPython ];
    dontUnpack = true;
    installPhase = "install -D $src $out/bin/cargo-vendor-normalise";
    pythonPath = [ python3.pkgs.toml ];
    postFixup = "wrapPythonPrograms";
    doInstallCheck = true;
    installCheckPhase = ''
      # check that ../fetchcargo-default-config.toml is a fix point
      reference=${../fetchcargo-default-config.toml}
      < $reference $out/bin/cargo-vendor-normalise > test;
      cmp test $reference
    '';
    preferLocalBuild = true;
  };
in
{
  pname ? null,
  version ? null,
  name ? if args ? pname && args ? version then "${pname}-${version}" else "cargo-deps",
  src ? null,
  srcs ? [ ],
  patches ? [ ],
  sourceRoot ? "",
  cargoUpdateHook ? "",
  nativeBuildInputs ? [ ],
  ...
}@args:

assert lib.assertMsg (
  (args ? pname || args ? version) -> !(args ? name)
) "Either specify `pname` with `version`, or specify `name` only, not a mix of both.";
assert lib.assertMsg (
  args ? pname == args ? version
) "If `pname` is specified, `version` must be also, and vice versa.";
let
  # args to remove from the final call to stdenv.mkDerivation, as we've already handled them
  removedArgs = [
    "name"
    "pname"
    "version"
    "sha256"
    "cargoUpdateHook"
    "nativeBuildInputs"
  ];

  hash_ =
    if args ? hash then
      {
        outputHashAlgo = if args.hash == "" then "sha256" else null;
        outputHash = args.hash;
      }
    else if args ? sha256 then
      {
        outputHashAlgo = "sha256";
        outputHash = args.sha256;
      }
    else
      throw "fetchCargoTarball requires a hash for ${name}";
in
stdenv.mkDerivation (
  {
    name = "${name}-vendor.tar.gz";
    nativeBuildInputs = [
      cacert
      git
      cargo-vendor-normalise
      cargo
    ] ++ nativeBuildInputs;

    dontConfigure = true;
    buildPhase = ''
      runHook preBuild

      # Ensure deterministic Cargo vendor builds
      export SOURCE_DATE_EPOCH=1

      if [ -n "''${cargoRoot-}" ]; then
        cd "$cargoRoot"
      fi

      if [[ ! -f Cargo.lock ]]; then
          echo
          echo "ERROR: The Cargo.lock file doesn't exist"
          echo
          echo "Cargo.lock is needed to make sure that cargoHash/cargoSha256 doesn't change"
          echo "when the registry is updated."
          echo

          exit 1
      fi

      # Keep the original around for copyLockfile
      cp Cargo.lock Cargo.lock.orig

      export CARGO_HOME=$(mktemp -d cargo-home.XXX)
      CARGO_CONFIG=$(mktemp cargo-config.XXXX)

      if [[ -n "$NIX_CRATES_INDEX" ]]; then
      cat >$CARGO_HOME/config.toml <<EOF
      [source.crates-io]
      replace-with = 'mirror'
      [source.mirror]
      registry = "$NIX_CRATES_INDEX"
      EOF
      fi

      ${cargoUpdateHook}

      # Override the `http.cainfo` option usually specified in `.cargo/config`.
      export CARGO_HTTP_CAINFO="''${NIX_SSL_CERT_FILE:-${cacert}/etc/ssl/certs/ca-bundle.crt}

      if grep '^source = "git' Cargo.lock; then
          echo
          echo "ERROR: The Cargo.lock contains git dependencies"
          echo
          echo "This is not supported in the default fixed-output derivation fetcher."
          echo "Set \`useFetchCargoVendor = true\` / use fetchCargoVendor"
          echo "or use cargoLock.lockFile / importCargoLock instead."
          echo

          exit 1
      fi

      cargo vendor $name --respect-source-config | cargo-vendor-normalise > $CARGO_CONFIG

      # Create an empty vendor directory when there is no dependency to vendor
      mkdir -p $name
      # Add the Cargo.lock to allow hash invalidation
      cp Cargo.lock.orig $name/Cargo.lock

      # Packages with git dependencies generate non-default cargo configs, so
      # always install it rather than trying to write a standard default template.
      install -D $CARGO_CONFIG $name/.cargo/config

      runHook postBuild
    '';

    # Build a reproducible tar, per instructions at https://reproducible-builds.org/docs/archives/
    installPhase = ''
      tar --owner=0 --group=0 --numeric-owner --format=gnu \
          --sort=name --mtime="@$SOURCE_DATE_EPOCH" \
          -czf $out $name
    '';

    inherit (hash_) outputHashAlgo outputHash;

    impureEnvVars = lib.fetchers.proxyImpureEnvVars ++ [ "NIX_CRATES_INDEX" ];
  }
  // (removeAttrs args removedArgs)
)
