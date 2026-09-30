# DB Center

A native macOS database workbench written in SwiftUI and AppKit. Requires macOS 14 or newer and Xcode 16 / Swift 6 to build. No Electron, web views, CLI query execution, or simulated results.

## Features

- One sidebar for saved Postgres, SQL Server, MongoDB, Redis, and InfluxDB connections, with independent query workspaces.
- Native query editor with syntax highlighting and selection-only execution.
- Database inspector with 50-record previews and structure/details sheets.
- Result grids with individual-cell copying, keyboard navigation, and CSV/JSON export.
- Expandable AI query generation using database schema context, with global OpenAI key/model settings.
- Optional SSH tunnels with password or private-key authentication, random local ports, and automatic cleanup.
- macOS Keychain credentials, native menus, and documented keyboard shortcuts.

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
| InfluxDB | Foundation URLSession / system libcurl for SSH, InfluxDB 2 HTTP API | Flux, annotated CSV grid and raw response |

Driver API references: [libpq](https://www.postgresql.org/docs/current/libpq.html), [MongoDB commands](https://mongoc.org/libmongoc/current/mongoc_client_command_simple.html), [hiredis](https://redis.io/docs/latest/develop/clients/hiredis/issue-commands/), [InfluxDB query API](https://docs.influxdata.com/influxdb/v2/api/query/).

## Workflow

1. Choose **New Connection** (`⇧⌘N`) or an engine on the welcome screen.
2. Enter a name, host, port, initial database, and credentials. InfluxDB uses an organization and token; the bucket can be discovered on connect.
3. Save and connect. Registered servers appear together in the sidebar with engine icons and connection indicators.
4. Select any server to connect. Switching servers keeps each session, editor draft, result, and in-memory query history alive.
5. Use the native database combo box to select a discovered database or type a database name and press Return. The inspector lists tables/views, collections, a first scan of Redis keys, or Influx measurements.
6. Run with **⌘Return** or the toolbar button. Selected text runs on its own (**Run Selection**); with no selection, the entire editor runs. Whitespace-only selections run nothing. History records the executed text.
7. Use the sidebar context menu to edit, disconnect, or remove a registration. Removing a registration never deletes a database.

Click a result cell and press **⌘C** to copy its complete value without headers. Arrow keys move between cells. Click a row number or use Shift/Command-click to select rows; **⌘A** selects all rows. The grid supports resizable columns and CSV/JSON export. NULL cells copy as `NULL`; empty cells copy as an empty string. MongoDB replies and Influx CSV also offer a Raw view.

Passwords and tokens are stored in macOS Keychain. Connection metadata is written atomically to `~/Library/Application Support/DBCenter/servers.json`. Query text and results remain in memory and are not persisted across app launches. Nothing is sent to a telemetry service.

TLS is enabled by default for Postgres, SQL Server, MongoDB, and InfluxDB, with certificate validation. Turn it off explicitly for local servers that do not use TLS. Redis currently supports TCP only. Host fields take a hostname or IP address, not a URI. MongoDB SRV URIs, custom CA selection, client certificates, and Windows integrated authentication are not implemented.

## SSH tunnels

In **New Connection** or **Edit Connection**, enable **SSH tunnel** and enter the SSH host, port (default 22), and username. Choose **Password** or **SSH key file**. The native file picker can show hidden files such as those in `~/.ssh`; encrypted keys accept an optional passphrase.

Keep the database's **Host** and **Port** set to the destination reachable **from the SSH server**. For example, use SSH host `bastion.example.com` and database host `127.0.0.1:5432` when Postgres runs on that SSH server, or `postgres.internal:5432` when it runs elsewhere on the private network. Enter host and port in their separate fields.

DB Center starts macOS's built-in `/usr/bin/ssh`, authenticates, and forwards an available random port on **127.0.0.1 only** to the configured database host/port. Each workspace owns its tunnel. Switching sidebar servers preserves it; switching databases reuses it. Disconnecting, editing/removing the connection, failed initial database connection, or normal application termination closes the tunnel. If SSH drops, reconnect explicitly; requests do not fall back to a direct database connection.

SSH passwords/passphrases use separate Keychain items (`com.dbcenter.ssh`). The app itself serves as OpenSSH's askpass helper: only the credential UUID, never the secret, is passed in the environment. Key paths and non-secret SSH settings are saved with the registration. Private keys are read from their selected location, not copied. Passwords/passphrases containing line breaks are unsupported.

OpenSSH automatically remembers previously unknown host keys in `~/.ssh/known_hosts` and rejects changed keys (`StrictHostKeyChecking=accept-new`). Preload a verified host key there if first-use trust is unsuitable. DB Center ignores `~/.ssh/config`, uses the supplied password or key rather than an SSH agent, and does not support jump-host chains, interactive MFA, or agent forwarding. The SSH account must permit local TCP forwarding.

**TLS remains a separate database setting.** Postgres and SQL Server retain certificate checks against the configured database hostname. MongoDB uses a custom native stream with the original TLS hostname and a direct connection to the selected node; replica-set discovery cannot route outside the tunnel. Tunneled InfluxDB uses macOS's native libcurl API to preserve HTTP Host, TLS SNI, and certificate verification while connecting to the local port. HTTP redirects and proxies are disabled for these tunneled requests. Redis remains TCP-only at the database layer; its connection to the SSH host is encrypted by SSH.

Implementation references: [OpenSSH forwarding and authentication](https://man.openbsd.org/ssh), [MongoDB stream initiators](https://mongoc.org/libmongoc/current/mongoc_client_set_stream_initiator.html), [ODBC certificate hostnames](https://learn.microsoft.com/en-us/sql/connect/odbc/linux-mac/connection-string-keywords-and-data-source-names-dsns), [libcurl connection routing and TLS identity](https://curl.se/libcurl/c/CURLOPT_CONNECT_TO.html).

## AI query generation

Open **DB Center → Settings…** (`⌘,`) to configure OpenAI for every workspace:

1. Enter your OpenAI API key. It is saved in a separate macOS Keychain item (`com.dbcenter.openai`), never in connection JSON or UserDefaults.
2. Click **Load Available Models**, then select a model that supports text generation with the Responses API. You can also type a model ID directly. The list returned by the API may include non-text models; no model is silently substituted.
3. Click **Save**. Clearing the key and saving removes the stored key. The selected model and cached model list are saved in app preferences.

In a connected workspace, click the small **AI** button beside **Run Query**, describe what you want, and click **Generate**. Generation reads the selected database's schema and populates the main editor with query/code for its engine. It does **not** run the generated query. A **Restore Previous Query** button lets you recover the replaced draft. If you edit the query while generation is running, the generated code waits behind **Insert Generated Query**, preserving your newer edits. Cancel stops the OpenAI request; switching databases, disconnecting, or leaving the workspace cancels pending generation. A native database metadata operation already in progress may finish before cancellation takes effect.

Context sent to OpenAI includes your prompt, engine, database name, and:

- **Postgres / SQL Server:** visible tables/views and column names from the catalog.
- **MongoDB:** collection names and top-level field names inferred from up to 20 documents per collection. Projection/grouping happens inside MongoDB so only field names are returned, not document values. Fields absent from this sample may be missing.
- **Redis:** key names from the initial SCAN iteration and their types. This is not a complete key inventory.
- **InfluxDB:** measurement names and field/tag names observed in the last 30 days.

Record values, database passwords, hostnames, usernames, and existing editor text are not included in the AI request. Schema names themselves may be sensitive; the AI panel describes what is sent before generation. Catalog query errors stop generation. Tables whose column metadata is unavailable are explicitly marked in the context. Context is limited to 200 KB, prompts to 10 KB, and non-SQL discovery to 200 objects. SQL column discovery must fit the driver's 10,000-row metadata limit. Larger schemas report an error instead of being silently truncated.

The client uses Foundation URLSession with an ephemeral, cookie-free session and the official [Responses API text-generation format](https://developers.openai.com/api/docs/guides/text). Requests set `store: false`, have a 120-second timeout, and do not use model tool execution. Model discovery uses the [Models API](https://developers.openai.com/api/reference/resources/models/methods/list). Incomplete responses, refusals, missing configuration, authentication failures, and rate-limit errors are shown in the panel without replacing the editor. OpenAI API usage requires your own API account/key and may incur usage charges.

API behavior is tested with a local URLProtocol fixture; live generation has not been verified with a real OpenAI key. SQL and MongoDB schema extraction is covered by live disposable database tests, including checks that record values do not appear in the transmitted context.

## Inspector object actions

Each table, view, collection, key, or measurement has two buttons in the right inspector:

- **Play** executes a read-only preview and shows its results in the main grid. Your editor draft and selection are preserved; the generated query is available in query history. SQL uses `LIMIT 50` (Postgres) or `TOP (50)` (SQL Server). MongoDB requests one batch of at most 50 documents. These previews use the database's default order; no ordering is guaranteed without an explicit sort.
- **Info** opens a native details sheet without replacing your query results. SQL tables/views show column order, names, types, lengths/precision, nullability, and defaults. MongoDB shows collection type, options, and validation metadata. Redis shows key type and expiration. InfluxDB shows field and tag keys from the last 30 days.

InfluxDB previews use the last 30 days and a global 50-row limit. Redis uses a command appropriate to the key type (GET, LRANGE, ZRANGE, SSCAN, HSCAN, or XRANGE), with at most 50 displayed rows; sets/hashes use an initial scan, so results can be partial. Object actions are disabled while disconnected or another operation is running. Names are escaped for each engine, with SQL schema and table names retained separately so names containing dots work correctly.

Metadata depends on database permissions and object existence; errors are shown in the details sheet with a retry button. MongoDB metadata comes from [listCollections](https://www.mongodb.com/docs/manual/reference/command/listCollections/); Influx schema details use its [schema functions](https://docs.influxdata.com/influxdb/cloud/query-data/flux/explore-schema/).

## Keyboard shortcuts

Focus commands are available in the macOS **Navigate** menu and in control tooltips. **⌥** is Option; **⌘** is Command.

| Shortcut | Action |
| --- | --- |
| **⌥⌘1** | Focus the database selector and select its text. Type a name and press Return, or use the native dropdown's arrow keys. |
| **⌥⌘2** | Focus the query editor, preserving its insertion point and selection. |
| **⌥⌘3** | Focus the inspector's table/object search and select its text. Opens the inspector if hidden. This filters table, collection, key, or measurement names. |
| **⌥⌘4** | Focus the result grid. Switches Raw to Grid and selects the first cell if none is selected. Arrow keys then move between cells; ⌘C copies the selected value. |
| **⌘Return** | Run selected editor text, or the entire query when nothing is selected. |
| **⇧⌘R** | Refresh database objects. |
| **⇧⌘N** | Add a connection. |
| **⌘,** | Open global Settings, including the OpenAI API key and model. |
| **⌘C** | Copy the selected result cell, or selected rows in row-selection mode. |
| **⌘A** | Select all rows when the result grid has focus. |

Focus commands apply to the active server workspace and are disabled while editing a connection. Database focus is available when connected and idle; result-grid focus requires a tabular result and is unavailable during a query or an error. The table search text is retained when the inspector is hidden and reopened.

## Syntax highlighting

The native query editor colors keywords/commands, strings, numbers, comments, and quoted identifiers or JSON keys according to the selected server engine:

- Postgres and SQL Server: SQL keywords, quoted strings/identifiers, line comments, nested block comments; Postgres also supports dollar-quoted strings.
- MongoDB: JSON keys, strings, numbers, booleans, and null.
- Redis: command names and quoted/numeric arguments.
- InfluxDB 2: Flux keywords/common functions, strings, numbers, and line comments.

Colors use macOS system colors. Highlighting runs after a short typing debounce, with tokenization off the main thread. It applies temporary layout attributes, preserving plain-text query contents, cursor selection, and undo. This is lexical highlighting, not syntax validation or autocomplete. Queries larger than 250,000 UTF-16 code units remain plain text to keep the editor responsive; query execution is unaffected.

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

## Export formats

The Results export menu offers **Export as CSV…** and **Export as JSON…**, each using the native save dialog. Both export the currently displayed result rows. JSON contains `columns`, positional `rows`, `affectedRows`, and `truncated`. This preserves column order and duplicate column names. Cell values remain strings as returned by the result model, with database NULL values encoded as JSON `null`; nested MongoDB values remain their displayed JSON strings.

## Current boundaries

- InfluxDB support targets **2.x/Flux**. InfluxDB 1/InfluxQL and 3/SQL are not implemented. HTTP requests are used because this engine exposes an HTTP query API, rather than a native C client.
- Queries go directly to the drivers and can modify data. There is no implicit read-only mode or transaction wrapper.
- Results display at most 10,000 rows and mark truncation. This is a display cap, not a server-side execution or memory limit; narrow large queries explicitly. Postgres libpq buffers results before display.
- MongoDB displays the command's first returned batch and the full reply, including cursor ID. A nonzero cursor is marked partial; issue a `getMore` command manually for subsequent batches. Collection discovery uses a batch of up to 10,000 names.
- Redis key discovery uses one nonblocking `SCAN` iteration; it is not a full key inventory. Run subsequent `SCAN` commands to continue. Redis Cluster, TLS, Pub/Sub, MONITOR, and binary payload editing are not supported. Use the database picker for `SELECT` and settings for authentication; session-changing commands are blocked in the editor.
- SQL Server displays the first result set; Postgres displays libpq's final result for a multi-statement batch. Multi-result navigation and streaming/COPY modes are not implemented.
- Switching databases opens a new native connection for SQL engines and Redis; switching sidebar servers preserves existing sessions. Uncommitted SQL transactions are rolled back when their connection closes.
- Native driver operations run on a dedicated serial queue per server. Connection timeouts are 10 seconds; query/socket timeouts are generally 30 seconds. Database query execution has no in-flight Cancel button; the AI panel has its own generation cancellation.
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

To include real SSH authentication and forwarding tests, install the test-only Python dependency in a virtual environment and run:

```sh
python3 -m venv /tmp/dbcenter-ssh-venv
/tmp/dbcenter-ssh-venv/bin/pip install paramiko
SSH_TEST_PYTHON=/tmp/dbcenter-ssh-venv/bin/python3 ./scripts/test-ssh-integration.sh
```

This adds a disposable loopback SSH fixture with generated keys, a test password, and isolated known-hosts files. It does not enable macOS Remote Login or authenticate system users. Password/key-passphrase tests use a fixture askpass helper; macOS Keychain prompts in the packaged app still need interactive verification.

The script starts disposable servers in temporary directories, binds only to loopback on dedicated ports, and stops its processes on exit. It does not use or alter existing database data directories. Logs remain in temporary `dbcenter-tests.*` directories for diagnosis.

Verified in this workspace:

- Debug and release compilation and `.app` packaging.
- All 48 automated tests passed in the latest full integration run, including object previews/details, name escaping, exports, cell copying, focus routing, highlighting, selection-only execution, and AI request/schema handling.
- SSH: password and encrypted/unencrypted key authentication, wrong-password and changed-host-key rejection, simultaneous tunnels, database switching, failure/disconnect cleanup, and Postgres/MongoDB/Redis/Influx fixture queries through a hostname resolved only by the SSH fixture. Live tunneled SQL Server and database TLS handshakes have not been integration-tested.
- Live Postgres: queries, Unicode, NULL, errors, session persistence, database/object discovery.
- Live MongoDB: insert/find commands, Unicode, malformed JSON, collection/database discovery.
- Live Redis: commands, quoted values, errors, database isolation, database/key discovery.
- InfluxDB: authentication/request/CSV contract against a local HTTP fixture, **not a live InfluxDB server**.
- OpenAI: request/response handling and model discovery use a URLProtocol fixture; **live generation has not been verified with a real API key**. Live Postgres/MongoDB tests verify schema names and exclusion of record values.
- SQL Server: ODBC driver loads and returns a connection diagnostic; **live SQL Server queries are not verified**.
- Native visual inspection was blocked by missing macOS Computer Use permission; layout and interactive GUI behavior remain to be checked manually.

## Structure

- `Sources/DBCenter/DBCenterApp.swift`: native window, sidebar, inspector, connection sheet.
- `Sources/DBCenter/NativeViews.swift`: NSTextView, NSTableView, NSComboBox bridges.
- `Sources/DBCenter/AppStore.swift`: saved registrations and per-server workspace lifecycle.
- `Sources/DBCenter/DatabaseDriver.swift`: driver dispatch, metadata, HTTP API.
- `Sources/DBCenter/SSHTunnel.swift`: OpenSSH lifecycle, configuration, and Keychain askpass entry point.
- `Sources/CDBDrivers/HTTP.c`: system libcurl requests through SSH with the original TLS identity.
- `Sources/DBCenter/Models.swift`: engine metadata, database Keychain credentials, result parsers.
- `Sources/DBCenter/QueryExecution.swift` and `SyntaxHighlighter.swift`: selection extraction and engine-specific highlighting.
- `Sources/DBCenter/WorkspaceFocus.swift`: native focus routing and keyboard commands.
- `Sources/DBCenter/ResultExport.swift`: CSV and JSON serialization.
- `Sources/DBCenter/ObjectActions.swift` and `ObjectDetailsView.swift`: object discovery, previews, and metadata sheets.
- `Sources/DBCenter/AIQueryPanel.swift` and `AISettings.swift`: AI prompt UI, global model preferences, and OpenAI Keychain storage.
- `Sources/DBCenter/AISchema.swift` and `OpenAIClient.swift`: schema-only context collection and OpenAI HTTP requests.
- `Tests/DBCenterTests/`: parser, UI behavior, export, API fixture, and opt-in database integration tests.
- `Sources/CDBDrivers/Drivers.c`: small runtime-loaded C driver bridge.
