#include "skynet_handle.h"
#include "skynet_server.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#define CHECK(condition) do { \
	if (!(condition)) { \
		fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #condition); \
		exit(EXIT_FAILURE); \
	} \
} while (0)

struct skynet_context {
	uint32_t handle;
	atomic_uint refs;
};

uint32_t
skynet_context_handle(struct skynet_context *ctx) {
	return ctx->handle;
}

void
skynet_context_grab(struct skynet_context *ctx) {
	CHECK(atomic_fetch_add(&ctx->refs, 1) > 0);
}

void
skynet_context_release(struct skynet_context *ctx) {
	unsigned refs = atomic_fetch_sub(&ctx->refs, 1);
	CHECK(refs > 0);
	if (refs == 1) {
		// The runtime destructor can query the table; retire must unlock first.
		CHECK(skynet_handle_grab(ctx->handle) == NULL);
	}
}

char *
skynet_strdup(const char *name) {
	size_t size = strlen(name) + 1;
	char *copy = malloc(size);
	CHECK(copy != NULL);
	return memcpy(copy, name, size);
}

static void
register_context(struct skynet_context *ctx) {
	// The table owns the initial reference.
	atomic_init(&ctx->refs, 1);
	ctx->handle = skynet_handle_register(ctx);
	CHECK(ctx->handle >> HANDLE_REMOTE_SHIFT == 0x2a);
	CHECK((ctx->handle & HANDLE_MASK) != 0);
}

static void
check_table(void) {
	struct skynet_context contexts[10] = {0};
	for (size_t i = 0; i < sizeof(contexts) / sizeof(contexts[0]); ++i) {
		register_context(&contexts[i]);
	}
	// Keep all contexts live through growth and check each full handle afterward.
	for (size_t i = 0; i < sizeof(contexts) / sizeof(contexts[0]); ++i) {
		struct skynet_context *ctx = skynet_handle_grab(contexts[i].handle);
		CHECK(ctx == &contexts[i]);
		CHECK(atomic_load(&ctx->refs) == 2);
		skynet_context_release(ctx);
	}
	uint32_t first = contexts[0].handle;
	uint32_t second = contexts[1].handle;
	uint32_t wrong_harbor = first ^ (UINT32_C(1) << HANDLE_REMOTE_SHIFT);
	CHECK(skynet_handle_grab(wrong_harbor) == NULL);
	CHECK(skynet_handle_retire(wrong_harbor) == 0);

	char name[] = "zulu";
	const char *copy = skynet_handle_namehandle(first, name);
	CHECK(copy != NULL && copy != name);
	name[0] = 'x';
	CHECK(strcmp(copy, "zulu") == 0);
	CHECK(skynet_handle_namehandle(second, "alpha") != NULL);
	CHECK(skynet_handle_namehandle(first, "middle") != NULL);
	CHECK(skynet_handle_namehandle(second, "bravo") != NULL);
	CHECK(skynet_handle_namehandle(second, "middle") == NULL);
	CHECK(skynet_handle_findname("zulu") == first);
	CHECK(skynet_handle_findname("middle") == first);
	CHECK(skynet_handle_findname("alpha") == second);
	CHECK(skynet_handle_findname("bravo") == second);

	CHECK(skynet_handle_retire(first) == 1);
	CHECK(skynet_handle_retire(first) == 0);
	CHECK(skynet_handle_grab(first) == NULL);
	CHECK(skynet_handle_findname("zulu") == 0);
	CHECK(skynet_handle_findname("middle") == 0);
	CHECK(skynet_handle_findname("alpha") == second);
	CHECK(skynet_handle_findname("bravo") == second);

	skynet_handle_retireall();
	for (size_t i = 0; i < sizeof(contexts) / sizeof(contexts[0]); ++i) {
		CHECK(skynet_handle_grab(contexts[i].handle) == NULL);
		CHECK(atomic_load(&contexts[i].refs) == 0);
	}
	CHECK(skynet_handle_findname("alpha") == 0);
	CHECK(skynet_handle_findname("bravo") == 0);
}

struct retire_case {
	pthread_mutex_t lock;
	pthread_cond_t changed;
	struct skynet_context *ctx;
	unsigned readers_ready;
	bool retired;
};

struct reader {
	struct retire_case *test;
	bool register_thread;
};

static void *
hold_reference(void *ud) {
	struct reader *reader = ud;
	struct retire_case *test = reader->test;
	if (reader->register_thread) {
		skynet_handle_register_thread();
	}
	uint32_t handle = test->ctx->handle;
	struct skynet_context *ctx = skynet_handle_grab(handle);
	CHECK(ctx == test->ctx);

	CHECK(pthread_mutex_lock(&test->lock) == 0);
	++test->readers_ready;
	CHECK(pthread_cond_broadcast(&test->changed) == 0);
	while (!test->retired) {
		CHECK(pthread_cond_wait(&test->changed, &test->lock) == 0);
	}
	CHECK(pthread_mutex_unlock(&test->lock) == 0);

	// Retire removed the handle, not the references that the readers own.
	CHECK(skynet_handle_grab(handle) == NULL);
	CHECK(skynet_context_handle(ctx) == handle);
	skynet_context_release(ctx);
	return NULL;
}

static void
check_grab_retire(void) {
	struct skynet_context ctx = {0};
	register_context(&ctx);
	struct retire_case test = {
		.lock = PTHREAD_MUTEX_INITIALIZER,
		.changed = PTHREAD_COND_INITIALIZER,
		.ctx = &ctx,
	};
	// Exercise both the registered reader slot and the shared fallback counter.
	struct reader readers[] = { { &test, true }, { &test, false } };
	pthread_t threads[2];
	for (int i = 0; i < 2; ++i) {
		CHECK(pthread_create(&threads[i], NULL, hold_reference, &readers[i]) == 0);
	}
	CHECK(pthread_mutex_lock(&test.lock) == 0);
	while (test.readers_ready < 2) {
		CHECK(pthread_cond_wait(&test.changed, &test.lock) == 0);
	}
	CHECK(atomic_load(&ctx.refs) == 3);
	CHECK(skynet_handle_retire(ctx.handle) == 1);
	CHECK(skynet_handle_grab(ctx.handle) == NULL);
	CHECK(atomic_load(&ctx.refs) == 2);
	test.retired = true;
	CHECK(pthread_cond_broadcast(&test.changed) == 0);
	CHECK(pthread_mutex_unlock(&test.lock) == 0);

	for (int i = 0; i < 2; ++i) {
		CHECK(pthread_join(threads[i], NULL) == 0);
	}
	CHECK(atomic_load(&ctx.refs) == 0);
	CHECK(pthread_cond_destroy(&test.changed) == 0);
	CHECK(pthread_mutex_destroy(&test.lock) == 0);
}

int
main(void) {
	skynet_handle_init(0x12a, 1);
	check_table();
	check_grab_retire();
	return EXIT_SUCCESS;
}
