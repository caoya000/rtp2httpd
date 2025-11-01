#ifndef __MULTICAST_H__
#define __MULTICAST_H__

#include "rtp2httpd.h"

/* UDP socket receive buffer size (512KB) */
#define UDP_RCVBUF_SIZE (512 * 1024)

/**
 * Bind socket to upstream interface if configured
 *
 * @param sock Socket file descriptor to bind
 * @param ifname Interface name for binding (may be NULL)
 */
void bind_to_upstream_interface(int sock, const char *ifname);

/**
 * Select the appropriate upstream interface for FCC with priority logic
 * Priority: upstream_interface_fcc > upstream_interface
 *
 * @return Pointer to the interface name to use (may be NULL if none configured)
 */
const char *get_upstream_interface_for_fcc(void);

/**
 * Select the appropriate upstream interface for RTSP with priority logic
 * Priority: upstream_interface_rtsp > upstream_interface
 *
 * @return Pointer to the interface name to use (may be NULL if none configured)
 */
const char *get_upstream_interface_for_rtsp(void);

/**
 * Select the appropriate upstream interface for multicast with priority logic
 * Priority: upstream_interface_multicast > upstream_interface
 *
 * @return Pointer to the interface name to use (may be NULL if none configured)
 */
const char *get_upstream_interface_for_multicast(void);

/**
 * Join a multicast group and return socket
 *
 * @param service Service structure containing multicast address info
 * @return Socket file descriptor on success, exits on failure
 */
int join_mcast_group(service_t *service);

/**
 * Rejoin a multicast group on an existing socket
 * This performs MCAST_LEAVE_GROUP followed by MCAST_JOIN_GROUP to force
 * the kernel to send a new IGMP Report message, refreshing membership.
 *
 * @param sock Existing multicast socket file descriptor
 * @param service Service structure containing multicast address info
 * @return 0 on success, -1 on failure
 */
int rejoin_mcast_group(int sock, service_t *service);

#endif /* __MULTICAST_H__ */
