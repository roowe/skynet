#include "skynet_mq.h"

#include <pthread.h>
#include <stdio.h>

#define CHECK(condition) do { \
	if (!(condition)) { \
		fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #condition); \
		exit(EXIT_FAILURE); \
	} \
} while (0)

enum { PRODUCER_MESSAGES = 513 };
static unsigned char payloads[2 * PRODUCER_MESSAGES][4];

static size_t
message_size(int sequence) {
	return ((size_t)7 << MESSAGE_TYPE_SHIFT) | (1 + (size_t)sequence % sizeof(payloads[0]));
}

static void
push_message(struct message_queue *queue, int sequence) {
	struct skynet_message message = { 0x01000000, sequence, payloads[sequence], message_size(sequence) };
	skynet_mq_push(queue, &message);
}

static void
check_message(const struct skynet_message *message, int sequence) {
	CHECK(message->source == 0x01000000);
	CHECK(message->session == sequence);
	CHECK(message->data == payloads[sequence]);
	CHECK(message->sz == message_size(sequence));
}

static void
pop_message(struct message_queue *queue, int sequence) {
	struct skynet_message message;
	CHECK(skynet_mq_pop(queue, &message) == 0);
	check_message(&message, sequence);
}

static void
check_empty(struct message_queue *queue) {
	struct skynet_message message;
	CHECK(skynet_mq_length(queue) == 0);
	CHECK(skynet_mq_pop(queue, &message) != 0);
}

struct drops {
	int next;
	int end;
};

static void
check_drop(struct skynet_message *message, void *ud) {
	struct drops *drops = ud;
	CHECK(drops->next < drops->end);
	check_message(message, drops->next++);
}

static void
release_idle(struct message_queue *queue) {
	struct drops drops = { 0, 0 };
	skynet_mq_mark_release(queue);
	CHECK(skynet_globalmq_pop() == queue);
	skynet_mq_release(queue, check_drop, &drops);
	CHECK(skynet_globalmq_pop() == NULL);
}

static void
check_ready_queue(void) {
	struct message_queue *first = skynet_mq_create(0x01000001);
	struct message_queue *second = skynet_mq_create(0x01000002);
	CHECK(skynet_mq_handle(first) == 0x01000001);
	CHECK(skynet_mq_handle(second) == 0x01000002);

	push_message(second, 2);
	push_message(first, 0);
	CHECK(skynet_globalmq_pop() == NULL);
	skynet_globalmq_push(first);
	skynet_globalmq_push(second);
	CHECK(skynet_globalmq_pop() == first);
	push_message(first, 1);
	CHECK(skynet_globalmq_pop() == second);
	CHECK(skynet_globalmq_pop() == NULL);
	pop_message(first, 0);
	pop_message(first, 1);
	pop_message(second, 2);
	check_empty(first);
	check_empty(second);

	push_message(second, 3);
	push_message(second, 4);
	CHECK(skynet_globalmq_pop() == second);
	CHECK(skynet_globalmq_pop() == NULL);
	pop_message(second, 3);
	pop_message(second, 4);
	// A successful last pop still leaves the queue owned by the worker.
	push_message(second, 5);
	CHECK(skynet_globalmq_pop() == NULL);
	pop_message(second, 5);
	check_empty(second);
	release_idle(first);
	release_idle(second);
}

static void
check_wrapped_growth(void) {
	struct message_queue *queue = skynet_mq_create(0x01000001);
	skynet_globalmq_push(queue);
	CHECK(skynet_globalmq_pop() == queue);
	for (int i = 0; i < 48; ++i) {
		push_message(queue, i);
	}
	for (int i = 0; i < 32; ++i) {
		pop_message(queue, i);
	}
	// Growth must preserve both spans of the wrapped ring.
	for (int i = 48; i < 100; ++i) {
		push_message(queue, i);
	}
	CHECK(skynet_mq_length(queue) == 68);
	for (int i = 32; i < 100; ++i) {
		pop_message(queue, i);
	}
	check_empty(queue);
	release_idle(queue);
}

static void
check_deferred_release(void) {
	struct message_queue *queue = skynet_mq_create(0x01000001);
	struct drops drops = { 1, 4 };
	for (int i = drops.next; i < drops.end; ++i) {
		push_message(queue, i);
	}
	skynet_globalmq_push(queue);
	CHECK(skynet_globalmq_pop() == queue);
	skynet_mq_release(queue, check_drop, &drops);
	CHECK(drops.next == 1);
	CHECK(skynet_mq_length(queue) == 3);
	skynet_mq_mark_release(queue);
	CHECK(skynet_globalmq_pop() == queue);
	CHECK(skynet_globalmq_pop() == NULL);
	skynet_mq_release(queue, check_drop, &drops);
	CHECK(drops.next == drops.end);
	CHECK(skynet_globalmq_pop() == NULL);
}

struct producer {
	struct message_queue *queue;
	int start;
};

static void *
produce(void *ud) {
	struct producer *producer = ud;
	for (int i = producer->start; i < producer->start + PRODUCER_MESSAGES; ++i) {
		push_message(producer->queue, i);
	}
	return NULL;
}

static void
check_concurrent_producers(void) {
	struct message_queue *queue = skynet_mq_create(0x01000001);
	skynet_globalmq_push(queue);
	CHECK(skynet_globalmq_pop() == queue);
	check_empty(queue);

	struct producer producers[] = { { queue, 0 }, { queue, PRODUCER_MESSAGES } };
	pthread_t threads[2];
	for (int i = 0; i < 2; ++i) {
		CHECK(pthread_create(&threads[i], NULL, produce, &producers[i]) == 0);
	}
	for (int i = 0; i < 2; ++i) {
		CHECK(pthread_join(threads[i], NULL) == 0);
	}
	CHECK(skynet_globalmq_pop() == queue);
	CHECK(skynet_globalmq_pop() == NULL);
	CHECK(skynet_mq_length(queue) == 2 * PRODUCER_MESSAGES);

	// The two producers can interleave, but each producer retains FIFO order.
	int next[] = { 0, PRODUCER_MESSAGES };
	for (int i = 0; i < 2 * PRODUCER_MESSAGES; ++i) {
		struct skynet_message message;
		CHECK(skynet_mq_pop(queue, &message) == 0);
		CHECK(message.session >= 0 && message.session < 2 * PRODUCER_MESSAGES);
		int producer = message.session / PRODUCER_MESSAGES;
		check_message(&message, next[producer]++);
		CHECK(skynet_mq_overload(queue) == (i == 0 ? 1025 : 0));
	}
	CHECK(next[0] == PRODUCER_MESSAGES);
	CHECK(next[1] == 2 * PRODUCER_MESSAGES);
	check_empty(queue);
	release_idle(queue);
}

int
main(void) {
	skynet_mq_init();
	check_ready_queue();
	check_wrapped_growth();
	check_deferred_release();
	check_concurrent_producers();
	return EXIT_SUCCESS;
}
