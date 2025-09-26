# pgelog - extended logging by pseudo-autonomous transactions via dblink into log table


## Introduction

The **pgelog** extension enables reliable and non-intrusive logging into a database table using **pseudo-autonomous transactions** via the `dblink` extension. Logs are written in a way that survives even if the calling transaction is rolled back.

To optimize performance, the `dblink` connection is cached using the `pg_variables` extension and reused throughout the session.

> ⚠️ **Note:** Each session may open up to **1 additional connection** (due to `dblink`). Adjust your `max_connections` setting accordingly.
> 

---

## License

The **pgelog** extension available under the [license](LICENSE) similar to
[PostgreSQL](http://www.postgresql.org/about/licence/).

---

## Prerequisites

- **PostgreSQL or PostgresPro 11+**
- Extensions:
  - [`dblink`](https://www.postgresql.org/docs/current/contrib-dblink.html)
  - [`pg_variables`](https://github.com/postgrespro/pg_variables)

- **Passwordless dblink to localhost**

For **pgelog** to work, **regular users must be able to connect to localhost via `dblink` without a password**.

Update `pg_hba.conf`:

```conf
# TYPE  DATABASE  USER  ADDRESS  METHOD
local   all       all            peer
```

Reload configuration:

```sql
SELECT pg_reload_conf();
```

Test dblink():

```sql
SELECT * FROM dblink(
    'host=localhost port=5432 dbname=' || current_database() || ' user=' || current_user,
    $$SELECT 'It works!'$$
) AS t(result text);
```

Should return:

```conf
It works!
```

---

## Installation

Typical installation procedure may look like this:

1. Download and extract:

```bash
$ wget https://github.com/anfiau/pgelog/archive/refs/tags/v1.0.2.tar.gz
$ tar -xzf pgelog-1.0.2.tar.gz
$ cd pgelog-1.0.2
$ chmod +x find-pg_config.sh
```

2. Install for the latest PostgreSQL version detected:

```bash
$ sudo make install
$ make installcheck
```

   Or install for a specific version (for example, set path to pg_config of 11):

```bash
$ sudo make PG_CONFIG=/usr/pgsql-11/bin/pg_config install
$ make PG_CONFIG=/usr/pgsql-11/bin/pg_config installcheck
```

3. Enable in your database:

```sql
CREATE EXTENSION IF NOT EXISTS dblink;
CREATE EXTENSION IF NOT EXISTS pg_variables;
CREATE EXTENSION pgelog;
```

---

## Objects

### Table: pgelog_params

Stores configuration parameters


| Column       | Type     | Description |
|--------------|----------|-------------|
| param_name   | TEXT     | Name of parameter |
| param_value  | TEXT     | Value of parameter |


### Table: pgelog_logs

Main log storage


|Column        |Type          |Description  |
|--------------|--------------|-------------|
| log_stamp    | TIMESTAMP    | Timestamp (clock_timestamp()) |
| log_type     | TEXT         | Log level: FAIL, WARN, INFO, etc. |
| log_func     | TEXT         | Source function or context |
| phase        | TEXT         | Phase label (e.g., 1, 2.a) |
| log_info     | TEXT         | Message body |
| xact_id      | TEXT         | Transaction ID by pg_current_xact_id() or txid_current() |
| sqlstate     | TEXT         | SQLSTATE code |
| sqlerrm      | TEXT         | Error message (SQLERRM) |
| conn_name    | TEXT         | dblink connection name used |


### View: pgelog_vw_logs

Main log storage with timing


| Column       | Type         | Description |
|--------------|--------------|-------------|
| log_stamp    | TIMESTAMP    | Timestamp (clock_timestamp()) |
| log_type     | TEXT         | Log level: FAIL, WARN, INFO, etc. |
| log_func     | TEXT         | Source function or context |
| phase        | TEXT         | Phase label (e.g., 1, 2.a) |
| log_info     | TEXT         | Message body |
| xact_id      | TEXT         | Transaction ID by pg_current_xact_id() or txid_current() |
| time_s       | INTEGER      | Time in seconds since the previous log entry for the same xact_id |
| delta_t      | INTEGER      | Time in seconds since first log entry for the same xact_id (~ time from function call to this phase) |
| sqlstate     | TEXT         | SQLSTATE code |
| sqlerrm      | TEXT         | Error message (SQLERRM) |
| conn_name    | TEXT         | dblink connection name used |

---

## Usage Examples

### Simple

- Write a log entry

```sql
SELECT pgelog_to_log('SQL', 'standalone', 'Test of logging by pgelog', '1');
```

- Read latest entry

```sql
SELECT log_stamp, log_info
FROM pgelog_logs
ORDER BY log_stamp DESC
LIMIT 1;
```

- Result:

|        log_stamp          |         log_info          |
|---------------------------|---------------------------|
| 2025-09-15 10:54:41.907   | Test of logging by pgelog |


### Logging Exception in PL/pgSQL

- Execute PL/pgSQL block raising an exception

```sql
DO $$
DECLARE
  v_Result   FLOAT;
  v_Divisor  INTEGER := 0;
  v_Log_Func TEXT := 'PL/pgSQL block';
  v_Phase    TEXT;
  v_Exc_1    TEXT;
  v_Exc_2    TEXT;
  v_Exc_3    TEXT;
  v_Exc_4    TEXT;
  v_SQLSTATE TEXT;
  v_SQLERRM  TEXT;
BEGIN
 -- 1) First phase
 v_Phase := '1)';
 v_Result := 1.0 / v_Divisor;
 -- 2) Second phase
 v_Phase := '2)';
 PERFORM pgelog_to_log('INFO', v_Log_Func,
   'v_Divisor='||COALESCE(v_Divisor::TEXT,'NULL'), v_Phase);
 -- Catch exceptions
 EXCEPTION
    WHEN OTHERS THEN
       GET STACKED DIAGNOSTICS
           v_Exc_1    = MESSAGE_TEXT
          ,v_Exc_2    = PG_EXCEPTION_DETAIL
          ,v_Exc_3    = PG_EXCEPTION_HINT
          ,v_Exc_4    = PG_EXCEPTION_CONTEXT
          ,v_SQLSTATE = RETURNED_SQLSTATE
       ;
       v_SQLERRM := format(
                           '%s%s%s%s%s'
                           ,COALESCE(NULLIF(v_Exc_1,'')||'; ','')
                           ,COALESCE(NULLIF(v_Exc_2,'')||'; ','')
                           ,COALESCE(NULLIF(v_Exc_3,'')||'; ','')
                           ,COALESCE(NULLIF(v_Exc_4,'')||'; ','')
                           ,COALESCE(NULLIF(SQLERRM::TEXT,'')||'; ','')
                          );
       PERFORM pgelog_to_log('FAIL', v_Log_Func
         ,format(
                 '%s failed for v_Divisor=%s'
                 ,v_Log_Func
                 ,COALESCE(v_Divisor::TEXT,'NULL')
                )
         ,v_Phase, v_SQLERRM, v_SQLSTATE);
	   RAISE EXCEPTION '%', v_SQLERRM
       USING ERRCODE = SQLSTATE;
END $$;
```

- Read latest entry with 'FAIL' log_type

```sql
SELECT L.log_info, L.sqlerrm
FROM   pgelog_logs L
WHERE  L.log_type = 'FAIL'
ORDER BY L.log_stamp DESC
LIMIT 1;
```

- Result:

|log_info               | sqlerrm |
|-----------------------|---------|
|PL/pgSQL block failed for v_Divisor=0|division by zero PL/pgSQL; function inline_code_block line 16 at assignment; division by zero¶  |

---

## Configuration Parameters

Use pgelog_set_param() and pgelog_get_param():

```sql
SELECT pgelog_get_param('pgelog_ttl_minutes'); -- get old value = 1440
SELECT pgelog_set_param('pgelog_ttl_minutes', '2880'); -- set new value = 2880
SELECT pgelog_get_param('pgelog_ttl_minutes'); -- get new value = 2880
```

| Parameter                | Default     | Description |
|--------------------------|-------------|-------------|
| pgelog_port              | '5432'      | Database port |
| pgelog_pgv_transactional | 'y'         | Use pg_variables in transactional mode |
| pgelog_assign_xact_id    | 'n'         | Force xact ID assignment for read-only tx |
| pgelog_is_active         | 'y'         | Global logging toggle |
| pgelog_pgv_package       | 'pgelog'    | pg_variables package name |
| pgelog_ttl_minutes       | '1440'      | Retention time in minutes (default: 1 day) |
| pgelog_log_clean_call    | 'y'         | Log calls to pgelog_clean_log()? |
| pgelog_log_init_call     | 'n'         | Log calls to pgelog_init()? |

> You can store your own custom parameters in pgelog_params by pgelog_set_param() — they persist across backups.

---

## Session-Level Control of Logging

Override global logging settings per session:

- pgelog_enable_locally()   -- Enable logging only in this session
- pgelog_disable_locally()  -- Disable logging only in this session

Example:

```sql
SELECT pgelog_disable_locally(); -- Turn off logging for current session
```

---

## Clean Up Old Logs

Remove logs older than N minutes:

- Delete logs older than 60 minutes:

```sql
SELECT pgelog_clean_log(60);
```

- Or use default TTL:

```sql
SELECT pgelog_clean_log();
```

- Schedule it via cron (for example run daily cleanup at 2:00 AM):

```conf
0 2 * * * psql -U postgres -d mydb -c "SELECT pgelog_clean_log();"
```

---

## Functions

| Function                     | Returns    | Description |
|------------------------------|------------|-------------|
| pgelog_to_log(log_type,log_func,log_info,phase,sqlerrm,sqlstate) | BOOLEAN    | Write a log entry |
| pgelog_init()                | BOOLEAN    | Initialize dblink (auto-called) |
| pgelog_close()               | BOOLEAN    | Close dblink manually |
| pgelog_clean_log(minutes)    | BOOLEAN    | Remove old records |
| pgelog_set_param(name,val)   | VOID       | Set config param |
| pgelog_get_param(name)       | TEXT       | Get config param |
| pgelog_delete_param(name)    | VOID       | Delete config param |
| pgelog_enable() / disable()  | BOOLEAN    | Toggle global logging |
| pgelog_enable_locally() / disable_locally() | BOOLEAN | Toggle session logging |

---

## Exception Handling

All exceptions in **pgelog** functions are caught silently to avoid disrupting calling code. A NOTICE is raised with error details.

This ensures logging never causes unintended rollbacks.

---

## PGXN

This extension is available on [PGXN](https://pgxn.org/dist/pgelog/). Install it with:

```bash
pgxn install pgelog
```

