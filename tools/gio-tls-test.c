/*
 * gio-tls-check: does GIO have a TLS backend, and does it trust anything?
 *
 * Everything on the image that speaks https -- WebKit through libsoup, and any
 * other GIO client -- reaches TLS the same way: g_tls_backend_get_default()
 * looks up an extension point that is empty until a module in
 * /usr/lib/gio/modules registers one. When it is empty the failure surfaces
 * far from its cause, as "TLS support is not available" from libsoup or a
 * blank page in the browser, so this check names it directly.
 *
 * With no arguments it answers the offline half of the question: is a backend
 * registered, and does the default database load the system trust store. That
 * much runs at build time under the cross loader. Given a URL it does the
 * online half -- a real handshake, a real GET, and the status line back.
 */
#include <gio/gio.h>
#include <stdio.h>
#include <string.h>

#define TLS_DEFAULT_PORT 443
#define TLS_TIMEOUT_SECONDS 30
#define STATUS_LINE_MAX 512

static int fail(const char *what, GError *error) {
    fprintf(stderr, "gio-tls-check: %s%s%s\n", what,
            error ? ": " : "", error ? error->message : "");
    if (error) g_error_free(error);
    return 1;
}

/* The protocol version and ciphersuite are the proof that a handshake really
   happened rather than a plaintext connection to port 443. */
static void describe_connection(GIOStream *stream) {
    GTlsConnection *tls = NULL;

    if (G_IS_TLS_CONNECTION(stream))
        tls = G_TLS_CONNECTION(stream);
    else if (G_IS_TCP_WRAPPER_CONNECTION(stream))
        tls = (GTlsConnection *)g_tcp_wrapper_connection_get_base_io_stream(
            G_TCP_WRAPPER_CONNECTION(stream));

    if (!tls || !G_IS_TLS_CONNECTION(tls)) {
        printf("connection: not TLS\n");
        return;
    }

    GEnumClass *versions = g_type_class_ref(G_TYPE_TLS_PROTOCOL_VERSION);
    GEnumValue *version = g_enum_get_value(versions,
                                           g_tls_connection_get_protocol_version(tls));
    char *ciphersuite = g_tls_connection_get_ciphersuite_name(tls);
    printf("protocol: %s\nciphersuite: %s\n",
           version ? version->value_nick : "unknown",
           ciphersuite ? ciphersuite : "unknown");
    g_free(ciphersuite);
    g_type_class_unref(versions);
}

static int fetch(const char *url) {
    GError *error = NULL;
    GUri *uri = g_uri_parse(url, G_URI_FLAGS_NONE, &error);
    if (!uri) return fail("could not parse the URL", error);

    const char *host = g_uri_get_host(uri);
    const char *path = g_uri_get_path(uri);
    if (!host || !*host) return fail("the URL has no host", NULL);
    if (!path || !*path) path = "/";

    GSocketClient *client = g_socket_client_new();
    g_socket_client_set_tls(client, TRUE);
    g_socket_client_set_timeout(client, TLS_TIMEOUT_SECONDS);

    GSocketConnection *connection =
        g_socket_client_connect_to_uri(client, url, TLS_DEFAULT_PORT, NULL, &error);
    if (!connection) return fail("could not connect", error);

    describe_connection(G_IO_STREAM(connection));

    char *request = g_strdup_printf(
        "GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n"
        "User-Agent: gio-tls-check\r\n\r\n", path, host);
    GOutputStream *out = g_io_stream_get_output_stream(G_IO_STREAM(connection));
    gboolean sent = g_output_stream_write_all(out, request, strlen(request),
                                              NULL, NULL, &error);
    g_free(request);
    if (!sent) return fail("could not send the request", error);

    char status[STATUS_LINE_MAX];
    GInputStream *in = g_io_stream_get_input_stream(G_IO_STREAM(connection));
    gssize read = g_input_stream_read(in, status, sizeof status - 1, NULL, &error);
    if (read < 0) return fail("could not read the response", error);
    status[read] = '\0';

    char *end = strpbrk(status, "\r\n");
    if (end) *end = '\0';
    printf("response: %s\n", status);

    g_object_unref(connection);
    g_object_unref(client);
    g_uri_unref(uri);
    return strstr(status, "HTTP/1.") ? 0 : fail("the response is not HTTP", NULL);
}

int main(int argc, char **argv) {
    GTlsBackend *backend = g_tls_backend_get_default();
    if (!backend)
        return fail("gio has no TLS backend; is a module installed in /usr/lib/gio/modules", NULL);
    printf("backend: %s\n", G_OBJECT_TYPE_NAME(backend));

    if (!g_tls_backend_supports_tls(backend))
        return fail("the TLS backend does not support TLS", NULL);

    GTlsDatabase *database = g_tls_backend_get_default_database(backend);
    if (!database)
        return fail("the TLS backend has no default certificate database", NULL);
    printf("database: %s\n", G_OBJECT_TYPE_NAME(database));
    g_object_unref(database);

    if (argc < 2) {
        printf("gio-tls-check: a TLS backend is registered\n");
        return 0;
    }
    return fetch(argv[1]);
}
