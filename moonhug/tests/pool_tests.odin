package tests

import engine "../engine"

import "core:testing"

@(test)
test_pool_init :: proc(t: ^testing.T) {
	pool: engine.Pool(int)
	engine.pool_init(&pool)

	testing.expect_value(t, pool.count, 0)
	testing.expect_value(t, pool.free_head, engine.MAX - 1)
}

@(test)
test_pool_create_and_get :: proc(t: ^testing.T) {
	pool: engine.Pool(int)
	engine.pool_init(&pool)

	h, ptr := engine.pool_create(&pool)
	ptr^ = 42

	testing.expect_value(t, pool.count, 1)
	testing.expect(t, engine.pool_valid(&pool, h), "handle should be valid after create")

	got := engine.pool_get(&pool, h)
	testing.expect(t, got != nil, "pool_get should return non-nil for valid handle")
	testing.expect_value(t, got^, 42)
}

@(test)
test_pool_create_multiple :: proc(t: ^testing.T) {
	pool: engine.Pool(int)
	engine.pool_init(&pool)

	h1, p1 := engine.pool_create(&pool)
	p1^ = 10
	h2, p2 := engine.pool_create(&pool)
	p2^ = 20
	h3, p3 := engine.pool_create(&pool)
	p3^ = 30

	testing.expect_value(t, pool.count, 3)

	testing.expect_value(t, engine.pool_get(&pool, h1)^, 10)
	testing.expect_value(t, engine.pool_get(&pool, h2)^, 20)
	testing.expect_value(t, engine.pool_get(&pool, h3)^, 30)
}

@(test)
test_pool_destroy :: proc(t: ^testing.T) {
	pool: engine.Pool(int)
	engine.pool_init(&pool)

	h, ptr := engine.pool_create(&pool)
	ptr^ = 99

	engine.pool_destroy(&pool, h)

	testing.expect_value(t, pool.count, 0)
	testing.expect(t, !engine.pool_valid(&pool, h), "handle should be invalid after destroy")
	testing.expect(t, engine.pool_get(&pool, h) == nil, "pool_get should return nil for destroyed handle")
}

@(test)
test_pool_generation_increments :: proc(t: ^testing.T) {
	pool: engine.Pool(int)
	engine.pool_init(&pool)

	h1, _ := engine.pool_create(&pool)
	engine.pool_destroy(&pool, h1)

	h2, _ := engine.pool_create(&pool)

	testing.expect(t, !engine.pool_valid(&pool, h1), "old handle should be invalid after slot reuse")
	testing.expect(t, engine.pool_valid(&pool, h2), "new handle should be valid")
	testing.expect(t, h2.generation > h1.generation, "generation should increment on reuse")
	testing.expect_value(t, h1.index, h2.index)
	testing.expect(t, engine.pool_get(&pool, h1) == nil, "pool_get should return nil for stale handle")
}

@(test)
test_pool_slot_reuse :: proc(t: ^testing.T) {
	pool: engine.Pool(int)
	engine.pool_init(&pool)

	h1, p1 := engine.pool_create(&pool)
	p1^ = 111
	engine.pool_destroy(&pool, h1)

	h2, p2 := engine.pool_create(&pool)
	p2^ = 222

	testing.expect_value(t, h1.index, h2.index)
	testing.expect_value(t, engine.pool_get(&pool, h2)^, 222)
}

@(test)
test_pool_get_assert :: proc(t: ^testing.T) {
	pool: engine.Pool(int)
	engine.pool_init(&pool)

	h, ptr := engine.pool_create(&pool)
	ptr^ = 7

	got := engine.pool_get_assert(&pool, h)
	testing.expect_value(t, got^, 7)
}

@(test)
test_pool_valid_out_of_range :: proc(t: ^testing.T) {
	pool: engine.Pool(int)
	engine.pool_init(&pool)

	bad_handle := engine.Handle{ index = engine.MAX, generation = 1, type_key = engine.INVALID_TYPE_KEY }
	testing.expect(t, !engine.pool_valid(&pool, bad_handle), "out-of-range index should be invalid")
}

iter_count: int
iter_sum: int

@(test)
test_pool_iter :: proc(t: ^testing.T) {
	pool: engine.Pool(int)
	engine.pool_init(&pool)

	_, p1 := engine.pool_create(&pool)
	p1^ = 1
	_, p2 := engine.pool_create(&pool)
	p2^ = 2
	_, p3 := engine.pool_create(&pool)
	p3^ = 3

	iter_count = 0
	iter_sum = 0
	engine.pool_iter(&pool, proc(h: engine.Handle, data: ^int) {
		iter_sum += data^
		iter_count += 1
	})

	testing.expect_value(t, iter_count, 3)
	testing.expect_value(t, iter_sum, 6)
}
