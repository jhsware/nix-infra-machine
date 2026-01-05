# Beiwe Backend package
# A Django-based smartphone digital phenotyping research platform backend
#
# Using jhsware fork which adds environment variable support for Celery configuration
# (CELERY_MANAGER_IP and CELERY_PASSWORD instead of manager_ip file)
#
# To update to a new version:
# 1. Update the rev to the new commit hash
# 2. Run: nix-prefetch-url --unpack https://github.com/jhsware/beiwe-backend/archive/<NEW_COMMIT>.tar.gz
# 3. Update the hash with the output from step 2

{
  lib,
  stdenv,
  fetchFromGitHub,
  fetchPypi,
  python312,
  python312Packages,
  postgresql,
  # Custom parameters
  rev ? "93be878",  # jhsware fork with env var support for Celery
}:


let
  # Known version hashes
  # To add a new version, run:
  #   nix-prefetch-url --unpack https://github.com/jhsware/beiwe-backend/archive/<COMMIT>.tar.gz
  versionHashes = {
    # jhsware fork with CELERY_MANAGER_IP and CELERY_PASSWORD env var support
    "93be878" = {
      srcHash = "sha256-marYxVINxgW0X9x+xoHL7bdRYEgm+4q+O1CF5WXeZGg=";
    };
    # Original onnela-lab version (for reference)
    "6bb5363" = {
      srcHash = "sha256-EeD+I3mWC81mhmlO9cKzRrArDLKVBmqhZjgJI8+geu0=";
    };
  };

  hashes = versionHashes.${rev} or (throw ''
    beiwe-backend revision ${rev} is not supported.
    
    Supported revisions: ${builtins.concatStringsSep ", " (builtins.attrNames versionHashes)}
    
    To add support for revision ${rev}:
    1. Get source hash: nix-prefetch-url --unpack https://github.com/jhsware/beiwe-backend/archive/${rev}.tar.gz
    2. Add entry to versionHashes in app_modules/_unstable/beiwe-backend/package.nix
  '');

  # Build cronutils from PyPI (not available in nixpkgs)
  cronutils = python312Packages.buildPythonPackage rec {
    pname = "cronutils";
    version = "0.4.2";
    format = "setuptools";

    src = fetchPypi {
      inherit pname version;
      hash = "sha256-SFHkQ9NltAyWArArkFpSBIJF3gMoXbxHEXreM1SEPUY=";
    };

    propagatedBuildInputs = with python312Packages; [
      sentry-sdk
    ];

    # Tests require network access
    doCheck = false;

    pythonImportsCheck = [ "cronutils" ];

    meta = with lib; {
      description = "Utilities for cron jobs including error handling";
      homepage = "https://pypi.org/project/cronutils/";
      license = licenses.mit;
    };
  };

  # Build beiwe-forest from GitHub (Forest analysis library)
  # See: https://github.com/onnela-lab/forest
  # Note: pip install git+https://github.com/onnela-lab/forest
  beiweForest = python312Packages.buildPythonPackage rec {
    pname = "forest";
    version = "unstable-2024-12-01";
    format = "pyproject";

    src = fetchFromGitHub {
      owner = "onnela-lab";
      repo = "forest";
      rev = "develop";  # Main development branch
      hash = "sha256-t+oq/jfJUmWCs0XzrN+xciYc3lz4oPiO8V8qfj3iTJA=";
    };

    nativeBuildInputs = with python312Packages; [
      setuptools
    ];

    propagatedBuildInputs = with python312Packages; [
      # Core data science
      numpy
      pandas
      scipy
      scikit-learn
      
      # Time/date utilities
      pytz
      holidays
      timezonefinder
      
      # GIS/mapping
      shapely
      pyproj
      
      # Audio processing (for voice analysis)
      librosa
      
      # HTTP/API
      requests
      ratelimit
    ];

    # Some optional dependencies not in nixpkgs (openrouteservice, ssqueezepy)
    # Disable strict runtime deps check to allow partial functionality
    pythonRelaxDeps = true;
    pythonRemoveDeps = [ "openrouteservice" "ssqueezepy" ];

    # Tests require data files
    doCheck = false;

    pythonImportsCheck = [ "forest" ];

    meta = with lib; {
      description = "Forest library for analyzing Beiwe digital phenotyping data";
      homepage = "https://github.com/onnela-lab/forest";
      license = licenses.bsd3;
    };
  };

  # Python environment with all dependencies from requirements.txt

  pythonEnv = python312.withPackages (ps: with ps; [
    # Django and web framework
    django
    django-extensions
    django-timezone-field  # Provides timezone_field module
    gunicorn
    jinja2
    
    # Database - using psycopg (v3) as specified in requirements.txt
    psycopg
    
    # AWS/S3 support
    boto3
    
    # Celery for task queue
    celery
    
    # Error tracking and monitoring
    sentry-sdk
    cronutils  # Custom package built above
    
    # Firebase (push notifications)
    firebase-admin
    
    # Security and crypto
    pycryptodomex  # Note: pycryptodomex not pycryptodome
    pyotp
    bleach
    
    # Serialization
    orjson
    
    # Date/time utilities
    python-dateutil
    pytz
    
    # Compression - pyzstd provides "import pyzstd" (jhsware fork uses pyzstd)
    pyzstd
    
    # Data analysis
    numpy
    pandas
    scipy
    scikit-learn
    beiweForest  # Custom package - provides "import forest"
    
    # Other utilities
    requests
    rcssmin
    pypng
    pyqrcode
    
    # Development/debugging
    ipython
    mypy
  ]);


in

stdenv.mkDerivation {
  pname = "beiwe-backend";
  version = rev;

  src = fetchFromGitHub {
    owner = "jhsware";  # Fork with env var support for Celery
    repo = "beiwe-backend";
    inherit rev;
    hash = hashes.srcHash;
  };

  buildInputs = [
    pythonEnv
    postgresql
  ];

  # No build phase needed - this is a Python application
  dontBuild = true;

  # Patch Django settings to support DATABASE_SSLMODE environment variable
  # This allows controlling PostgreSQL SSL mode via environment variable
  postPatch = ''
    # Find the Django settings file and patch the database configuration
    # to include sslmode from environment variable
    
    # Add sslmode support to database configuration
    # This sed command finds the DATABASES dict and adds OPTIONS with sslmode
    if [ -f config/django_settings.py ]; then
      echo "Patching config/django_settings.py for DATABASE_SSLMODE support..."
      
      # Add import for os at the top if not already there
      if ! grep -q "^import os" config/django_settings.py; then
        sed -i '1i import os' config/django_settings.py
      fi
      
      # Append code to add sslmode to database options at the end of the file
      cat >> config/django_settings.py << 'SSLPATCH'

# Patched by nix-infra-machine: Add DATABASE_SSLMODE support
# This allows setting PostgreSQL sslmode via environment variable
_db_sslmode = os.environ.get('DATABASE_SSLMODE', os.environ.get('PGSSLMODE', 'prefer'))
if 'default' in DATABASES:
    if 'OPTIONS' not in DATABASES['default']:
        DATABASES['default']['OPTIONS'] = {}
    DATABASES['default']['OPTIONS']['sslmode'] = _db_sslmode
SSLPATCH
      echo "Patched database settings for sslmode support"
    else
      echo "Warning: config/django_settings.py not found, skipping sslmode patch"
    fi
  '';

  installPhase = ''
    runHook preInstall

    # Create directory structure
    mkdir -p $out/lib/beiwe-backend
    mkdir -p $out/bin

    # Copy all source files
    cp -r . $out/lib/beiwe-backend/

    # Create wrapper scripts
    cat > $out/bin/beiwe-manage <<EOF
#!/usr/bin/env bash
cd $out/lib/beiwe-backend
exec ${pythonEnv}/bin/python manage.py "\$@"
EOF
    chmod +x $out/bin/beiwe-manage

    cat > $out/bin/beiwe-gunicorn <<EOF
#!/usr/bin/env bash
cd $out/lib/beiwe-backend
exec ${pythonEnv}/bin/gunicorn "\$@"
EOF
    chmod +x $out/bin/beiwe-gunicorn

    cat > $out/bin/beiwe-celery <<EOF
#!/usr/bin/env bash
cd $out/lib/beiwe-backend
exec ${pythonEnv}/bin/celery "\$@"
EOF
    chmod +x $out/bin/beiwe-celery

    runHook postInstall
  '';

  meta = {
    description = "Beiwe - smartphone-based digital phenotyping research platform backend";
    longDescription = ''
      The Beiwe Research Platform collects high-throughput smartphone-based 
      digital phenotyping data including spatial trajectories (GPS), physical 
      activity patterns (accelerometer/gyroscope), social networks and 
      communication dynamics (call/text logs), and voice samples.
      
      This package provides the Django-based backend server that supports:
      - Web-based study management portal
      - API endpoints for iOS/Android mobile apps
      - Data processing pipelines
      
      This is the jhsware fork which adds environment variable support for 
      Celery configuration (CELERY_MANAGER_IP and CELERY_PASSWORD).
      
      Patched by nix-infra-machine to support DATABASE_SSLMODE environment
      variable for controlling PostgreSQL SSL mode.
    '';
    homepage = "https://github.com/jhsware/beiwe-backend";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.unix;
  };
}