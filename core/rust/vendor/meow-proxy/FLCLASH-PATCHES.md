# FlClash direct outbound DNS

Based on crates.io meow-proxy 0.28.0, upstream revision
80816302e7ad8f868fdf1619a11bf3c8121696dd, under the included MIT license.

`DirectAdapter` selects its resolver generation's dedicated direct DNS for domain destinations, including
destinations whose IP was already populated by routing. Literal IPv4 and IPv6 destinations keep their ordinary
path. General and proxy-server DNS hooks are untouched. UDP sockets connect to the chosen DNS answer and ignore
the caller's old destination on writes; replies retain the original destination address expected by TUN/NAT.
