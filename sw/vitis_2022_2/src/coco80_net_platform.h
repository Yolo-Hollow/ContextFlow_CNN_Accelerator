#ifndef COCO80_NET_PLATFORM_H
#define COCO80_NET_PLATFORM_H

struct netif;

extern volatile int coco80_net_tcp_fast_timer;
extern volatile int coco80_net_tcp_slow_timer;

int coco80_net_platform_initialize(void);
void coco80_net_platform_enable_interrupts(void);
void coco80_net_platform_poll(struct netif *netif);

#endif
