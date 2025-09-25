#!/bin/sh
# find-pg_config.sh — надёжный поиск самой свежей версии pg_config

# 1. Пробуем PATH (самый приоритетный способ)
for cmd in pg_config pg_pro_config; do
    if path=$(command -v "$cmd" 2>/dev/null) && [ -x "$path" ]; then
        echo "$path"
        exit 0
    fi
done

# 2. Собираем все кандидаты из известных путей
candidates=""

# Postgres Pro: /opt/pgpro/std-13/bin/pg_config, /opt/pgpro/ent-17/bin/pg_config и т.д.
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

# 3. Если есть кандидаты — выбираем самую свежую версию
if [ -n "$candidates" ]; then
    # Преобразуем в список, сортируем по версии (-V), берём последнюю
    printf '%s\n' $candidates | sort -V | tail -n1
    exit 0
fi

# 4. Не найдено
echo "pg_config_not_found"
exit 1