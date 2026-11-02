# FlClash direct DNS generation references

Based on crates.io meow-api 0.28.0, upstream revision
80816302e7ad8f868fdf1619a11bf3c8121696dd, under the included MIT license.

The existing DNS runtime-reference scan also checks `direct-nameserver`. A routed direct nameserver captures
candidate proxy adapters and must rebuild when that registry changes, even when the DNS URL list stays equal.
The existing candidate construction, commit and failed-reload rollback remain the only owners of the transition.
