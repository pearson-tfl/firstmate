#!/usr/bin/env bash
# fm-secondmate-seat-plugins.sh <config-dir> <secondmate-id> <settings-file>
# Optional Claude secondmate launch delta. config/secondmate-seat-plugins holds
# one absolute path to a JSON seat map; no file means no change. Selects only
# seats["fm-<secondmate-id>"]. An absent entry is inert. A selected entry has
# {"launch":{"plugin_dirs":["/absolute/plugin", "~/plugin"],
#            "settings":{"env":{"NAME":"value"}}}}.
# Merges that env into the generated per-launch settings (preserving hooks and
# other settings), then prints shell-quoted --plugin-dir arguments. Reads data
# only, never imports an external launcher or writes shared Claude settings.
# Malformed/unreadable configured input refuses the launch. Called only for
# standard Claude secondmate commands, on fresh launches and exact resumes.
set -u
[ "$#" -eq 3 ] || { echo "usage: $0 <config-dir> <secondmate-id> <settings-file>" >&2; exit 2; }
selector="$1/secondmate-seat-plugins"
[ -e "$selector" ] || [ -L "$selector" ] || exit 0
node - "$selector" "$2" "$3" <<'JS'
const fs = require('fs');
const path = require('path');
const os = require('os');
const [selector, id, settingsFile] = process.argv.slice(2);
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const only = (value, keys) => object(value) && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
const quote = value => "'" + value.replace(/'/g, "'\\''") + "'";
try {
  const file = fs.readFileSync(selector, 'utf8').trim();
  if (!path.isAbsolute(file) || /[\r\n\0]/.test(file)) throw new Error('expected one absolute seat-map path');
  const data = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (!object(data) || !object(data.seats)) throw new Error('seat map must contain a seats object');
  const seat = `fm-${id}`;
  if (!Object.hasOwn(data.seats, seat)) process.exit(0);
  const delta = data.seats[seat];
  if (!only(delta, ['launch']) || !only(delta.launch, ['plugin_dirs', 'settings']) ||
      !only(delta.launch.settings, ['env']) || !object(delta.launch.settings.env)) {
    throw new Error(`${seat}: expected only launch.plugin_dirs and launch.settings.env`);
  }
  const {plugin_dirs: dirs, settings: {env}} = delta.launch;
  if (!Array.isArray(dirs) || dirs.some(dir => typeof dir !== 'string' ||
      /[\r\n\0]/.test(dir) || !(path.isAbsolute(dir) || dir.startsWith('~/')))) {
    throw new Error(`${seat}: plugin_dirs must be absolute or ~/ paths`);
  }
  if (Object.values(env).some(value => typeof value !== 'string' || value.includes('\0'))) {
    throw new Error(`${seat}: settings.env values must be strings without NUL`);
  }
  const settings = JSON.parse(fs.readFileSync(settingsFile, 'utf8'));
  settings.env = {...settings.env, ...env};
  const args = [...new Set(dirs.map(dir => dir.startsWith('~/') ? path.join(os.homedir(), dir.slice(2)) : dir))]
    .map(dir => `--plugin-dir ${quote(dir)} `).join('');
  fs.writeFileSync(settingsFile, JSON.stringify(settings) + '\n');
  process.stdout.write(args);
} catch (error) {
  console.error(`secondmate seat plugins (${selector}): ${error.message}`);
  process.exit(1);
}
JS
