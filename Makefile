# Look for pg_config if PG_CONFIG is not defined yet
ifndef PG_CONFIG
    PG_CONFIG := $(shell ./find-pg_config.sh)
endif

# Check if pg_config found?
ifeq ($(PG_CONFIG),pg_config_not_found)
    $(error pg_config not found. Please install PostgreSQL development packages or set PG_CONFIG manually, e.g.: make PG_CONFIG=/path/to/pg_config)
endif

# Check if pg_config exist?
ifneq ($(wildcard $(PG_CONFIG)),)
    # OK
else
    $(error PG_CONFIG points to non-existent file: $(PG_CONFIG))
endif

# pgelog definition
REGRESS = pgelog
EXTENSION = pgelog
DATA = pgelog--1.0.2.sql

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
