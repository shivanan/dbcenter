#include "CDBDrivers.h"
#include <curl/curl.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static pthread_once_t once = PTHREAD_ONCE_INIT;
static CURLcode initialized;
static void initialize(void) { initialized = curl_global_init(CURL_GLOBAL_DEFAULT); }
typedef struct { char *bytes; size_t length; } Buffer;
static size_t receive(char *bytes, size_t size, size_t count, void *context) {
    Buffer *buffer = context;
    if (size && count > SIZE_MAX / size) return 0;
    size_t length = size * count;
    if (length > SIZE_MAX - buffer->length - 1) return 0;
    char *new_bytes = realloc(buffer->bytes, buffer->length + length + 1);
    if (!new_bytes) return 0;
    buffer->bytes = new_bytes;
    memcpy(buffer->bytes + buffer->length, bytes, length);
    buffer->length += length; buffer->bytes[buffer->length] = 0;
    return length;
}
char *db_http_tunnel(const char *url, int local_port, const char *token, const char *body, size_t body_length, size_t *length, long *status, char **error) {
    pthread_once(&once, initialize);
    CURL *curl = initialized == CURLE_OK ? curl_easy_init() : NULL;
    if (!curl) { *error = strdup("Cannot initialize the tunneled HTTP client."); return NULL; }
    Buffer buffer = {0};
    char route[64], diagnostic[CURL_ERROR_SIZE] = {0};
    snprintf(route, sizeof(route), "::127.0.0.1:%d", local_port);
    struct curl_slist *routes = curl_slist_append(NULL, route), *headers = NULL;
    char *authorization = NULL;
    if (asprintf(&authorization, "Authorization: Token %s", token) < 0 || !routes) {
        *error = strdup("Cannot allocate HTTP request."); goto cleanup;
    }
    headers = curl_slist_append(headers, authorization);
    headers = curl_slist_append(headers, "Content-Type: application/vnd.flux");
    headers = curl_slist_append(headers, body ? "Accept: application/csv" : "Accept: application/json");
    CURLcode code;
#define SET(option, value) if ((code = curl_easy_setopt(curl, option, value)) != CURLE_OK) { *error = strdup(curl_easy_strerror(code)); goto cleanup; }
    SET(CURLOPT_URL, url);
    SET(CURLOPT_CONNECT_TO, routes);
    SET(CURLOPT_PROXY, "");
    SET(CURLOPT_FOLLOWLOCATION, 0L);
    SET(CURLOPT_PROTOCOLS_STR, "http,https");
    SET(CURLOPT_SSL_VERIFYPEER, 1L);
    SET(CURLOPT_SSL_VERIFYHOST, 2L);
    SET(CURLOPT_CONNECTTIMEOUT, 10L);
    SET(CURLOPT_TIMEOUT, 30L);
    SET(CURLOPT_NOSIGNAL, 1L);
    SET(CURLOPT_HTTPHEADER, headers);
    SET(CURLOPT_WRITEFUNCTION, receive);
    SET(CURLOPT_WRITEDATA, &buffer);
    SET(CURLOPT_ERRORBUFFER, diagnostic);
    if (body) { SET(CURLOPT_POSTFIELDS, body); SET(CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)body_length); }
    code = curl_easy_perform(curl);
    if (code != CURLE_OK) { *error = strdup(diagnostic[0] ? diagnostic : curl_easy_strerror(code)); goto cleanup; }
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, status);
    *length = buffer.length;
    if (!buffer.bytes) buffer.bytes = strdup("");
cleanup:
    curl_easy_cleanup(curl); curl_slist_free_all(routes); curl_slist_free_all(headers); free(authorization);
    if (*error) { free(buffer.bytes); return NULL; }
    return buffer.bytes;
}
