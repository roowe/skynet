#include "skynet_timer.c"

#include <stdio.h>

#define CHECK(condition) do { \
	if (!(condition)) { \
		fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #condition); \
		exit(EXIT_FAILURE); \
	} \
} while (0)

#define LIVE_HANDLE 0x100002au
#define RETIRED_HANDLE 0x100002bu

static struct timer_event delivered[5];
static size_t delivered_count;

int
skynet_context_push(uint32_t handle, struct skynet_message *message) {
	CHECK(message->source == 0);
	CHECK(message->data == NULL);
	CHECK(message->sz == ((size_t)PTYPE_RESPONSE << MESSAGE_TYPE_SHIFT));
	CHECK(delivered_count < sizeof(delivered) / sizeof(delivered[0]));
	delivered[delivered_count++] = (struct timer_event){ handle, message->session };
	return handle == RETIRED_HANDLE ? -1 : 0;
}

void
skynet_error(struct skynet_context *ctx, const char *fmt, ...) {
	(void)ctx;
	fprintf(stderr, "unexpected timer error: %s\n", fmt);
	exit(EXIT_FAILURE);
}

static void
expect_delivery(size_t index, uint32_t handle, int session) {
	CHECK(index < delivered_count);
	CHECK(delivered[index].handle == handle);
	CHECK(delivered[index].session == session);
}

static void
check_immediate_delivery(void) {
	CHECK(skynet_timeout(LIVE_HANDLE, 0, 21) == 21);
	CHECK(skynet_timeout(LIVE_HANDLE, -1, 22) == 22);
	CHECK(skynet_timeout(RETIRED_HANDLE, 0, 23) == -1);
	CHECK(delivered_count == 3);
	expect_delivery(0, LIVE_HANDLE, 21);
	expect_delivery(1, LIVE_HANDLE, 22);
	expect_delivery(2, RETIRED_HANDLE, 23);
	delivered_count = 0;
}

static void
check_boundary(uint32_t start) {
	TI = timer_create_timer();
	TI->time = start;

	CHECK(skynet_timeout(LIVE_HANDLE, 3, 11) == 11);
	CHECK(skynet_timeout(LIVE_HANDLE, 1, 12) == 12);
	CHECK(skynet_timeout(LIVE_HANDLE, 2, 13) == 13);
	CHECK(skynet_timeout(RETIRED_HANDLE, 3, 14) == 14);
	CHECK(skynet_timeout(LIVE_HANDLE, 4, 15) == 15);
	CHECK(delivered_count == 0);

	timer_update(TI);
	CHECK(delivered_count == 1);
	expect_delivery(0, LIVE_HANDLE, 12);
	timer_update(TI);
	CHECK(delivered_count == 2);
	expect_delivery(1, LIVE_HANDLE, 13);
	timer_update(TI);
	CHECK(delivered_count == 4);
	expect_delivery(2, LIVE_HANDLE, 11);
	expect_delivery(3, RETIRED_HANDLE, 14);
	timer_update(TI);
	CHECK(delivered_count == 5);
	expect_delivery(4, LIVE_HANDLE, 15);
	timer_update(TI);
	CHECK(delivered_count == 5);

	delivered_count = 0;
	SPIN_DESTROY(TI);
	skynet_free(TI);
	TI = NULL;
}

int
main(void) {
	check_immediate_delivery();
	// Start two ticks before each level boundary, including the uint32_t wrap.
	const uint32_t starts[] = { 0xfeu, 0x3ffeu, 0xffffeu, 0x3fffffeu, UINT32_MAX - 1 };
	for (size_t i = 0; i < sizeof(starts) / sizeof(starts[0]); ++i) {
		check_boundary(starts[i]);
	}
	return EXIT_SUCCESS;
}
