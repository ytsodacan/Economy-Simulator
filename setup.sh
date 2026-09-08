#!/usr/bin/env bash

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_DIR="$ROOT_DIR/services/api"
API_CONFIG="$API_DIR/config.json"
WEBSITE_DIR="$ROOT_DIR/services/Roblox/Roblox.Website"
WEBSITE_APPSETTINGS="$WEBSITE_DIR/appsettings.json"
WEBSITE_APPSETTINGS_EXAMPLE="$WEBSITE_DIR/appsettings.example.json"
FRONTEND_DIR="$ROOT_DIR/services/2016-roblox-main"
FRONTEND_CONFIG="$FRONTEND_DIR/config.json"

confirm() {
  local prompt="$1"
  local default_answer="${2:-N}"
  local answer=""

  if [[ "$default_answer" == "Y" ]]; then
    read -r -p "$prompt [Y/n]: " answer
    answer="${answer:-Y}"
  else
    read -r -p "$prompt [y/N]: " answer
    answer="${answer:-N}"
  fi

  [[ "$answer" =~ ^[Yy]$ ]]
}

require_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[warn] Missing required command: $cmd"
    return 1
  fi
  return 0
}

write_api_config_template() {
  local db_host db_user db_password db_name

  read -r -p "Postgres host [127.0.0.1]: " db_host
  db_host="${db_host:-127.0.0.1}"

  read -r -p "Postgres user [postgres]: " db_user
  db_user="${db_user:-postgres}"

  read -r -s -p "Postgres password: " db_password
  echo

  read -r -p "Postgres database name: " db_name
  if [[ -z "$db_name" ]]; then
    echo "[warn] Database name cannot be empty."
    return 1
  fi

  API_CONFIG_ENV="$API_CONFIG" DB_HOST="$db_host" DB_USER="$db_user" DB_PASSWORD="$db_password" DB_NAME="$db_name" node <<'NODE'
const fs = require('fs');

const outputPath = process.env.API_CONFIG_ENV;
const config = {
  knex: {
    client: 'pg',
    connection: {
      host: process.env.DB_HOST,
      user: process.env.DB_USER,
      password: process.env.DB_PASSWORD,
      database: process.env.DB_NAME,
    },
  },
};

fs.writeFileSync(outputPath, JSON.stringify(config, null, 2) + '\n');
NODE

  echo "[ok] Created $API_CONFIG"
}

update_website_directories() {
  ROOT_DIR_ENV="$ROOT_DIR" APPSETTINGS_ENV="$WEBSITE_APPSETTINGS" node <<'NODE'
const fs = require('fs');
const path = require('path');

const root = process.env.ROOT_DIR_ENV;
const appSettingsPath = process.env.APPSETTINGS_ENV;
const text = fs.readFileSync(appSettingsPath, 'utf8');
const data = JSON.parse(text);

const pathFromRoot = (...parts) => path.join(root, ...parts).replace(/\\/g, '/');

data.Directories = data.Directories || {};
Object.assign(data.Directories, {
  Storage: pathFromRoot('services', 'api', 'storage') + '/',
  Asset: pathFromRoot('services', 'api', 'storage', 'asset') + '/',
  Public: pathFromRoot('services', 'api', 'public') + '/',
  Thumbnails: pathFromRoot('services', 'api', 'public', 'images', 'thumbnails') + '/',
  GroupIcons: pathFromRoot('services', 'api', 'public', 'images', 'groups') + '/',
  XmlTemplates: pathFromRoot('services', 'Roblox', 'Roblox.Libraries', 'Templates') + '/',
  JsonData: pathFromRoot('services', 'Roblox', 'Roblox.Libraries', 'Json') + '/',
  AdminBundle: pathFromRoot('services', 'admin', 'public') + '/',
  EconomyChatBundle: pathFromRoot('services', 'economy-chat', 'build') + '/',
  RCCLuaScripts: pathFromRoot('services', 'Roblox', 'Roblox.Rendering', 'internalscripts') + '/',
  RCCService: pathFromRoot('services', 'RCCService') + '/'
});

fs.writeFileSync(appSettingsPath, JSON.stringify(data, null, 2) + '\n');
console.log('[ok] Updated Directories values in appsettings.json');
NODE
}

validate_website_values() {
  APPSETTINGS_ENV="$WEBSITE_APPSETTINGS" node <<'NODE'
const fs = require('fs');

const appSettingsPath = process.env.APPSETTINGS_ENV;
const text = fs.readFileSync(appSettingsPath, 'utf8');
const data = JSON.parse(text);

const warnings = [];
const postgres = String(data.Postgres || '');
if (!postgres || postgres.includes('******')) {
  warnings.push('Postgres connection string still has placeholders.');
}

const directories = data.Directories || {};
const storageDir = String(directories.Storage || '');
if (!storageDir || storageDir.includes('/home/my_username/source-code/') || storageDir.includes('C:/Users/Landon/Desktop/Economy-Simulator')) {
  warnings.push('Directories paths still look like placeholders or sample values.');
}

const ownerUserId = data.OwnerUserId;
if (Array.isArray(ownerUserId) && ownerUserId.includes(12)) {
  warnings.push('OwnerUserId still includes 12. Replace it with your own user id after registering.');
}

const authFields = [
  ['AssetValidation.Authorization', data.AssetValidation && data.AssetValidation.Authorization],
  ['Render.Authorization', data.Render && data.Render.Authorization],
];
for (const [name, value] of authFields) {
  const str = String(value || '');
  if (!str || /auth here/i.test(str)) {
    warnings.push(`${name} appears unset.`);
  }
}

if (!warnings.length) {
  console.log('[ok] appsettings.json passed basic validation checks.');
  process.exit(0);
}

console.log('[warn] appsettings.json needs manual updates:');
for (const warning of warnings) {
  console.log(`  - ${warning}`);
}
NODE
}

ensure_frontend_config() {
  if [[ -f "$FRONTEND_CONFIG" ]]; then
    echo "[ok] Frontend config already exists: $FRONTEND_CONFIG"
    return 0
  fi

  if ! require_command node; then
    echo "[warn] Cannot auto-create frontend config without node."
    return 1
  fi

  if confirm "Create frontend config.json by running util/create_config.js?" Y; then
    (cd "$FRONTEND_DIR" && node ./util/create_config.js)
  else
    echo "[warn] Skipped frontend config creation."
  fi
}

set_frontend_api_format() {
  FRONTEND_CONFIG_ENV="$FRONTEND_CONFIG" node <<'NODE'
const fs = require('fs');

const configPath = process.env.FRONTEND_CONFIG_ENV;
const text = fs.readFileSync(configPath, 'utf8');
const data = JSON.parse(text);

if (!data.publicRuntimeConfig) data.publicRuntimeConfig = {};
if (!data.publicRuntimeConfig.backend) data.publicRuntimeConfig.backend = {};

data.publicRuntimeConfig.backend.apiFormat = 'http://localhost:5000/apisite/{0}{1}';

fs.writeFileSync(configPath, JSON.stringify(data, null, 2) + '\n');
console.log('[ok] Updated frontend apiFormat to localhost website endpoint.');
NODE
}

echo "Economy Simulator setup helper"
echo "Repository root: $ROOT_DIR"
echo

echo "Step 1/5: services/api config"
if [[ -f "$API_CONFIG" ]]; then
  echo "[ok] Found $API_CONFIG"
else
  echo "[info] Missing $API_CONFIG"
  if confirm "Create services/api/config.json now?" Y; then
    if ! require_command node; then
      echo "[warn] node is required to write config.json automatically."
    else
    write_api_config_template
    fi
  else
    echo "[warn] Skipping config creation; migrations will fail until config.json is created."
  fi
fi

echo
echo "Step 2/5: services/api dependency install + knex migrations"
if require_command npm; then
  if confirm "Run npm install in services/api?" Y; then
    (cd "$API_DIR" && npm i)
  fi

  if [[ -f "$API_CONFIG" ]] && confirm "Run npx knex migrate:latest in services/api?" Y; then
    (cd "$API_DIR" && npx knex migrate:latest)
  elif [[ ! -f "$API_CONFIG" ]]; then
    echo "[warn] Skipping migrations because $API_CONFIG is missing."
  fi
else
  echo "[warn] npm is required for API setup steps."
fi

echo
echo "Step 3/5: services/Roblox/Roblox.Website appsettings"
if [[ ! -f "$WEBSITE_APPSETTINGS" ]]; then
  if [[ -f "$WEBSITE_APPSETTINGS_EXAMPLE" ]]; then
    echo "[info] Found appsettings.example.json"
    if confirm "Rename appsettings.example.json to appsettings.json?" Y; then
      mv "$WEBSITE_APPSETTINGS_EXAMPLE" "$WEBSITE_APPSETTINGS"
      echo "[ok] Created $WEBSITE_APPSETTINGS"
    fi
  else
    echo "[warn] appsettings.json is missing and no appsettings.example.json was found."
  fi
else
  echo "[ok] Found $WEBSITE_APPSETTINGS"
fi

if [[ -f "$WEBSITE_APPSETTINGS" ]]; then
  if confirm "Update Directories in appsettings.json to this repository path?" Y; then
    cp "$WEBSITE_APPSETTINGS" "$WEBSITE_APPSETTINGS.bak"
    update_website_directories
    echo "[ok] Backup written to $WEBSITE_APPSETTINGS.bak"
  fi
  validate_website_values
  echo "[info] Manually verify Postgres, Redis, Urls/BaseUrl, OwnerUserId, and auth values in appsettings.json"
fi

echo
echo "Step 4/5: services/2016-roblox-main frontend"
echo "[info] See setup guide: $FRONTEND_DIR/docs/get-started.md"
ensure_frontend_config

if require_command npm && confirm "Run npm install in services/2016-roblox-main?" Y; then
  (cd "$FRONTEND_DIR" && npm i)
fi

if [[ -f "$FRONTEND_CONFIG" ]] && confirm "Set frontend apiFormat to http://localhost:5000/apisite/{0}{1}?" Y; then
  set_frontend_api_format
fi

echo
echo "Step 5/5: manual run/start guidance"
cat <<GUIDE
Next commands:

1) Start website service:
   cd "$WEBSITE_DIR"
   dotnet run

2) Start admin builder (new terminal):
   cd "$ROOT_DIR/services/admin"
   npm i
   npm run dev

3) Start asset validation service (new terminal):
   cd "$ROOT_DIR/services/AssetValidationServiceV2"
   go run main.go

4) Register an account, then set OwnerUserId in appsettings.json to your own user id and restart dotnet run.

Note: services/game-server will likely still need manual edits for full game/render service compatibility.
GUIDE

echo
echo "Setup helper finished."
