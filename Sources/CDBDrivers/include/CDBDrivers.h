#ifndef CDBDRIVERS_H
#define CDBDRIVERS_H
#include <stddef.h>
typedef struct DBConnection DBConnection;
typedef struct { int columns; int rows; char **names; char **cells; char *json; char *error; long long affected; int truncated; } DBResult;
// kind: 0 libpq, 1 unixODBC, 2 libmongoc, 3 hiredis. Passwords never retained by this wrapper.
DBConnection *db_open(int kind, const char *connection, const char *host, int port, char **error);
DBConnection *db_open_tunneled(int kind, const char *connection, const char *host, int port, const char *tls_host, char **error);
DBResult *db_query(DBConnection *, const char *database, const char *query, int argc, const char **argv);
void db_close(DBConnection *);
void db_result_free(DBResult *);
void db_string_free(char *);
// Uses macOS libcurl to preserve the original HTTP Host and TLS SNI through a local forward.
char *db_http_tunnel(const char *url, int local_port, const char *token, const char *body, size_t body_length, size_t *length, long *status, char **error);
#endif
