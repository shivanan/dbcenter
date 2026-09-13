# DB Center

A native macOS database workbench written in SwiftUI and AppKit. Requires macOS 14 or newer and Xcode 16 / Swift 6 to build. No Electron, web views, CLI query execution, or simulated results.

## Run

```sh
./scripts/build-app.sh
open "dist/DB Center.app"
```

The build creates an ad-hoc signed `.app` with a native icon. You can also open `Package.swift` in Xcode and run the DBCenter executable scheme. The app bundle is recommended for normal use, including Keychain identity and HTTP InfluxDB connections.

This is a local developer build, not a notarized, self-contained distribution. The native driver libraries must be installed on the Mac that runs it.

## Native drivers

```sh
brew install libpq mongo-c-driver hiredis unixodbc
```

SQL Server also requires Microsoft's **ODBC Driver 18 for SQL Server**. Follow the [official macOS installation instructions](https://learn.microsoft.com/en-us/sql/connect/odbc/linux-mac/install-microsoft-odbc-driver-sql-server-macos). Its driver name must be registered with unixODBC as `ODBC Driver 18 for SQL Server`.

Drivers load at runtime from Apple Silicon and Intel Homebrew locations. Missing drivers produce an installation message without preventing other engines from working.

| Engine | Implementation | Editor and results |
| --- | --- | --- |
| Postgres | Native libpq | SQL, tabular results, NULL handling, affected row counts |
| SQL Server | unixODBC + Microsoft ODBC 18 | T-SQL, tabular results, affected row counts |
| MongoDB | Native MongoDB C driver (1.x / 2.x) | JSON database commands, document grid, full Extended JSON reply |
| Redis | Native hiredis 1.x | One command with quoted arguments, indexed scalar/array results |
| InfluxDB | Foundation URLSession, InfluxDB 2 HTTP API | Flux, annotated CSV grid and raw response |

Driver API references: [libpq](https://www.postgresql.org/docs/current/libpq.html), [MongoDB commands](https://mongoc.org/libmongoc/current/mongoc_client_command_simple.html), [hiredis](https://redis.io/docs/latest/develop/clients/hiredis/issue-commands/), [InfluxDB query API](https://docs.influxdata.com/influxdb/v2/api/query/).

## Workflow

1. Choose **New Connection** (`⇧⌘N`) or an engine on the welcome screen.
2. Enter a name, host, port, initial database, and credentials. InfluxDB uses an organization and token; the bucket can be discovered on connect.
3. Save and connect. Registered servers appear together in the sidebar with engine icons and connection indicators.
4. Select any server to connect. Switching servers keeps each session, editor draft, result, and in-memory query history alive.
5. Use the native database combo box to select a discovered database or type a database name and press Return. The inspector lists tables/views, collections, a first scan of Redis keys, or Influx measurements.
6. Run the editor contents with **⌘Return**. Results support native row selection, **⌘C**, column resizing, and CSV export. MongoDB replies and Influx CSV also have a Raw view.
7. Use the sidebar context menu to edit, disconnect, or remove a registration. Removing a registration never deletes a database.

Passwords and tokens are stored in macOS Keychain. Connection metadata is written atomically to `~/Library/Application Support/DBCenter/servers.json`. Query text and results remain in memory and are not persisted across app launches. Nothing is sent to a telemetry service.

TLS is enabled by default for Postgres, SQL Server, MongoDB, and InfluxDB, with certificate validation. Turn it off explicitly for local servers that do not use TLS. Redis currently supports TCP only. Host fields take a hostname or IP address, not a URI. MongoDB SRV URIs, custom CA selection, client certificates, SSH tunnels, and Windows integrated authentication are not implemented.

## Query examples

Postgres:

```sql
SELECT current_database(), version();
```

SQL Server:

```sql
SELECT TOP (100) * FROM dbo.your_table;
```

MongoDB accepts database commands, not JavaScript/mongosh expressions:

```json
{"find":"people","filter":{"active":true},"limit":100}
```

Redis accepts one command with quoted strings and escapes:

```text
GET "cache:user:123"
```

InfluxDB 2:

```flux
from(bucket: "metrics")
  |> range(start: -1h)
  |> limit(n: 100)
```

## Current boundaries

- InfluxDB support targets **2.x/Flux**. InfluxDB 1/InfluxQL and 3/SQL are not implemented. HTTP requests are used because this engine exposes an HTTP query API, rather than a native C client.
- Queries go directly to the drivers and can modify data. There is no implicit read-only mode or transaction wrapper.
- Results display at most 10,000 rows and mark truncation. This is a display cap, not a server-side execution or memory limit; narrow large queries explicitly. Postgres libpq buffers results before display.
- MongoDB displays the command's first returned batch and the full reply, including cursor ID. A nonzero cursor is marked partial; issue a `getMore` command manually for subsequent batches. Collection discovery uses a batch of up to 10,000 names.
- Redis key discovery uses one nonblocking `SCAN` iteration; it is not a full key inventory. Run subsequent `SCAN` commands to continue. Redis Cluster, TLS, Pub/Sub, MONITOR, and binary payload editing are not supported. Use the database picker for `SELECT` and settings for authentication; session-changing commands are blocked in the editor.
- SQL Server displays the first result set; Postgres displays libpq's final result for a multi-statement batch. Multi-result navigation and streaming/COPY modes are not implemented.
- Switching databases opens a new native connection for SQL engines and Redis; switching sidebar servers preserves existing sessions. Uncommitted SQL transactions are rolled back when their connection closes.
- Native driver operations run on a dedicated serial queue per server. Connection timeouts are 10 seconds; query/socket timeouts are generally 30 seconds. There is no in-flight Cancel button.
- Metadata discovery is permission-dependent. You can type a known database in the combo box if enumeration fails.

## Verification

```sh
swift test
```

Parser tests cover quoted Redis arguments, multiline/CRLF Influx CSV and schema changes, MongoDB nested values and cursor notices, connection string escaping, and credential-free JSON persistence. Integration tests skip unless explicitly enabled.

With local Homebrew `postgresql@18`, `mongodb-community`, `redis`, and the client libraries installed:

```sh
./scripts/test-integration.sh
```

The script starts disposable servers in temporary directories, binds only to loopback on dedicated ports, and stops its processes on exit. It does not use or alter existing database data directories. Logs remain in the printed temporary test directories.

Verified in this workspace:

- Debug and release compilation and `.app` packaging.
- All 9 automated tests pass.
- Live Postgres: queries, Unicode, NULL, errors, session persistence, database/object discovery.
- Live MongoDB: insert/find commands, Unicode, malformed JSON, collection/database discovery.
- Live Redis: commands, quoted values, errors, database isolation, database/key discovery.
- InfluxDB: authentication/request/CSV contract against a local HTTP fixture, **not a live InfluxDB server**.
- SQL Server: ODBC driver loads and returns a connection diagnostic; **live SQL Server queries are not verified**.
- Native visual inspection was blocked by missing macOS Computer Use permission; layout and interactive GUI behavior remain to be checked manually.

## Structure

- `Sources/DBCenter/DBCenterApp.swift`: native window, sidebar, inspector, connection sheet.
- `Sources/DBCenter/NativeViews.swift`: NSTextView, NSTableView, NSComboBox bridges.
- `Sources/DBCenter/AppStore.swift`: saved registrations and per-server workspace lifecycle.
- `Sources/DBCenter/DatabaseDriver.swift`: driver dispatch, metadata, HTTP API.
- `Sources/DBCenter/Models.swift`: engine metadata, Keychain, result parsers.
- `Sources/CDBDrivers/Drivers.c`: small runtime-loaded C driver bridge.
