#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <linux/if.h>

#include "m3u.h"
#include "rtp2httpd.h"
#include "service.h"
#include "configuration.h"
#include "http.h"
#include "http_fetch.h"
#include "epg.h"

#define MAX_M3U_LINE 4096
#define MAX_SERVICE_NAME 256
#define MAX_URL_LENGTH 2048
#define MAX_M3U_CONTENT (10 * 1024 * 1024) /* 10MB max */

/* Structure to store parsed EXTINF data */
struct m3u_extinf
{
    char name[MAX_SERVICE_NAME];
    char group_title[MAX_SERVICE_NAME];
    char catchup_source[MAX_URL_LENGTH];
    int has_catchup;
};

/* Static buffer for transformed M3U playlist */
/* Single unified buffer, with marker to track inline content end */
static char *transformed_m3u = NULL;
static size_t transformed_m3u_size = 0;
static size_t transformed_m3u_used = 0;
static size_t transformed_m3u_inline_end = 0; /* Marks end of inline content */

static int transformed_m3u_has_header = 0;

/* Fetch M3U content from URL (supports file://, http://, https://)
 * Returns: malloc'd string containing content (caller must free), or NULL on error
 */
char *m3u_fetch_url(const char *url)
{
    FILE *fp;
    char *content = NULL;
    long file_size;
    size_t read_size;
    size_t fetch_size;

    /* Handle HTTP(S) URLs using http_fetch_sync */
    if (strncmp(url, "http://", 7) == 0 || strncmp(url, "https://", 8) == 0)
    {
        content = http_fetch_sync(url, &fetch_size);
        if (!content)
        {
            return NULL;
        }

        /* Add null terminator for M3U text content */
        char *text_content = malloc(fetch_size + 1);
        if (!text_content)
        {
            logger(LOG_ERROR, "Failed to allocate memory for M3U text content");
            free(content);
            return NULL;
        }
        memcpy(text_content, content, fetch_size);
        text_content[fetch_size] = '\0';
        free(content);

        logger(LOG_INFO, "Successfully fetched M3U from URL (%zu bytes)", fetch_size);
        return text_content;
    }

    /* Handle file:// URLs */
    if (strncmp(url, "file://", 7) == 0)
    {
        url += 7; /* Skip file:// prefix */
    }

    /* Try to open as local file */
    fp = fopen(url, "r");
    if (!fp)
    {
        logger(LOG_ERROR, "Failed to open M3U file: %s", url);
        return NULL;
    }

    /* Get file size */
    fseek(fp, 0, SEEK_END);
    file_size = ftell(fp);
    fseek(fp, 0, SEEK_SET);

    if (file_size < 0 || file_size > MAX_M3U_CONTENT)
    {
        logger(LOG_ERROR, "Invalid or too large M3U file: %s (size: %ld)", url, file_size);
        fclose(fp);
        return NULL;
    }

    /* Allocate memory for content */
    content = malloc(file_size + 1);
    if (!content)
    {
        logger(LOG_ERROR, "Failed to allocate memory for M3U content");
        fclose(fp);
        return NULL;
    }

    /* Read file content */
    read_size = fread(content, 1, file_size, fp);
    content[read_size] = '\0';

    fclose(fp);
    return content;
}

int m3u_is_header(const char *line)
{
    return (strncmp(line, "#EXTM3U", 7) == 0);
}

/* Extract x-tvg-url attribute from #EXTM3U header line
 * Returns: malloc'd string containing URL (caller must free), or NULL if not found
 */
static char *extract_tvg_url(const char *line)
{
    const char *attr_start;
    const char *value_start;
    const char *value_end;
    size_t value_len;
    char *result;

    /* Look for x-tvg-url= attribute (case insensitive) */
    attr_start = strcasestr(line, "x-tvg-url=");
    if (!attr_start)
    {
        /* Also try url-tvg= (alternative format) */
        attr_start = strcasestr(line, "url-tvg=");
        if (!attr_start)
        {
            return NULL;
        }
        value_start = attr_start + 8; /* Skip "url-tvg=" */
    }
    else
    {
        value_start = attr_start + 10; /* Skip "x-tvg-url=" */
    }

    /* Skip whitespace */
    while (*value_start && isspace(*value_start))
    {
        value_start++;
    }

    /* Check if value is quoted */
    if (*value_start == '"')
    {
        value_start++;
        value_end = strchr(value_start, '"');
        if (!value_end)
        {
            return NULL;
        }
    }
    else
    {
        /* Unquoted value - find next space or end of line */
        value_end = value_start;
        while (*value_end && !isspace(*value_end))
        {
            value_end++;
        }
    }

    value_len = value_end - value_start;
    if (value_len == 0 || value_len >= MAX_URL_LENGTH)
    {
        return NULL;
    }

    result = malloc(value_len + 1);
    if (!result)
    {
        return NULL;
    }

    memcpy(result, value_start, value_len);
    result[value_len] = '\0';

    return result;
}

/* Check if an IPv4 address is private (RFC 1918, RFC 6598)
 * Returns: 1 if private, 0 if public
 */
static int is_private_ipv4(const char *ip_str)
{
    struct in_addr addr;
    uint32_t ip;

    if (inet_pton(AF_INET, ip_str, &addr) != 1)
    {
        return 0;
    }

    ip = ntohl(addr.s_addr);

    /* 10.0.0.0/8 */
    if ((ip & 0xFF000000) == 0x0A000000)
    {
        return 1;
    }

    /* 172.16.0.0/12 */
    if ((ip & 0xFFF00000) == 0xAC100000)
    {
        return 1;
    }

    /* 192.168.0.0/16 */
    if ((ip & 0xFFFF0000) == 0xC0A80000)
    {
        return 1;
    }

    /* 100.64.0.0/10 (Carrier-grade NAT) */
    if ((ip & 0xFFC00000) == 0x64400000)
    {
        return 1;
    }

    /* 169.254.0.0/16 (Link-local) */
    if ((ip & 0xFFFF0000) == 0xA9FE0000)
    {
        return 1;
    }

    return 0;
}

/* Get server address as complete URL
 * Priority: hostname config > non-upstream interface private IP > non-upstream interface public IP > upstream interface IP > localhost
 * Returns: malloc'd string containing complete URL (protocol://host:port/ or protocol://host:port/path/)
 *          Always ends with trailing slash '/'
 *          Caller must free the returned string
 *
 * If config.hostname contains a full URL (with protocol and/or path), this function:
 * 1. Extracts and constructs the full URL including protocol, host, port, and path
 * 2. Ensures the path ends with a trailing slash
 * 3. If no protocol specified, defaults to http://
 *
 * If using interface IP, this function:
 * 1. Constructs URL as http://ip:port/ (or http://ip/ if port is 80)
 * 2. Port is obtained from bind_addresses
 */
char *get_server_address(void)
{
    struct ifaddrs *ifaddr, *ifa;
    char *host_ip = NULL;
    char *non_upstream_private_ip = NULL;
    char *non_upstream_public_ip = NULL;
    char *upstream_ip = NULL;
    char addr_str[INET6_ADDRSTRLEN];
    char server_port[16];
    char full_url[2048];

    /* Get first listening port from bind_addresses */
    if (bind_addresses && bind_addresses->service)
    {
        strncpy(server_port, bind_addresses->service, sizeof(server_port) - 1);
        server_port[sizeof(server_port) - 1] = '\0';
    }
    else
    {
        strcpy(server_port, "5140");
    }

    /* Priority 1: Use configured hostname */
    if (config.hostname && strlen(config.hostname) > 0)
    {
        char protocol[16] = {0};
        char host[256] = {0};
        char port[16] = {0};
        char path[1024] = {0};

        /* Parse URL components from config.hostname */
        if (http_parse_url_components(config.hostname, protocol, host, port, path) != 0)
        {
            /* Failed to parse, build basic URL with config.hostname as host */
            if (strcmp(server_port, "80") == 0)
            {
                snprintf(full_url, sizeof(full_url), "http://%s/", config.hostname);
            }
            else
            {
                snprintf(full_url, sizeof(full_url), "http://%s:%s/", config.hostname, server_port);
            }
            return strdup(full_url);
        }

        /* Build full URL */
        /* Default protocol to http if not specified */
        if (protocol[0] == '\0')
        {
            strcpy(protocol, "http");

            /* Use port from config if specified, otherwise use server_port */
            if (port[0] == '\0')
            {
                strncpy(port, server_port, sizeof(port) - 1);
                port[sizeof(port) - 1] = '\0';
            }
        }

        /* Build base URL: protocol://host:port or protocol://host (if port is 80 and protocol is http) */
        if (port[0] == '\0' ||
            (strcmp(protocol, "http") == 0 && strcmp(port, "80") == 0) ||
            (strcmp(protocol, "https") == 0 && strcmp(port, "443") == 0))
        {
            snprintf(full_url, sizeof(full_url), "%s://%s", protocol, host);
        }
        else
        {
            snprintf(full_url, sizeof(full_url), "%s://%s:%s", protocol, host, port);
        }

        /* Add path if present, ensuring it ends with slash */
        if (path[0] != '\0')
        {
            size_t path_len = strlen(path);
            /* Ensure path ends with '/' */
            if (path[path_len - 1] != '/')
            {
                strncat(full_url, path, sizeof(full_url) - strlen(full_url) - 2);
                strcat(full_url, "/");
            }
            else
            {
                strncat(full_url, path, sizeof(full_url) - strlen(full_url) - 1);
            }
        }
        else
        {
            /* No path specified, add trailing slash */
            strcat(full_url, "/");
        }

        return strdup(full_url);
    }

    /* Priority 2-4: Get IP from network interfaces */
    if (getifaddrs(&ifaddr) == -1)
    {
        logger(LOG_WARN, "Failed to get network interfaces, using localhost");
        /* Build URL with localhost */
        if (strcmp(server_port, "80") == 0)
        {
            snprintf(full_url, sizeof(full_url), "http://localhost/");
        }
        else
        {
            snprintf(full_url, sizeof(full_url), "http://localhost:%s/", server_port);
        }
        return strdup(full_url);
    }

    for (ifa = ifaddr; ifa != NULL; ifa = ifa->ifa_next)
    {
        if (ifa->ifa_addr == NULL)
            continue;

        /* Skip loopback */
        if (ifa->ifa_flags & IFF_LOOPBACK)
            continue;

        /* Only process IPv4 for now */
        if (ifa->ifa_addr->sa_family == AF_INET)
        {
            struct sockaddr_in *addr = (struct sockaddr_in *)ifa->ifa_addr;

            if (inet_ntop(AF_INET, &addr->sin_addr, addr_str, sizeof(addr_str)) == NULL)
                continue;

            /* Check if this is an upstream interface */
            int is_upstream = 0;
            if (config.upstream_interface[0] != '\0' &&
                strcmp(ifa->ifa_name, config.upstream_interface) == 0)
            {
                is_upstream = 1;
            }
            if (config.upstream_interface_fcc[0] != '\0' &&
                strcmp(ifa->ifa_name, config.upstream_interface_fcc) == 0)
            {
                is_upstream = 1;
            }
            if (config.upstream_interface_rtsp[0] != '\0' &&
                strcmp(ifa->ifa_name, config.upstream_interface_rtsp) == 0)
            {
                is_upstream = 1;
            }
            if (config.upstream_interface_multicast[0] != '\0' &&
                strcmp(ifa->ifa_name, config.upstream_interface_multicast) == 0)
            {
                is_upstream = 1;
            }

            if (is_upstream)
            {
                /* Store as upstream IP (lowest priority) */
                if (!upstream_ip)
                    upstream_ip = strdup(addr_str);
            }
            else
            {
                /* Non-upstream interface: distinguish private vs public */
                if (is_private_ipv4(addr_str))
                {
                    /* Private IP (higher priority) */
                    if (!non_upstream_private_ip)
                        non_upstream_private_ip = strdup(addr_str);
                }
                else
                {
                    /* Public IP (medium priority) */
                    if (!non_upstream_public_ip)
                        non_upstream_public_ip = strdup(addr_str);
                }
            }
        }
    }

    freeifaddrs(ifaddr);

    /* Priority: non-upstream private > non-upstream public > upstream > localhost */
    if (non_upstream_private_ip)
    {
        host_ip = non_upstream_private_ip;
        if (non_upstream_public_ip)
            free(non_upstream_public_ip);
        if (upstream_ip)
            free(upstream_ip);
    }
    else if (non_upstream_public_ip)
    {
        host_ip = non_upstream_public_ip;
        if (upstream_ip)
            free(upstream_ip);
    }
    else if (upstream_ip)
    {
        host_ip = upstream_ip;
    }
    else
    {
        host_ip = strdup("localhost");
    }

    /* Build complete URL with protocol, host, and port */
    if (strcmp(server_port, "80") == 0)
    {
        snprintf(full_url, sizeof(full_url), "http://%s/", host_ip);
    }
    else
    {
        snprintf(full_url, sizeof(full_url), "http://%s:%s/", host_ip, server_port);
    }

    free(host_ip);

    return strdup(full_url);
}

/* Extract attribute value from EXTINF line
 * Example: catchup-source="rtsp://..." extracts the URL
 */
static int extract_attribute(const char *line, const char *attr_name, char *value, size_t value_size)
{
    char search_pattern[128];
    const char *attr_start;
    const char *value_start;
    const char *value_end;
    size_t value_len;

    snprintf(search_pattern, sizeof(search_pattern), "%s=", attr_name);
    attr_start = strstr(line, search_pattern);
    if (!attr_start)
    {
        return -1;
    }

    value_start = attr_start + strlen(search_pattern);

    /* Skip whitespace */
    while (*value_start && isspace(*value_start))
    {
        value_start++;
    }

    /* Check if value is quoted */
    if (*value_start == '"')
    {
        value_start++;
        value_end = strchr(value_start, '"');
        if (!value_end)
        {
            return -1;
        }
    }
    else
    {
        /* Unquoted value - find next space or end of line */
        value_end = value_start;
        while (*value_end && !isspace(*value_end))
        {
            value_end++;
        }
    }

    value_len = value_end - value_start;
    if (value_len >= value_size)
    {
        return -1;
    }

    memcpy(value, value_start, value_len);
    value[value_len] = '\0';

    return 0;
}

/* Extract service name from EXTINF line
 * Format: #EXTINF:-1 ... ,ServiceName
 * Returns the text after the last comma
 */
static int extract_service_name(const char *line, char *name, size_t name_size)
{
    const char *comma_pos;
    const char *name_start;
    size_t name_len;

    comma_pos = strrchr(line, ',');
    if (!comma_pos)
    {
        return -1;
    }

    name_start = comma_pos + 1;

    /* Skip whitespace */
    while (*name_start && isspace(*name_start))
    {
        name_start++;
    }

    if (*name_start == '\0')
    {
        return -1;
    }

    /* Copy name and trim trailing whitespace/newline */
    strncpy(name, name_start, name_size - 1);
    name[name_size - 1] = '\0';

    /* Remove trailing whitespace and newline */
    name_len = strlen(name);
    while (name_len > 0 && (isspace(name[name_len - 1]) || name[name_len - 1] == '\r' || name[name_len - 1] == '\n'))
    {
        name[name_len - 1] = '\0';
        name_len--;
    }

    return 0;
}

/* Extract dynamic query parameters (containing { or }) from URL
 * Returns: malloc'd string containing only dynamic params (caller must free), or NULL if none
 */
static char *extract_dynamic_params(const char *url)
{
    const char *query_start;
    const char *param_start;
    const char *param_end;
    const char *equals_pos;
    const char *value_start;
    int has_placeholder;
    char result[MAX_URL_LENGTH];
    size_t result_len = 0;
    int first_param = 1;

    query_start = strchr(url, '?');
    if (!query_start)
    {
        return NULL;
    }

    result[0] = '\0';
    param_start = query_start + 1;

    while (*param_start)
    {
        /* Find the end of this parameter */
        param_end = strchr(param_start, '&');
        if (!param_end)
        {
            param_end = param_start + strlen(param_start);
        }

        /* Find the equals sign */
        equals_pos = strchr(param_start, '=');
        if (equals_pos && equals_pos < param_end)
        {
            value_start = equals_pos + 1;

            /* Check if value contains { or } */
            has_placeholder = 0;
            for (const char *p = value_start; p < param_end; p++)
            {
                if (*p == '{' || *p == '}' || *p == '$')
                {
                    has_placeholder = 1;
                    break;
                }
            }

            if (has_placeholder)
            {
                /* Add this parameter to result */
                size_t param_len = param_end - param_start;
                if (!first_param)
                {
                    result[result_len++] = '&';
                }
                memcpy(result + result_len, param_start, param_len);
                result_len += param_len;
                result[result_len] = '\0';
                first_param = 0;
            }
        }

        /* Move to next parameter */
        if (*param_end == '\0')
        {
            break;
        }
        param_start = param_end + 1;
    }

    if (result_len == 0)
    {
        return NULL;
    }

    return strdup(result);
}

/* Extract actual URL from http://host:port/protocol/actual_url format
 * Example: http://router.ccca.cc:5140/rtp/239.253.64.120:5140 -> rtp://239.253.64.120:5140
 */
static int extract_wrapped_url(const char *url, char *extracted, size_t extracted_size)
{
    const char *scheme_end;
    const char *host_start;
    const char *path_start;
    const char *protocol_end;
    char protocol[16];
    size_t protocol_len;

    /* Check if this is an HTTP(S) URL */
    if (strncmp(url, "http://", 7) != 0 && strncmp(url, "https://", 8) != 0)
    {
        return -1; /* Not an HTTP URL */
    }

    scheme_end = strstr(url, "://");
    if (!scheme_end)
    {
        return -1;
    }

    host_start = scheme_end + 3;

    /* Find path start (first / after host:port) */
    /* For IPv6, skip to closing bracket first */
    if (*host_start == '[')
    {
        const char *bracket_end = strchr(host_start, ']');
        if (!bracket_end)
        {
            return -1;
        }
        path_start = strchr(bracket_end, '/');
    }
    else
    {
        path_start = strchr(host_start, '/');
    }

    if (!path_start)
    {
        return -1; /* No path */
    }

    path_start++; /* Skip the slash */

    /* Extract protocol (rtp, udp, rtsp) */
    protocol_end = strchr(path_start, '/');
    if (!protocol_end)
    {
        return -1; /* No protocol separator */
    }

    protocol_len = protocol_end - path_start;
    if (protocol_len >= sizeof(protocol))
    {
        return -1; /* Protocol too long */
    }

    memcpy(protocol, path_start, protocol_len);
    protocol[protocol_len] = '\0';

    /* Check if protocol is supported */
    if (strcasecmp(protocol, "rtp") != 0 &&
        strcasecmp(protocol, "udp") != 0 &&
        strcasecmp(protocol, "rtsp") != 0)
    {
        return -1; /* Unsupported protocol */
    }

    /* Build extracted URL: protocol://rest_of_path */
    if (snprintf(extracted, extracted_size, "%s://%s", protocol, protocol_end + 1) >= (int)extracted_size)
    {
        return -1; /* Buffer too small */
    }

    return 0;
}

/* Build service URL for transformed M3U
 * service_name: name of the service (will be URL encoded)
 * query_params: optional query parameters (can be NULL)
 * output: buffer to store URL
 * output_size: size of output buffer
 * base_url: complete base URL from get_server_address() (e.g., "http://host:port/" or "https://host:port/path/")
 * Returns: 0 on success, -1 on error
 */
static int build_service_url(const char *service_name, const char *query_params,
                             char *output, size_t output_size,
                             const char *base_url)
{
    char *encoded_name = http_url_encode(service_name);
    char *encoded_token = NULL;
    int result;
    int has_query_params = (query_params && strlen(query_params) > 0);
    int has_r2h_token = (config.r2h_token && config.r2h_token[0] != '\0');

    if (!encoded_name)
    {
        logger(LOG_ERROR, "Failed to URL encode service name");
        return -1;
    }

    /* URL encode r2h-token if configured */
    if (has_r2h_token)
    {
        encoded_token = http_url_encode(config.r2h_token);
        if (!encoded_token)
        {
            logger(LOG_ERROR, "Failed to URL encode r2h-token");
            free(encoded_name);
            return -1;
        }
    }

    /* Build URL with appropriate query parameters */
    /* base_url already ends with '/', so we can directly append the service name */
    if (has_query_params && has_r2h_token)
    {
        /* Include both query parameters and r2h-token */
        result = snprintf(output, output_size, "%s%s?%s&r2h-token=%s",
                          base_url, encoded_name, query_params, encoded_token);
    }
    else if (has_query_params)
    {
        /* Include only query parameters */
        result = snprintf(output, output_size, "%s%s?%s",
                          base_url, encoded_name, query_params);
    }
    else if (has_r2h_token)
    {
        /* Include only r2h-token */
        result = snprintf(output, output_size, "%s%s?r2h-token=%s",
                          base_url, encoded_name, encoded_token);
    }
    else
    {
        /* No query parameters */
        result = snprintf(output, output_size, "%s%s",
                          base_url, encoded_name);
    }

    free(encoded_name);
    if (encoded_token)
        free(encoded_token);

    if (result >= (int)output_size)
    {
        logger(LOG_ERROR, "Service URL too long");
        return -1;
    }

    return 0;
}

/* Check if URL can be recognized and converted to a service
 * Returns: 1 if URL can be handled, 0 otherwise
 */
static int is_url_recognizable(const char *url)
{
    char test_url[MAX_URL_LENGTH];
    char extracted[MAX_URL_LENGTH];

    strncpy(test_url, url, sizeof(test_url) - 1);
    test_url[sizeof(test_url) - 1] = '\0';

    /* Try to extract wrapped URL */
    if (extract_wrapped_url(test_url, extracted, sizeof(extracted)) == 0)
    {
        /* Use extracted URL for checking */
        size_t len = strlen(extracted);
        if (len >= sizeof(test_url))
            len = sizeof(test_url) - 1;
        memcpy(test_url, extracted, len);
        test_url[len] = '\0';
    }

    /* Check if protocol is supported */
    if (strncmp(test_url, "rtp://", 6) == 0 ||
        strncmp(test_url, "udp://", 6) == 0 ||
        strncmp(test_url, "rtsp://", 7) == 0)
    {
        return 1;
    }

    return 0;
}

/* Append string to transformed M3U buffer */
static int append_to_transformed_m3u(const char *str, service_source_t source)
{
    size_t len = strlen(str);
    size_t new_size;

    (void)source; /* Source parameter kept for API compatibility but not used */

    /* Allocate buffer if needed */
    if (!transformed_m3u)
    {
        transformed_m3u_size = 4096;
        transformed_m3u = malloc(transformed_m3u_size);
        if (!transformed_m3u)
        {
            logger(LOG_ERROR, "Failed to allocate transformed M3U buffer");
            return -1;
        }
        transformed_m3u_used = 0;
        transformed_m3u[0] = '\0';
    }

    /* Grow buffer if needed */
    while (transformed_m3u_used + len + 1 > transformed_m3u_size)
    {
        new_size = transformed_m3u_size * 2;
        if (new_size > MAX_M3U_CONTENT)
        {
            logger(LOG_ERROR, "Transformed M3U too large");
            return -1;
        }
        char *new_buf = realloc(transformed_m3u, new_size);
        if (!new_buf)
        {
            logger(LOG_ERROR, "Failed to grow transformed M3U buffer");
            return -1;
        }
        transformed_m3u = new_buf;
        transformed_m3u_size = new_size;
    }

    /* Append string */
    memcpy(transformed_m3u + transformed_m3u_used, str, len);
    transformed_m3u_used += len;
    transformed_m3u[transformed_m3u_used] = '\0';

    return 0;
}

/* Find a unique service name by adding numeric suffix if needed
 * Returns: malloc'd string containing unique name (caller must free), or NULL on error
 *
 * If service_name already exists:
 * - First occurrence keeps original name (no modification)
 * - Second occurrence gets name/2
 * - Third occurrence gets name/3, etc.
 * If service_name doesn't exist, returns copy of service_name
 */
static char *find_unique_service_name(const char *service_name)
{
    service_t *existing;
    int max_suffix = 0;
    char test_name[MAX_SERVICE_NAME];
    char *result = NULL;
    int base_exists = 0;

    /* Check if base name exists and find max numbered suffix */
    for (existing = services; existing != NULL; existing = existing->next)
    {
        if (!existing->url)
            continue;

        /* Check for exact base name match */
        if (strcmp(existing->url, service_name) == 0)
        {
            base_exists = 1;
            /* Don't modify existing service, just note that base name is taken */
        }

        /* Check for numbered variants (name/2, name/3, etc.) */
        size_t base_len = strlen(service_name);
        if (strncmp(existing->url, service_name, base_len) == 0 &&
            existing->url[base_len] == '/')
        {
            /* Extract the suffix number */
            const char *suffix_str = existing->url + base_len + 1;
            char *endptr;
            long suffix_num = strtol(suffix_str, &endptr, 10);

            /* Valid if entire remaining string is a number */
            if (*suffix_str != '\0' && *endptr == '\0' && suffix_num > 0 && suffix_num < 1000)
            {
                if (suffix_num > max_suffix)
                {
                    max_suffix = (int)suffix_num;
                }
            }
        }
    }

    /* If no conflicts, use base name as-is */
    if (!base_exists && max_suffix == 0)
    {
        return strdup(service_name);
    }

    /* Base name is taken, assign next available number */
    /* Start from 2 (first duplicate), or max_suffix + 1 if numbered services already exist */
    int next_suffix = (max_suffix > 0) ? max_suffix + 1 : 2;
    snprintf(test_name, sizeof(test_name), "%s/%d", service_name, next_suffix);
    result = strdup(test_name);

    return result;
}

/* Create a service from name and URL
 * Returns: malloc'd string containing the actual unique service name used (caller must free),
 *          or NULL on error
 */
static char *create_service_from_url(const char *service_name, const char *url, service_source_t source)
{
    char normalized_url[MAX_URL_LENGTH];
    char extracted_url[MAX_URL_LENGTH];
    service_t *new_service = NULL;
    service_t **services_tail;
    char *unique_name = NULL;

    strncpy(normalized_url, url, sizeof(normalized_url) - 1);
    normalized_url[sizeof(normalized_url) - 1] = '\0';

    /* Try to extract wrapped URL (e.g., http://router:5140/rtp/239.x.x.x -> rtp://239.x.x.x) */
    if (extract_wrapped_url(normalized_url, extracted_url, sizeof(extracted_url)) == 0)
    {
        /* Use the extracted URL */
        strncpy(normalized_url, extracted_url, sizeof(normalized_url) - 1);
        normalized_url[sizeof(normalized_url) - 1] = '\0';
    }

    /* Find unique service name (handles duplicates automatically) */
    unique_name = find_unique_service_name(service_name);
    if (!unique_name)
    {
        logger(LOG_ERROR, "Failed to generate unique service name for: %s", service_name);
        return NULL;
    }

    logger(LOG_DEBUG, "Creating service from M3U: %s -> %s %s", service_name, unique_name, normalized_url);

    /* Create service based on URL type */
    if (strncmp(normalized_url, "rtp://", 6) == 0 || strncmp(normalized_url, "udp://", 6) == 0)
    {
        new_service = service_create_from_rtp_url(normalized_url);
    }
    else if (strncmp(normalized_url, "rtsp://", 7) == 0)
    {
        new_service = service_create_from_rtsp_url(normalized_url);
    }
    else
    {
        logger(LOG_WARN, "Unsupported URL format in M3U: %s", normalized_url);
        free(unique_name);
        return NULL;
    }

    if (!new_service)
    {
        logger(LOG_ERROR, "Failed to create service from M3U entry: %s", service_name);
        free(unique_name);
        return NULL;
    }

    /* Set service URL (name) to unique name */
    /* Free the URL that was set by service_create_* functions */
    if (new_service->url)
    {
        free(new_service->url);
    }
    new_service->url = strdup(unique_name); /* Copy unique name to service */
    if (!new_service->url)
    {
        logger(LOG_ERROR, "Failed to allocate service URL");
        service_free(new_service);
        free(unique_name);
        return NULL;
    }

    /* Set service source */
    new_service->source = source;

    /* Add to global services list */
    services_tail = &services;
    while (*services_tail != NULL)
    {
        services_tail = &(*services_tail)->next;
    }
    *services_tail = new_service;
    new_service->next = NULL;

    logger(LOG_INFO, "Service created: %s (%s) [%s]", unique_name,
           new_service->service_type == SERVICE_MRTP ? "RTP" : "RTSP",
           source == SERVICE_SOURCE_INLINE ? "inline" : "external");

    /* Return the unique name for use in transformed M3U */
    return unique_name;
}

int m3u_parse_and_create_services(const char *content, const char *source_url)
{
    char line[MAX_M3U_LINE];
    const char *content_ptr = content;
    struct m3u_extinf current_extinf;
    int in_entry = 0;
    int entry_count = 0;
    size_t line_len;
    char *server_addr = NULL;
    char proxy_url[MAX_URL_LENGTH];
    char transformed_line[MAX_M3U_LINE];

    memset(&current_extinf, 0, sizeof(current_extinf));

    logger(LOG_INFO, "Parsing M3U content from: %s", source_url ? source_url : "inline");

    /* Determine service source based on source_url */
    service_source_t service_source;
    if (!source_url || strcmp(source_url, "inline") == 0 || strncmp(source_url, "inline", 6) == 0)
    {
        service_source = SERVICE_SOURCE_INLINE;
    }
    else
    {
        service_source = SERVICE_SOURCE_EXTERNAL;
    }

    /* Get server address as complete URL */
    server_addr = get_server_address();
    if (!server_addr)
    {
        logger(LOG_ERROR, "Failed to get server address");
        return -1;
    }

    logger(LOG_INFO, "Server base URL: %s", server_addr);

    /* Don't reset transformed M3U buffer - accumulate content from multiple sources */
    /* Buffer will be cleared when configuration is reloaded */

    while (*content_ptr)
    {
        /* Extract one line */
        const char *line_end = strchr(content_ptr, '\n');
        if (line_end)
        {
            line_len = line_end - content_ptr;
            if (line_len >= sizeof(line))
            {
                line_len = sizeof(line) - 1;
            }
            memcpy(line, content_ptr, line_len);
            line[line_len] = '\0';
            content_ptr = line_end + 1;
        }
        else
        {
            /* Last line without newline */
            strncpy(line, content_ptr, sizeof(line) - 1);
            line[sizeof(line) - 1] = '\0';
            content_ptr += strlen(content_ptr);
        }

        /* Trim trailing whitespace */
        line_len = strlen(line);
        while (line_len > 0 && (isspace(line[line_len - 1]) || line[line_len - 1] == '\r'))
        {
            line[line_len - 1] = '\0';
            line_len--;
        }

        /* Skip empty lines */
        if (line_len == 0)
        {
            continue;
        }

        /* Handle M3U header */
        if (m3u_is_header(line))
        {
            /* Extract EPG URL from header if present */
            char *tvg_url = extract_tvg_url(line);
            if (tvg_url)
            {
                logger(LOG_INFO, "Found EPG URL in M3U header: %s", tvg_url);

                /* Set EPG URL directly (don't fetch yet - will be triggered after parsing) */
                epg_set_url(tvg_url);
                free(tvg_url);
            }

            /* Only add header once to the transformed playlist */
            if (!transformed_m3u_has_header)
            {
                /* Build transformed header with local EPG URL */
                char transformed_header[MAX_M3U_LINE];

                if (tvg_url)
                {
                    /* Replace x-tvg-url with local endpoint */
                    char *server_addr_temp = get_server_address();
                    const char *epg_filename;

                    /* Determine EPG filename based on original URL extension */
                    if (epg_url_is_gzipped(tvg_url))
                    {
                        epg_filename = "epg.xml.gz";
                    }
                    else
                    {
                        epg_filename = "epg.xml";
                    }

                    /* server_addr_temp is now a complete URL ending with '/', so just append filename */
                    snprintf(transformed_header, sizeof(transformed_header),
                             "#EXTM3U x-tvg-url=\"%s%s\"",
                             server_addr_temp, epg_filename);

                    if (server_addr_temp)
                        free(server_addr_temp);

                    append_to_transformed_m3u(transformed_header, service_source);
                }
                else
                {
                    /* No EPG URL, add header as-is */
                    append_to_transformed_m3u(line, service_source);
                }
                append_to_transformed_m3u("\n", service_source);
                transformed_m3u_has_header = 1;
            }
            continue;
        }

        /* Handle other comments (not EXTINF) */
        if (line[0] == '#' && strncmp(line, "#EXTINF:", 8) != 0)
        {
            append_to_transformed_m3u(line, service_source);
            append_to_transformed_m3u("\n", service_source);
            continue;
        }

        /* Parse EXTINF line */
        if (strncmp(line, "#EXTINF:", 8) == 0)
        {
            memset(&current_extinf, 0, sizeof(current_extinf));

            /* Add blank line before first entry to separate from header */
            if (entry_count == 0)
            {
                append_to_transformed_m3u("\n", service_source);
            }

            /* Extract service name */
            char base_name[MAX_SERVICE_NAME];
            if (extract_service_name(line, base_name, sizeof(base_name)) != 0)
            {
                logger(LOG_WARN, "Failed to extract service name from EXTINF line");
                in_entry = 0;
                continue;
            }

            /* Extract group-title if present */
            if (extract_attribute(line, "group-title", current_extinf.group_title,
                                  sizeof(current_extinf.group_title)) == 0 &&
                current_extinf.group_title[0] != '\0')
            {
                /* Build service name as "group-title/service-name" */
                size_t group_len = strlen(current_extinf.group_title);
                size_t base_len = strlen(base_name);
                size_t total_len = group_len + 1 + base_len;

                if (total_len >= sizeof(current_extinf.name))
                {
                    /* Truncate group title to make it fit */
                    size_t max_group_len = sizeof(current_extinf.name) - base_len - 2;
                    current_extinf.group_title[max_group_len] = '\0';
                    logger(LOG_WARN, "Group title truncated for service: %s", base_name);
                }

                /* Now safe to format */
                int written = snprintf(current_extinf.name, sizeof(current_extinf.name),
                                       "%s/%s", current_extinf.group_title, base_name);
                if (written < 0 || (size_t)written >= sizeof(current_extinf.name))
                {
                    logger(LOG_ERROR, "Failed to format service name, using base name only");
                    strncpy(current_extinf.name, base_name, sizeof(current_extinf.name) - 1);
                    current_extinf.name[sizeof(current_extinf.name) - 1] = '\0';
                }
            }
            else
            {
                /* No group-title, use base name as-is */
                strncpy(current_extinf.name, base_name, sizeof(current_extinf.name) - 1);
                current_extinf.name[sizeof(current_extinf.name) - 1] = '\0';
            }

            /* Extract catchup-source if present */
            if (extract_attribute(line, "catchup-source", current_extinf.catchup_source,
                                  sizeof(current_extinf.catchup_source)) == 0)
            {
                current_extinf.has_catchup = 1;
            }

            /* Store original EXTINF line for later processing */
            /* We'll generate the transformed EXTINF when processing the URL line,
             * after we know the unique service name */
            strncpy(transformed_line, line, sizeof(transformed_line) - 1);
            transformed_line[sizeof(transformed_line) - 1] = '\0';

            in_entry = 1;
            continue;
        }

        /* Process URL line (follows EXTINF) */
        if (in_entry && line[0] != '#')
        {
            /* Check if URL is recognizable */
            int is_recognizable = is_url_recognizable(line);

            if (is_recognizable)
            {
                /* Recognizable URL: create service first to get unique name */
                char *unique_service_name = create_service_from_url(current_extinf.name, line, service_source);

                if (unique_service_name)
                {
                    char *unique_catchup_name = NULL;
                    int catchup_is_recognizable = 0;

                    /* Create catchup service if present and URL is recognizable */
                    if (current_extinf.has_catchup && strlen(current_extinf.catchup_source) > 0)
                    {
                        catchup_is_recognizable = is_url_recognizable(current_extinf.catchup_source);
                        if (catchup_is_recognizable)
                        {
                            char catchup_name[MAX_SERVICE_NAME + 20];
                            snprintf(catchup_name, sizeof(catchup_name), "%s/catchup", unique_service_name);
                            unique_catchup_name = create_service_from_url(catchup_name, current_extinf.catchup_source, service_source);
                        }
                    }

                    /* Now generate the transformed EXTINF line with unique names */
                    if (unique_catchup_name && catchup_is_recognizable)
                    {
                        /* Replace catchup-source URL in EXTINF line */
                        char *catchup_query = extract_dynamic_params(current_extinf.catchup_source);
                        char catchup_proxy_url[MAX_URL_LENGTH];

                        if (build_service_url(unique_catchup_name, catchup_query, catchup_proxy_url,
                                              sizeof(catchup_proxy_url), server_addr) == 0)
                        {
                            /* Find and replace catchup-source in line */
                            char *catchup_start = strstr(transformed_line, "catchup-source=\"");
                            if (catchup_start)
                            {
                                catchup_start += 16; /* Skip 'catchup-source="' */
                                char *catchup_end = strchr(catchup_start, '"');
                                if (catchup_end)
                                {
                                    /* Build transformed EXTINF line */
                                    size_t prefix_len = catchup_start - transformed_line;
                                    char final_extinf[MAX_M3U_LINE];
                                    snprintf(final_extinf, sizeof(final_extinf), "%.*s%s%s",
                                             (int)prefix_len, transformed_line, catchup_proxy_url, catchup_end);
                                    append_to_transformed_m3u(final_extinf, service_source);
                                    append_to_transformed_m3u("\n", service_source);
                                }
                                else
                                {
                                    append_to_transformed_m3u(transformed_line, service_source);
                                    append_to_transformed_m3u("\n", service_source);
                                }
                            }
                            else
                            {
                                append_to_transformed_m3u(transformed_line, service_source);
                                append_to_transformed_m3u("\n", service_source);
                            }
                        }
                        else
                        {
                            append_to_transformed_m3u(transformed_line, service_source);
                            append_to_transformed_m3u("\n", service_source);
                        }

                        if (catchup_query)
                            free(catchup_query);
                    }
                    else if (current_extinf.has_catchup && strlen(current_extinf.catchup_source) > 0 &&
                             !catchup_is_recognizable &&
                             current_extinf.catchup_source[0] == '&')
                    {
                        /* catchup-source is not recognizable but starts with '&', and main service was converted
                         * Replace '&' with '?' to make it valid for append mode */
                        char *catchup_start = strstr(transformed_line, "catchup-source=\"");
                        if (catchup_start)
                        {
                            catchup_start += 16; /* Skip 'catchup-source="' */
                            char *catchup_end = strchr(catchup_start, '"');
                            if (catchup_end)
                            {
                                /* Build transformed EXTINF line with modified catchup-source */
                                size_t prefix_len = catchup_start - transformed_line;
                                char final_extinf[MAX_M3U_LINE];
                                /* Replace leading '&' with '?' */
                                snprintf(final_extinf, sizeof(final_extinf), "%.*s?%.*s%s",
                                         (int)prefix_len, transformed_line,
                                         (int)(catchup_end - catchup_start - 1), catchup_start + 1,
                                         catchup_end);
                                append_to_transformed_m3u(final_extinf, service_source);
                                append_to_transformed_m3u("\n", service_source);
                            }
                            else
                            {
                                append_to_transformed_m3u(transformed_line, service_source);
                                append_to_transformed_m3u("\n", service_source);
                            }
                        }
                        else
                        {
                            append_to_transformed_m3u(transformed_line, service_source);
                            append_to_transformed_m3u("\n", service_source);
                        }
                    }
                    else
                    {
                        /* No catchup or unrecognizable catchup URL, use original EXTINF */
                        append_to_transformed_m3u(transformed_line, service_source);
                        append_to_transformed_m3u("\n", service_source);
                    }

                    /* Now generate the main service URL */
                    char *main_query = extract_dynamic_params(line);

                    /* Build service URL using the actual unique service name for transformed M3U */
                    if (build_service_url(unique_service_name, main_query, proxy_url,
                                          sizeof(proxy_url), server_addr) == 0)
                    {
                        append_to_transformed_m3u(proxy_url, service_source);
                    }
                    else
                    {
                        append_to_transformed_m3u(line, service_source);
                    }
                    append_to_transformed_m3u("\n", service_source);

                    if (main_query)
                        free(main_query);
                    if (unique_catchup_name)
                        free(unique_catchup_name);
                    free(unique_service_name);
                }
                else
                {
                    /* Failed to create service, preserve original EXTINF and URL */
                    append_to_transformed_m3u(transformed_line, service_source);
                    append_to_transformed_m3u("\n", service_source);
                    append_to_transformed_m3u(line, service_source);
                    append_to_transformed_m3u("\n", service_source);
                }
            }
            else
            {
                /* Unrecognizable URL: preserve original EXTINF and URL completely */
                append_to_transformed_m3u(transformed_line, service_source);
                append_to_transformed_m3u("\n", service_source);
                append_to_transformed_m3u(line, service_source);
                append_to_transformed_m3u("\n", service_source);
                logger(LOG_DEBUG, "Preserving unrecognizable URL: %s", line);
            }

            /* Add blank line after each entry */
            append_to_transformed_m3u("\n", service_source);

            entry_count++;
            in_entry = 0;
        }
    }

    /* Mark the end of inline content if this was inline parsing */
    if (service_source == SERVICE_SOURCE_INLINE)
    {
        transformed_m3u_inline_end = transformed_m3u_used;
    }

    logger(LOG_INFO, "Parsed %d M3U entries, generated transformed playlist (%zu bytes)",
           entry_count, transformed_m3u_used);

    if (server_addr)
        free(server_addr);

    return 0;
}

const char *m3u_get_transformed_playlist(void)
{
    /* Simply return the unified buffer - no merging needed */
    if (transformed_m3u_used == 0)
    {
        return NULL;
    }

    return transformed_m3u;
}

void m3u_reset_transformed_playlist(void)
{
    /* Clear entire buffer */
    if (transformed_m3u)
    {
        free(transformed_m3u);
        transformed_m3u = NULL;
    }
    transformed_m3u_size = 0;
    transformed_m3u_used = 0;
    transformed_m3u_inline_end = 0;

    /* Reset header flag */
    transformed_m3u_has_header = 0;
}

void m3u_reset_external_playlist(void)
{
    /* Truncate buffer to inline content only (for external reload) */
    if (transformed_m3u && transformed_m3u_inline_end < transformed_m3u_used)
    {
        /* Reset used size to inline end position */
        transformed_m3u_used = transformed_m3u_inline_end;
        transformed_m3u[transformed_m3u_used] = '\0';
    }

    /* If no inline content, reset header flag to allow external M3U header to be added */
    if (transformed_m3u_inline_end == 0)
    {
        transformed_m3u_has_header = 0;
    }
}
