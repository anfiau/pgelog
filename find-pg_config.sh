#!/bin/sh
# find-pg_config.sh — looking for the pg_config of latest Postgres

# 1. Trying to find in PATH first
for cmd in pg_config pg_pro_config; do
    if path=$(command -v "$cmd" 2>/dev/null) && [ -x "$path" ]; then
        echo "$path"
        exit 0
    fi
done

# 2. Gather all candidates together
candidates=""

# Postgres Pro: /opt/pgpro/std-13/bin/pg_config, /opt/pgpro/ent-17/bin/pg_config etc
for f in /opt/pgpro/*/bin/pg_config; do
    [ -x "$f" ] && candidates="$candidates $f"
done

# RHEL / CentOS / Alma / Rocky / Postgres Pro RPM
for f in /usr/pgsql-*/bin/pg_config; do
    [ -x "$f" ] && candidates="$candidates $f"
done

# Debian / Ubuntu
for f in /usr/lib/postgresql/*/bin/pg_config; do
    [ -x "$f" ] && candidates="$candidates $f"
done

# macOS: Postgres.app
for f in /Applications/Postgres.app/Contents/Versions/*/bin/pg_config; do
    [ -x "$f" ] && candidates="$candidates $f"
done

# Homebrew (Intel & Apple Silicon)
for f in /opt/homebrew/bin/pg_config /usr/local/bin/pg_config; do
    [ -x "$f" ] && candidates="$candidates $f"
done

# 3. Get the latest candidate if possible
if [ -n "$candidates" ]; then
    # Convert to list, sort by version (-V), get the latest
    printf '%s\n' $candidates | sort -V | tail -n1
    exit 0
fi

# 4. Not found
echo "pg_config_not_found"
exit 1