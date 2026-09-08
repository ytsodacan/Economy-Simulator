#!/usr/bin/env bash

set -u -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_DIR="$ROOT_DIR/services/api"
API_CONFIG="$API_DIR/config.json"
WEBSITE_DIR="$ROOT_DIR/services/Roblox/Roblox.Website"
WEBSITE_APPSETTINGS="$WEBSITE_DIR/appsettings.json"
WEBSITE_APPSETTINGS_EXAMPLE="$WEBSITE_DIR/appsettings.example.json"
FRONTEND_DIR="$ROOT_DIR/services/2016-roblox-main"
FRONTEND_CONFIG="$FRONTEND_DIR/config.json"
ADMIN_DIR="$ROOT_DIR/services/admin"
ASSET_VALIDATION_DIR="$ROOT_DIR/services/AssetValidationServiceV2"

DB_HOST=""
DB_USER=""
DB_PASSWORD=""
DB_NAME=""

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

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

validate_identifier() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

start_postgres_redis_services() {
  local os_name
  os_name="$(uname -s)"

  if [[ "$os_name" == "Linux" ]]; then
    if ! require_command sudo; then
      echo "[warn] sudo is required to start postgres/redis services on Linux."
      return 1
    fi
    if require_command systemctl; then
      sudo systemctl enable --now postgresql || true
      sudo systemctl enable --now redis-server || true
      return 0
    fi
    if require_command service; then
      sudo service postgresql start || true
      sudo service redis-server start || true
    fi
    return 0
  fi

  if [[ "$os_name" == "Darwin" ]]; then
    if ! require_command brew; then
      echo "[warn] Homebrew is required to start postgres/redis services on macOS."
      return 1
    fi
    brew services start postgresql@14 >/dev/null 2>&1 || brew services start postgresql >/dev/null 2>&1 || true
    brew services start redis >/dev/null 2>&1 || true
    return 0
  fi
}

install_prereqs() {
  local os_name
  os_name="$(uname -s)"

  if [[ "$os_name" == "Linux" ]]; then
    if ! require_command apt-get; then
      echo "[info] apt-get not found; skipping automated package install."
      return 0
    fi
    if ! confirm "Install postgres + redis via apt-get (requires sudo)?" N; then
      return 0
    fi
    if ! require_command sudo; then
      echo "[warn] sudo is required for apt install."
      return 1
    fi
    sudo apt-get update
    sudo apt-get install -y postgresql postgresql-contrib redis-server
    start_postgres_redis_services
    echo "[ok] Completed apt-based postgres/redis install attempt."
    return 0
  fi

  if [[ "$os_name" == "Darwin" ]]; then
    if ! require_command brew; then
      echo "[warn] Homebrew is required for macOS automated install."
      echo "[info] Install Homebrew from https://brew.sh and re-run this script."
      return 1
    fi
    if ! confirm "Install postgres + redis via Homebrew?" N; then
      return 0
    fi
    if ! brew list --versions postgresql@14 >/dev/null 2>&1 && ! brew list --versions postgresql >/dev/null 2>&1; then
      brew install postgresql@14 || brew install postgresql
    fi
    brew list --versions redis >/dev/null 2>&1 || brew install redis
    start_postgres_redis_services
    echo "[ok] Completed Homebrew postgres/redis install attempt."
    return 0
  fi

  echo "[info] Unsupported OS for automated package install. Please install postgres and redis manually."
}

configure_postgres_role_and_db() {
  local pg_admin_host pg_admin_port pg_admin_user pg_admin_db pg_admin_password

  if ! require_command psql; then
    echo "[warn] psql is required for automated Postgres role/DB creation."
    return 1
  fi

  read -r -p "Postgres admin host [127.0.0.1]: " pg_admin_host
  pg_admin_host="${pg_admin_host:-127.0.0.1}"

  read -r -p "Postgres admin port [5432]: " pg_admin_port
  pg_admin_port="${pg_admin_port:-5432}"

  read -r -p "Postgres admin user [postgres]: " pg_admin_user
  pg_admin_user="${pg_admin_user:-postgres}"

  read -r -p "Postgres admin database [postgres]: " pg_admin_db
  pg_admin_db="${pg_admin_db:-postgres}"

  read -r -s -p "Postgres admin password (leave empty if not needed): " pg_admin_password
  echo

  read -r -p "App DB host for config [127.0.0.1]: " DB_HOST
  DB_HOST="${DB_HOST:-127.0.0.1}"

  read -r -p "App DB user [postgres]: " DB_USER
  DB_USER="${DB_USER:-postgres}"

  read -r -s -p "App DB password: " DB_PASSWORD
  echo

  read -r -p "App DB name: " DB_NAME
  if [[ -z "$DB_NAME" ]]; then
    echo "[warn] App DB name cannot be empty."
    return 1
  fi

  if ! validate_identifier "$DB_USER"; then
    echo "[warn] DB user must match [A-Za-z_][A-Za-z0-9_]* for automation."
    return 1
  fi

  if ! validate_identifier "$DB_NAME"; then
    echo "[warn] DB name must match [A-Za-z_][A-Za-z0-9_]* for automation."
    return 1
  fi

  local psql_cmd=(psql -h "$pg_admin_host" -p "$pg_admin_port" -U "$pg_admin_user" -d "$pg_admin_db" -v ON_ERROR_STOP=1)
  local db_user_escaped db_password_escaped db_name_escaped
  db_user_escaped="$(sql_escape "$DB_USER")"
  db_password_escaped="$(sql_escape "$DB_PASSWORD")"
  db_name_escaped="$(sql_escape "$DB_NAME")"

  local role_exists
  role_exists="$(PGPASSWORD="$pg_admin_password" "${psql_cmd[@]}" -tAc "SELECT 1 FROM pg_roles WHERE rolname='${db_user_escaped}' LIMIT 1;")"
  if [[ "$role_exists" == "1" ]]; then
    PGPASSWORD="$pg_admin_password" "${psql_cmd[@]}" -c "ALTER ROLE \"$DB_USER\" WITH LOGIN PASSWORD '$db_password_escaped';"
    echo "[ok] Updated existing role: $DB_USER"
  else
    PGPASSWORD="$pg_admin_password" "${psql_cmd[@]}" -c "CREATE ROLE \"$DB_USER\" WITH LOGIN PASSWORD '$db_password_escaped';"
    echo "[ok] Created role: $DB_USER"
  fi

  local db_exists
  db_exists="$(PGPASSWORD="$pg_admin_password" "${psql_cmd[@]}" -tAc "SELECT 1 FROM pg_database WHERE datname='${db_name_escaped}' LIMIT 1;")"
  if [[ "$db_exists" == "1" ]]; then
    echo "[ok] Database already exists: $DB_NAME"
  else
    PGPASSWORD="$pg_admin_password" "${psql_cmd[@]}" -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";"
    echo "[ok] Created database: $DB_NAME"
  fi

  PGPASSWORD="$pg_admin_password" "${psql_cmd[@]}" -c "GRANT ALL PRIVILEGES ON DATABASE \"$DB_NAME\" TO \"$DB_USER\";"
}

write_api_config_template() {
  local db_host db_user db_password db_name
  db_host="${1:-}"
  db_user="${2:-}"
  db_password="${3:-}"
  db_name="${4:-}"

  if [[ -z "$db_host" ]]; then
    read -r -p "Postgres host [127.0.0.1]: " db_host
    db_host="${db_host:-127.0.0.1}"
  fi

  if [[ -z "$db_user" ]]; then
    read -r -p "Postgres user [postgres]: " db_user
    db_user="${db_user:-postgres}"
  fi

  if [[ -z "$db_password" ]]; then
    read -r -s -p "Postgres password: " db_password
    echo
  fi

  if [[ -z "$db_name" ]]; then
    read -r -p "Postgres database name: " db_name
  fi

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

update_website_postgres_connection() {
  APPSETTINGS_ENV="$WEBSITE_APPSETTINGS" DB_HOST="$DB_HOST" DB_USER="$DB_USER" DB_PASSWORD="$DB_PASSWORD" DB_NAME="$DB_NAME" node <<'NODE'
const fs = require('fs');

const appSettingsPath = process.env.APPSETTINGS_ENV;
const text = fs.readFileSync(appSettingsPath, 'utf8');
const data = JSON.parse(text);

const host = process.env.DB_HOST;
const user = process.env.DB_USER;
const password = process.env.DB_PASSWORD;
const db = process.env.DB_NAME;

data.Postgres = 'Host=' + host + '; Database=' + db + '; ' + 'Password=' + password + '; Username=' + user + '; Maximum Pool Size=20';

fs.writeFileSync(appSettingsPath, JSON.stringify(data, null, 2) + '\n');
console.log('[ok] Updated Postgres connection string in appsettings.json');
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

echo "Step 0/6: system prerequisites (Linux/WSL + macOS Homebrew helper)"
install_prereqs

if confirm "Create/update PostgreSQL role + database now?" N; then
  configure_postgres_role_and_db
else
  echo "[info] Skipped automated PostgreSQL role/database creation."
fi

echo
echo "Step 1/6: services/api config"
if [[ -f "$API_CONFIG" ]]; then
  echo "[ok] Found $API_CONFIG"
else
  echo "[info] Missing $API_CONFIG"
  if confirm "Create services/api/config.json now?" Y; then
    if ! require_command node; then
      echo "[warn] node is required to write config.json automatically."
    else
      if [[ -n "$DB_HOST" && -n "$DB_USER" && -n "$DB_NAME" ]]; then
        write_api_config_template "$DB_HOST" "$DB_USER" "$DB_PASSWORD" "$DB_NAME"
      else
        write_api_config_template
      fi
    fi
  else
    echo "[warn] Skipping config creation; migrations will fail until config.json is created."
  fi
fi

echo
echo "Step 2/6: services/api dependency install + knex migrations"
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
echo "Step 3/6: services/Roblox/Roblox.Website appsettings"
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

  if [[ -n "$DB_HOST" && -n "$DB_USER" && -n "$DB_NAME" ]] && confirm "Set appsettings Postgres connection from DB values you entered?" Y; then
    update_website_postgres_connection
  fi

  validate_website_values
  echo "[info] Manually verify Urls/BaseUrl, OwnerUserId, Redis, and auth values in appsettings.json"
fi

echo
echo "Step 4/6: services/2016-roblox-main frontend"
echo "[info] See setup guide: $FRONTEND_DIR/docs/get-started.md"
ensure_frontend_config

if require_command npm && confirm "Run npm install in services/2016-roblox-main?" Y; then
  (cd "$FRONTEND_DIR" && npm i)
fi

if [[ -f "$FRONTEND_CONFIG" ]] && confirm "Set frontend apiFormat to http://localhost:5000/apisite/{0}{1}?" Y; then
  set_frontend_api_format
fi

echo
echo "Step 5/6: remaining dependencies"
if require_command npm && confirm "Run npm install in services/admin?" Y; then
  (cd "$ADMIN_DIR" && npm i)
fi

if require_command go && [[ -f "$ASSET_VALIDATION_DIR/go.mod" ]] && confirm "Run go mod download in services/AssetValidationServiceV2?" Y; then
  (cd "$ASSET_VALIDATION_DIR" && go mod download)
fi

echo
echo "Step 6/6: run guidance"
cat <<GUIDE
Use ./run-all.sh to start the local stack with one command.

Manual values still required:
- Database credentials/connection values if you skipped DB prompts.
- appsettings.json OwnerUserId (set this to your own user ID after registering an account).
- Any authorization keys or custom URLs in appsettings.json.

Accessibility after services are running:
- Website:            http://localhost:5000/
- Website admin:      http://localhost:5000/admin/
- Website API proxy:  http://localhost:5000/apisite/
- Website Swagger:    http://localhost:5000/swagger
- Frontend (optional):http://localhost:3000/
- Asset validator:    http://localhost:4300/
GUIDE

echo
echo "Setup helper finished."
